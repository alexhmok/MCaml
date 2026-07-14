# MCaml

A small ML-like language that compiles to Minecraft `.mcfunction` files. Written in OCaml. Target use case: eventually implementing microGPT-style ML inference in-game.

## Pipeline

```
source → lex → parse → alpha → partial_app → for_lift →
  Phase 1 (per Fun): type → knormal → tco → cfg_build → function table
  Phase 2a        : inline (leaf-splice over full table)
  Phase 2b        : monomorphize (specialize array-param templates)
  Phase 3 (per Fun): optimize (M3a → M4 loop_pass → M3a) → regalloc_cfg → codegen_cfg → files
  Phase 4         : tick_split (fan oversized files into __cont<N> chains via `schedule … 1t`)
  Phase 5         : tick_guard (prepend per-iteration $tick_iters_<fname> budget guard at every TCO'd self-loop entry)
```

The M4 loop_pass runs LICM → unroll → SROA between two M3a fixed-point
sweeps; the second sweep collapses the `ICopy` chains and dead element
slots that SROA leaves behind. Each pass has a `MCAML_NO_<NAME>=1`
A/B toggle.

M3c-1 introduced a two-phase driver so the inliner can see every caller
and callee at once. `codegen.ml` is split into `compile_def_to_cfg` (AST
→ cfg_func) and `compile_cfg_to_files` (cfg_func → files); `main.ml`
runs Phase 1 across every def, calls `Inline.run` on the whole function
table, then runs Phase 3. Disable the inliner with `MCAML_NO_INLINE=1`
for A/B measurement.

Historical note: before Milestone 2 the codegen emitted Minecraft commands directly from a tree walk over `kexpr`, and register allocation used a tree-shaped `future`-threading pass over the same IR. Both are gone. Every optimization pass from M3 onward runs on the CFG.

### Module layout

**Frontend**
- `source_include.ml` — pre-lex `include "path"` splicing (line-wise directive, once-per-file, includer-relative paths, `cat` semantics). Runs on the raw stdin text in `main.ml` before the lexer.
- `ast.ml` — AST types. `typ` includes `TInt`/`TBool`/`TUnit`/`TSelector`/`TPos` plus `TArr of typ * int` and `TMat of typ * int * int` for arrays and matrices.
- `lexer.mll` — ocamllex source (generates `lexer.ml`, checked in).
- `parser.mly` — menhir grammar (generates `parser.ml`/`.mli`, checked in). Uses a `seq_expr`/`expr` split to avoid a reduce/reduce conflict between list-separator `;` inside `[| … |]` and statement-level `Seq`.
- `alpha.ml` — scope analysis; renames every user binder to `name_N` for uniqueness.
- `partial_app.ml` — explicit partial application: an under-applied call to a known top-level fun desugars to let-temps (supplied args evaluate once) + a lambda, which for_lift then closure-converts like any other. Skips targets with array/matrix/ref params; no implicit currying.
- `typing.ml` — type checker, split into units re-exported through this facade (`include` chain, so the historical `Typing.*` interface and `Typing.Error`'s identity are preserved): `typing_core.ml` (the shared `Error` exception + global tables: `fun_sigs`, `global_vals`, `adt_decls`/`ctor_info`, `record_decls`/`record_fields`), `typing_unify.ml` (HM unification engine, schemes/generalization, `subst_typarams`), `typing_decls.ml` (type/record registration + validators + `build_sigs`), `typing_patterns.ml` (pattern typing + Maranget usefulness), `typing_infer.ml` (the `infer` walk + `type_fun_def`). `App` types calls against the global `fun_sigs` table (populated from the post-for_lift program); a lookup miss falls back to `TInt` (covers synthesized helpers and untyped callees). Quirk: nested `Array` literals with matching inner lengths promote to `TMat`.

**Middle end**
- `knormal.ml` — A-normal form. `kexpr` has `KInt`/`KVar`/`KStr`/`KCommand`/`KBinOp`/`KLet`/`KIf`/`KSeq`/`KCall`/`KLoop` plus the M1 array primitives `KArrLitConst`/`KArrLitDyn`/`KArrGetStatic`/`KArrGet` and the indexed-store primitives `KArrSetStatic`/`KArrSet`. Arrays are not first-class runtime values: `let a = [| … |]` binds `a` to a compile-time storage ID via an internal `arr_env` table; arrays can't be passed to functions or returned in M1/M2. Indexed assignment: `a[i] := v` parses as `RefSet(Index1(a,i), v)` and `alpha.ml` rewrites that into dedicated `IndexSet1`/`IndexSet2` AST nodes so no parser change was needed.
- `tco.ml` — rewrites self-recursive tail `KCall` to `KLoop`. Matches the knormal-produced `KSeq(KCall, KLet(d, KVar "$ret", KUnit))` pattern; see the explicit rule.

**CFG IR (Milestone 2)**
- `cfg.ml` — CFG IR types: `instr`, `terminator`, `block`, `cfg_func`. Blocks carry a **guard chain** (`(cond_vreg, polarity) list`) from enclosing `TBranch`es; this is the source of truth for both liveness (implicit cond reads) and codegen (`execute if/unless` wrapping). `instr` includes `IArrSet`/`IArrSetStatic` for indexed stores — both are **side-effecting** (no vreg def, storage write) so DCE never removes them and local_cse never merges two writes to the same `(aid, k)` pair. `copy_prop` rewrites the val/idx operands through its map but leaves the storage id opaque.
- `cfg_build.ml` — lowers `kexpr` → CFG. Populates guard chains during lowering, not as a post-pass. `TBranch` terminators carry the merge label explicitly.
- `liveness.ml` — iterative backward dataflow with **guard-chain pinning**: every `cond_vreg` in a block's guard chain is treated as an implicit use of every instruction in that block. This is the correctness fix for the M2-specific trap where cond would otherwise be "dead" inside its own branches.
- `regalloc_cfg.ml` — interval-based linear scan over RPO linearization. Uses a dual-position encoding (`2*g+1` for both reads and same-instruction writes) to enforce the read-before-write constraint on `IBinOp`. Reserved vregs (`$ret`, `param_N`, `$arr_result`) are identity-mapped.
- `codegen_cfg.ml` — CFG-driven command emission. Structured DFS walk from entry. Guard chains compose into single-head `execute if … unless … run cmd` clauses (the "execute fold" win over the old nested `execute … run execute … run …` chains). Generates save/restore helper files for non-tail calls; macro helper files for dynamic array indexing.
- `codegen_helpers.ml` — pure command-string builders, no mutable state. Both the CFG codegen and (historically) the kexpr codegen imported from here.

**Inliner (Milestone 3c)**
- `inline.ml` — `Inline.run` splices every ICall to a leaf callee into its caller, operating on a `(string, cfg_func) Hashtbl.t` populated by Phase 1. Leaf = zero `ICall` + zero `TTail` (so TCO'd self-loops are *not* leaves). Vreg renaming uses a per-event `$in<N>_` prefix; `$ret` and `$arr_result` are treated as reserved (not renamed), because knormal's call convention is `ICall(None, f, args); ICopy(d, $ret)` — the caller reads the return via `$ret` after the inlined body runs. Guards compose: cloned blocks inherit the caller block's guard chain. Size threshold: 30 instrs per leaf; growth cap: 3× caller's initial size.

**Loop pass (Milestone 4)**
- `dominators.ml` — iterative dataflow dominators over the CFG. Returns an `idom` array; `< 50` blocks per function so the simple worklist beats Lengauer-Tarjan in code size. `MCAML_DUMP_LOOPS=1` dumps results.
- `loop_detect.ml` — natural loop detection from idom + back-edges. For TCO'd self-recursive loops (the common case from `for_lift`/`tco`) the preheader is virtual: hoisted code lives in `cfg.preheader_instrs` and codegen splits the function into a wrapper file plus a `__body` file.
- `licm.ml` — hoists loop-invariant `IArrLitConst`/`IArrLitDyn` (the M1 stress-test win: `let a = [|...|]` no longer re-runs `data modify storage` per iteration). v1 restricts hoisting to no-vreg-dest instructions so regalloc doesn't need to know about the preheader. Single-init-per-aid is structurally guaranteed by knormal but checked defensively. `MCAML_NO_LICM=1` toggles.
- `unroll.ml` — full unrolling of `for_lift`-synthesized counted helpers. Detects the canonical `if i < hi then body; tail self(i+1, ..)` shape, resolves `lo`/`hi` from the unique caller's IConst defs, and clones the body block N times with per-iteration `$un<k>_` prefix and `IConst($un<k>_<lv>, lo+k)` substitution for the loop var. Cap: `MCAML_UNROLL_LIMIT` (default 16). `MCAML_NO_UNROLL=1` toggles. **Renaming invariant**: only vregs *defined inside the body block* get the `$un<k>_` prefix. Vregs defined in the header/entry block (loop-invariant scalars carried in via `ICopy(k, param_N)`) are left alone so every per-iteration clone shares the same live value — renaming those would create undefined `$un0_k, $un1_k, …` slots. v1 only handles single-block bodies; multi-block unrolling is follow-up. **Post-unroll invariant**: the original body block is left in `cfg.blocks` with its stale `TTail` terminator and empty `preds`, so any reachability check (e.g. `main.ml`'s `has_self_tail`) MUST filter on `label = entry || preds <> []` — otherwise the stale TTail is mistaken for a live self-loop and `tick_guard` prepends a spurious budget guard to an already-unrolled helper, which then yields mid-body and corrupts any caller relying on the unrolled work completing.
- `sroa.ml` — promotes small non-escaping arrays whose every read AND write is static (`IArrGetStatic`/`IArrSetStatic`) to N independent vregs `<aid>_<k>`. Length cap: `MCAML_SROA_LIMIT` (default 16). Gates on at least one in-function static use AND on **cross-function escape**: `Sroa.run` receives the whole `fn_table` and disqualifies any aid that any other non-template function mentions, because for-loop-lifted helpers (after monomorphization) often share the same storage path with their caller — promoting one side while leaving the other reading raw storage would silently break the pipeline. `IArrLitConst→N IConst`, `IArrLitDyn→N ICopy`, `IArrGetStatic→ICopy`, `IArrSetStatic→ICopy(slot, val)`; the post-SROA M3a fixed point collapses the copy chains. `MCAML_NO_SROA=1` toggles.
- `strength_reduce.ml` (M4 follow-up) — induction-variable analysis + rewrite. Stage 1 detects basic IVs (`ICopy(lv, "param_N")` in the entry block, advanced by a constant step in some self-`TTail` latch). Stage 2 walks the loop body and classifies every vreg as `Inv` or `IvLin {iv; stride; base}`, surfacing derived IVs whose value is `iv*stride + base` for some basic IV and loop-invariant stride/base. Stage 3 rewrites each derived IV by minting a fresh `$ref_sr_<n>` carrier slot, materializing its initial value `param_<idx>*stride + base` into `cfg.preheader_instrs` (which the wrapper file emits once at function entry), replacing the per-iteration `IBinOp` with `ICopy(d, $ref_sr_n)`, and appending `$ref_sr_n += stride` before every self-`TTail`. Carriers and materialized stride/base temps both use the `$ref_*` prefix so regalloc/copy_prop/dce/liveness/inline/unroll all skip them — preheader temps live only in `preheader_instrs` (which regalloc does not walk) and would otherwise be renamed in the body's back-edge increment but not in the wrapper. Useful-uses filter drops derived IVs whose only consumers are *other* derived IVs we're rewriting (the matmul `k*cols` intermediate folded into `k*cols + j` is the canonical case). v1 scope: step=+1 basic IVs, single-defining-block derived chains, and TCO'd self-loops where `header = cfg.entry`. `MCAML_NO_SR=1` toggles; `MCAML_DUMP_IV=1` dumps the analyzer table for every non-template function.
- `optimize.ml` — drives both fixed points: M3a → loop_pass (LICM → strength_reduce → unroll → SROA) → second M3a. Templates skip everything; the loop pass also threads `fn_table` to the unroller for caller-side constant resolution. SR runs *before* unroll so hand-written tail-recursive loops the unroller declines (matmul-style `if i >= hi then exit else recurse`) still get their per-iteration index multiplies replaced by carrier increments; `for_lift`-emitted loops (which the unroller can fully clone) have no derived IVs in this codebase, so SR is a no-op there and unroll fires unaffected.
- `const_fold.ml` (M4 amendment) — when `IArrGet`'s index resolves to a known constant, rewrites to `IArrGetStatic`. This is the bridge from unrolling (which materializes `loop_var` as an `IConst`) to SROA's static-only access requirement.
- `codegen_helpers.ml` (SR amendment) — `cmd_score_binop` now elides the leading `d := v1` self-copy when `d = v1`, so the SR-emitted `IBinOp(carrier, Add, carrier, stride)` increment lowers to a single `scoreboard players operation carrier += stride` instead of two commands. Saves one command per increment per iteration; mechanically correct because regalloc never produces `IBinOp(d, op, v1, v2)` with `d = v2 ≠ v1` (its dual-position encoding gives v1/v2 reads and the d write disjoint slot lifetimes).

**Driver**
- `codegen.ml` — split into `compile_def_to_cfg` (AST → cfg_func) and `compile_cfg_to_files` (optimize → regalloc → codegen_cfg). Legacy `compile_def` still exists as a convenience wrapper.
- `main.ml` — three-phase driver: build cfg table, run `Inline.run`, emit. Reads stdin, writes `.mcfunction` files in source order. `MCAML_DUMP_CFG=1` dumps post-regalloc CFG; `MCAML_NO_INLINE=1` skips Phase 2.

## Build & run

Dune project. All OCaml sources live in `src/` (one `.mli` per `.ml`).
Interfaces are CURATED, not inferred dumps (narrowed 2026-07-09): an
`.mli` exports only what other modules — `src/` or `test/` — actually
consume; helpers stay private. When new cross-module code needs a
symbol, add just that one `val` (run `ocamlc -i` to print the full
signature and copy the line out of it; don't paste the whole dump).
The exceptions are the generated `parser.mli`/`lexer.mli` and
`main.mli`, which stay as-is. `src/`
builds as library `mcaml` (`(wrapped false)`, so module names are
unchanged: `Cfg`, `Const_fold`, …) plus a thin `main` executable that
links it — the split exists so `test/` can link the compiler modules;
narrowing an `.mli` therefore narrows what tests can see, so tests
count as consumers when deciding what to export.
Build artifacts stay under `_build/` — never commit `.cmi`/`.cmo` next
to the sources. Rebuild:

```
cd /Users/alexmok/MCaml
dune build          # builds _build/default/src/main.exe; ./mcaml is a symlink to it
```

Dune resolves module ordering automatically — no hand-maintained module
list. The checked-in `src/lexer.ml` / `src/parser.ml` / `src/parser.mli`
are compiled as plain modules; when `lexer.mll` or `parser.mly` change,
regenerate them manually first:

```
cd src
ocamllex lexer.mll                                   # regenerate lexer.ml
menhir parser.mly                                    # regenerate parser.ml/.mli
```

The `dune` file uses `(flags (-g))` (no `:standard`) so warnings match
plain `ocamlc` defaults instead of dune's fatal dev-profile set.

Refactor gate: `python3 tools/verify_canary.py` compiles the 5 test
suites, runs their sim checkers, and prints a sha256 canary hash per
build — compare across commits to prove a change is byte-identical.

Unit tests: alcotest suites in `test/` (the repo's only external dep,
test-only — `opam install alcotest`), run with `dune test`. Tranche 1
covers `const_fold` floor-division parity, `codegen_helpers` golden
command strings, `dominators`/`loop_detect` on hand-built CFGs, and
the `liveness` guard-chain pinning invariant. `test/cfg_fixtures.ml`
builds fixture CFGs and enforces the label-equals-array-index and
populated-`preds` invariants the analyses rely on.

Invoke:

```
./mcaml -o build < scripts/test_full.mcaml   # writes .mcfunction files to build/
MCAML_OUT=build ./mcaml < …                  # env var alternative
./mcaml < …                                  # no flag → files land in cwd (legacy)
MCAML_DUMP_CFG=1 ./mcaml < …                 # stderr shows post-regalloc CFG + emitted commands
MCAML_NO_INLINE=1 ./mcaml < …                # skip Phase 2 (leaf inliner) for A/B
MCAML_NO_M3A=1 ./mcaml < …                   # M3a: skip const_fold/copy_prop/local_cse/dce fixed point (both sweeps)
MCAML_NO_LICM=1 ./mcaml < …                  # M4: skip LICM hoisting
MCAML_NO_SR=1 ./mcaml < …                    # SR: skip strength-reduction rewrite
MCAML_NO_UNROLL=1 ./mcaml < …                # M4: skip loop unrolling
MCAML_NO_SROA=1 ./mcaml < …                  # M4: skip array→scalar promotion
MCAML_NO_DEADVAL=1 ./mcaml < …               # skip dead global-val elimination (unreferenced vals dropped
                                             # from __globals_init; static-only vals lose their _get file)
MCAML_O0=1 ./mcaml < …                       # unoptimized baseline: implies ALL seven MCAML_NO_* pass flags above.
                                             # Monomorphize (required for array params), tick_split, and tick_guard
                                             # still run — those are correctness mechanisms, not optimizations.
                                             # Implemented as Cfg.pass_disabled, which every pass flag reads through.
MCAML_DUMP_LOOPS=1 ./mcaml < …               # stderr dumps idom + detected loops
MCAML_DUMP_IV=1 ./mcaml < …                  # SR §1 stage 1: basic induction variables per function
MCAML_UNROLL_LIMIT=N ./mcaml < …             # max unroll trip count (default 16)
MCAML_SROA_LIMIT=N ./mcaml < …               # max promoted array length (default 16)
MCAML_NO_TICK_SPLIT=1 ./mcaml < …            # Phase 4: skip straight-line file splitting
MCAML_NO_TICK_GUARD=1 ./mcaml < …            # Phase 5: skip per-iteration loop guard
MCAML_TICK_BUDGET=N ./mcaml < …              # split threshold per file (default 50000)
MCAML_TICK_COMMANDS=N ./mcaml < …            # per-tick command budget for tick_guard (default 60000);
                                             # each guarded loop's iter limit = N / its per-iter body cost
MCAML_LOOP_ITER_LIMIT=N ./mcaml < …          # legacy override: uniform per-tick iteration limit for every
                                             # guarded loop, ignoring per-iter cost
```

The driver accepts `-o <dir>` (or the `MCAML_OUT` env var) to pick an
output directory; it `mkdir -p`'s the dir if missing. Default is cwd so
the `/tmp/mcaml_out` test harness (which loads sims + sources from the
same dir) keeps working unchanged — use `-o build` when compiling from
the project root to keep generated files out of the source tree.

## Runtime conventions

- Objective name: `vars` (hardcoded as `obj_name` in `codegen_helpers.ml`).
- Physical slots: `$r0`, `$r1`, … minted by regalloc, per-function pool.
- Return slot: `$ret`. **Caveat**: every function writes `$ret` on exit (unit-returning for_lift helpers write `0`), so the slot is only valid for the immediate next command in the caller — safe for synchronous call chains, *unsafe* across tick boundaries. A TCO'd loop whose scheduled continuations resume on later ticks will clobber `$ret` on every natural exit, overwriting whatever the original caller wrote. When a result must survive across tick boundaries, bind it to a ref (`let result = ref 0 in … ; result := expr; !result`) and read `$ref_result_<N>` directly — refs lower to reserved-namespace scoreboard slots that no function touches except via explicit user code. The demo in `scripts/demo_classifier.mcaml` shows the pattern.
- Call params: `param_0`, `param_1`, ….
- Tick budget slots: `$tick_iters_<fname>` — one counter per `tick_guard`-instrumented self-loop. Per-loop (not one shared counter) is a correctness requirement for nested loops: with a shared counter, the outer loop's iterations bump the inner loop's budget too, so the inner loop yields spuriously mid-iteration and leaves the outer's accumulator with a partial sum (MineTorch stage 9 hit exactly this in the MNIST matmul). The per-loop iteration limit is `MCAML_TICK_COMMANDS / body_cost` (per-function body cost via `Cost.estimate_block`); `MCAML_LOOP_ITER_LIMIT` is a legacy uniform override. `main.ml`'s `has_self_tail` check must filter on reachable blocks only (`Cfg.block_is_reachable`) so the unroller's stale dead `TTail` doesn't cause a guard to be prepended to a fully-unrolled helper. Without this filter, every call to such a helper bumps its counter and may yield mid-body, corrupting the caller. The counter is also reset to 0 on the natural-exit path (a trailing `scoreboard players set $tick_iters_<target> vars 0` appended to the guarded entry file, pre-tick_split) so a later invocation of the same loop never inherits a stale budget and yields prematurely — the budget is per-invocation.
- Array scratch slot: `$arr_result` — used by macro getters, reserved. Parallel: `$arr_set_val` — used by per-aid macro setters (`<id>_set.mcfunction`) to pass the value-to-store without macro-substituting a scoreboard read; also reserved.
- Function dispatch: `function mcaml:<name>`.
- Array storage: `storage mcaml:heap <aid>` where `<aid>` is a compile-time string like `arr3`.
- Frame stack for non-tail calls: `storage mcaml:stk frames` — an NBT list; each frame is a compound `{r0: …, r1: …, …}`.
- Macro getter path: `storage mcaml:tmp args.idx` is the index passed to `function mcaml:<aid>_get with storage mcaml:tmp args`.
- Integer `/` and `%` are **floor** semantics (floorDiv/floorMod, `-7 / 2 = -4`, `-7 % 3 = 2`), matching vanilla scoreboard `/=`/`%=` as measured in-game 2026-07-07 — NOT OCaml's truncating operators. `const_fold.ml` (including the FMult/FDiv internal divisions) and `sim.py` implement the same; `scripts/mc_test_suite.mcaml` t04/t05, t07/t08, t61/t62 pin fold/runtime parity.
- Booleans are integers 0/1; `if` compares against `matches 1`.
- Comparison binops use `execute store success score … if score …`; `Neq` uses `unless score … =`.
- `And`/`Or` compile to scoreboard `<` (min) / `>` (max) — correct for 0/1 operands.
- Tail recursion compiles to `return run function mcaml:<self>` after rewriting `param_N`. The `return run` (MC 1.20.5+) is load-bearing, not style: a bare `function` dispatch would resume THIS file's remaining lines when the callee returns — the other match arms / merge blocks after the tail call, guarded by cond slots the callee just clobbered (TTail has no save/restore helper by design). Optimized builds historically survived this fallthrough only because their exit arms happened to be idempotent under re-execution; `MCAML_NO_M3A=1` builds miscompiled (count_leaves_tco returned 2 instead of 5) until the `return run` fix landed 2026-07-08. Non-tail direct calls (zero live slots) are safe without it: liveness's guard-chain pinning forces any guarded call with guarded successors through the save/restore helper path.
- Non-tail calls generate a per-call-site helper file `<fname>_callN.mcfunction` that saves `$r0..$r{slot_count-1}` to a storage frame, makes the call, restores, pops the frame. The caller emits a single `function mcaml:<fname>_callN` line (guard-wrappable).

## Test programs

- `scripts/test_all.mcaml` — arith, in_range, classify, fib, sum_to, driver (covers arithmetic, booleans, branches, TCO, non-tail calls).
- `scripts/stress_nested_if.mcaml` — regression test for the KIf cond liveness trap; nested conditionals with many locals in each branch.
- `scripts/test_arr_set.mcaml` — indexed-store regression: static set, dynamic for-loop set, read-modify-write (`a[i] := a[i] + 1`), matrix set. Covers the full IArrSet end-to-end path.
- `scripts/primitives_v1.mcaml` — stage-1 microGPT primitives: `dot`, `vec_add_into`, `vec_scale_into` (all N=4) plus per-input driver functions. Cross-validated against `primitives_ref.py` via `test_primitives_v1.py`.
- `scripts/demo_classifier.mcaml` — representative end-to-end pipeline: 3-class integer classifier built from the primitives, 500-iter batch loop over 4 samples. Exercises both tick mechanisms (`tick_guard` via the loop; compile with `MCAML_LOOP_ITER_LIMIT=30`) and demonstrates the cross-tick ref pattern for the final result.
- `scripts/test_core.mcaml`, `test_fib.mcaml`, `test_fib_tco.mcaml`, `test_tco.mcaml`, `debug_ret.mcaml` — smaller single-feature smoke tests.
- `/tmp/mcaml_out/` — working directory for test artifacts, simulators (`sim.py`, `arrsim.py`, `nested_sim.py`, `stress_run.py`), and stress/array test sources.

## Simulator

Canonical location: `sim/sim.py` (checked into this repo). Copied to `/tmp/mcaml_out/sim.py` at test time by MineTorch's `validation/_harness.py` (`ensure_sim()`). A Python model of the Minecraft command subset that MCaml emits: `scoreboard players set/operation`, `execute if/unless score … matches N`, `execute store success/result`, `function mcaml:<name> [with storage …]`, `data modify storage …`, macro substitution (`$(key)`), `return 0` (tick_guard exit), `return run <cmd>` (TTail dispatch). Used by every test suite to verify `$ret` values and `say` outputs without running actual Minecraft.

## Datapack packaging

Host-side tooling that wraps a flat `-o build/` directory into a loadable Minecraft datapack. Lives in `tools/`, not OCaml — packaging is pure file shuffling and a separate script keeps the simulator path (which consumes raw `.mcfunction` files) untouched.

- `tools/pack_datapack.py` — Python 3 packager. Takes `--input <build dir> --name <pack name> --output <dir-or-zip>`, copies every `*.mcfunction` flat into `data/mcaml/function/`, and synthesizes `pack.mcmeta` (`pack_format: 41` baseline, `supported_formats: [41, 81]` through 1.21.x), `data/mcaml/function/init.mcfunction` (registers the `vars` objective and zeroes `mcaml:stk frames` / `mcaml:tmp args`), and `data/minecraft/tags/function/load.json` (wires `mcaml:init` to `#minecraft:load`). Refuses to overwrite a user-provided `init.mcfunction`. Zip mode uses sorted entries + a fixed epoch so rebuilds are byte-identical.
- `tools/README.md` — entrypoint convention for chat-driven invocation: set `param_N` in the `vars` objective, run `/function mcaml:<name>`, read `$ret` from `vars`. Worked example: `test_full_chain.mcaml` returns `$ret = 70`.
- `tools/MANUAL_TEST.md` — five-minute checklist for verifying a packed datapack against `sim.py` in real Minecraft. Used as the correctness gate whenever a change touches codegen, the runtime conventions, or the packager.
- `main.ml` reserves the top-level function name `init` (errors before alpha-renaming) so user programs can't clobber the synthesized loader. Same treatment is the right move for any future synthesized name.
