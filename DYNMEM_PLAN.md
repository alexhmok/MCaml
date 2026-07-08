# MCaml dynamic-memory implementation plan

Cross-session reference document for adding dynamic arrays, cons lists, and
region-based memory management to MCaml. Read this file at the start of every
new session that touches this work.

## How to use this document

1. At the start of a new session, paste the **session kickoff prompt** for the
   current phase (§8) into Claude Code.
2. Claude reads this file, checks the **current status** section (§2), verifies
   the codebase state, then picks up the next open task.
3. When a task completes, Claude updates the status section in this file as
   part of the same commit.
4. The **load-bearing design decisions** in §3 have been settled. Do not
   relitigate them unless you hit a concrete blocker — in which case stop and
   flag it to the user before improvising.

## 1. Goal

Add three things to MCaml while preserving the existing optimization pipeline
and the language's functional purity:

- **Dynamic arrays** (`TArrDyn of typ`): runtime-sized, handle-backed arrays,
  passable across function boundaries, allocated into an arena.
- **Lists with `::` / `[]` / `head` / `tail`** (`TList of typ`): immutable
  cons-cell lists in their own pool.
- **Region blocks** (`region (fun () -> ...)`): structured arena nesting with
  compiler-inserted copy-on-escape for pure semantics.

The static array path (`TArrStatic`, today's `TArr`) is untouched. SROA, LICM,
monomorphization, unrolling, and every M3/M4 optimization keeps running
unchanged on static arrays so the existing nano-GPT / matmul perf doesn't
regress.

## 2. Current status

Update this section as tasks complete. Format: one bullet per task, marked
`[ ]` open, `[~]` in progress, `[x]` done. Include commit hashes for completed
work.

### Phase A — Dynamic arrays
- [x] A1. Type system: add `TArrStatic`/`TArrDyn` split in `ast.ml`, `typing.ml`
- [x] A2. Runtime layout: `mcaml:scratch cells`, `mcaml:permheap cells`, bump counters
- [x] A3. IR: `IHeapAlloc`/`IHeapGet`/`IHeapSet` in `cfg.ml`
- [x] A4. knormal lowering for `Array.make` / dynamic access
- [x] A5. cfg_build emits new IR ops
- [x] A6. codegen_helpers: shared `scratch_get`/`scratch_set`/`permheap_*` macro helpers
- [x] A7. codegen_cfg: lowering for the three new ops
      (Surface builtin name is `array_make`, not `Array.make` — lexer forbids `.` in idents.)
- [x] A8. Allocator init lines in `init.mcfunction` (via `tools/pack_datapack.py`)
      (Already landed in A2 `204c42a` — six §4.3 lines are in `INIT_MCFUNCTION`.)
- [x] A9. Per-invocation arena reset at public entry-point exits
- [x] A10. Test program + simulator coverage
      (`scripts/test_dyn_array.mcaml` has four straight-line sub-tests — basic,
      read-modify-write, multi-alloc, mixed static+dyn — validated through
      `/tmp/mcaml_out/test_dyn_array.py` against sim.py with zero simulator
      changes. **Follow-up landed**: cross-function TArrDyn passing and
      for-loops over dyn arrays now work via (a) strict typing arms for
      `array_make`/`array_get`/`array_set` surfacing `TArrDyn TInt`,
      (b) `normalize_fun` seeding `dyn_env` for TArrDyn params (cfg_build's
      scalar `_` arm already emits the handle `ICopy`, no edit needed),
      and (c) a `darr` surface keyword (`T_DARR` → `TArrDyn TInt`) so
      helpers can declare dyn-array params. Validated by
      `scripts/test_dyn_array_params.mcaml` against `sim.py`: cross-func
      read (60), cross-func fill (45), and in-function for-loop over a
      dyn array (30).)

### Phase B — Lists and cons
- [x] B1. Parser: `::`, `[]`, list literal desugaring in `parser.mly`/`lexer.mll`
      (CONS token in lexer, `%right CONS` between comparison and PLUS/MINUS,
      list literal desugars in parser action via `List.fold_right`.)
- [x] B2. Type system: `TList of typ`
      (v1 monomorphic int lists: `Nil → TList TInt`, `Cons` rejects
      non-int head and non-`TList TInt` tail. `head`/`tail`/`is_nil` go
      through App fallback — no fun_sigs entries needed for v1.)
- [x] B3. Runtime: `mcaml:conspool pairs` pool, `$conspool_next`
      (No-code-change task — the three pieces all pre-landed:
      reserved slot `$conspool_next` in `codegen_cfg.ml` (A2), init
      line + counter zero in `tools/pack_datapack.py` INIT_MCFUNCTION
      (A2/A8), reset at public entry-point exits in `main.ml`
      `reset_cmds` (A9). **Deferred to B4/B5**: the reset is gated on
      `any_dyn_heap_use` which currently only scans `IHeap*` — once
      `ICons`/`IHead`/`ITail` exist, that predicate must also count
      those so a cons-only program still gets the conspool reset.)
- [x] B4. IR: `ICons`/`IHead`/`ITail`
      (Added to `cfg.ml` with instr_def/instr_uses/string_of_instr.
      All three are side-effecting in `dce.ml` (ICons bumps counter +
      writes NBT; IHead/ITail read NBT via macro helpers with the
      same hidden `$arr_result` write as IArrGet). Identity-passthrough
      arms added to copy_prop, inline, monomorphize, unroll,
      regalloc_cfg, const_fold (kill dest), cost (5/3/3 per §5.1–5.2),
      and sroa (note_use for handle operands). local_cse reaches them
      via the Cfg.instr_def fallback. codegen_cfg has a failwith stub
      pending B6. `main.ml`'s `any_dyn_heap_use` gate now counts cons
      ops so cons-only programs trip the arena reset (resolves the
      B3 deferral).)
- [x] B5. knormal/cfg_build lowering
      (kexpr gains `KCons`/`KHead`/`KTail`; `normalize_to` rules:
      `Nil → KInt -1`, `Cons(h,t)` normalizes both operands to temps
      then emits `KCons(d, t_h, t_t)`, `head`/`tail` dispatch from the
      App arm before the generic fallback, and `is_nil` desugars to
      `KBinOp(Eq, t_l, -1)` — no new primitive needed. cfg_build adds
      three one-line arms lowering to `ICons`/`IHead`/`ITail`. Probe
      `fun main()=is_nil([])` codegens cleanly and returns 1; a
      `cons/head/tail` program reaches codegen and fires the B6
      failwith stub as expected.)
- [x] B6. codegen: `cons_head.mcfunction`, `cons_tail.mcfunction`, 5-command `cons` inline
      (codegen_helpers gains `cmd_cons` (5 inline cmds, no macro
      dispatch — `pairs[-1]` is a literal NBT path so the store-result
      lines need no helper), `cmd_cons_head`/`cmd_cons_tail` (3 cmds
      each, parameterized field), and `cons_head_body`/`cons_tail_body`
      single-line macro emitters. codegen_cfg state grows
      `emit_cons_head`/`emit_cons_tail` flags; per-instruction lowering
      pushes the right command sequence and flags helper emission;
      after the block walk, helpers are appended (deduped across
      functions by main.ml's filename-level pass). Probe
      `1::2::3::[] |> tail |> head` dumps with exactly 5/3/3 commands
      per op as expected, plus the conspool reset firing because of
      the B4 gate extension. End-to-end sim run is gated on B8's
      sim extension for `mcaml:conspool`.)
- [x] B7. Nil sentinel handling (`-1`), `is_nil` builtin
      (Most pieces landed in B5: `Nil → KInt -1` (§4.2 sentinel) and
      `App("is_nil", [arg])` desugars to `KBinOp(Eq, t_l, -1)`.
      B7 closes the gap by adding a typing arm `App("is_nil", _) →
      TBool` so the result can sit directly in an `if` condition
      (the App-fallback would otherwise return TInt, which `if`
      rejects). head/tail still ride the App-fallback-returns-TInt
      trick because their results are int-handle vregs and consumers
      don't care about the static type. The §4.2 reference
      lowering is "execute if score … matches -1" (1 cmd); the
      current Eq-against-temp lowering produces 2 cmds (one IConst,
      one IBinOp Eq → 1 cmd via cmd_score_binop). Functionally
      equivalent; the 1-cmd form is a future peephole, not a B7
      command-budget violation.)
- [x] B8. Test program (e.g., tail-recursive Fibonacci list)
      (`scripts/test_cons.mcaml` has 6 entry points: head/tail
      traversal, is_nil on empty/non-empty, tail-recursive `sum_list`
      driven from a 5-element list, and a cross-function
      `build3 → sum_list` round-trip exercising list-as-handle param
      AND return. Validated through `/tmp/mcaml_out/test_cons.py`
      against sim.py with one extension — the `data modify ...
      append value {h:0,t:0}` parser now handles compound literals so
      cons cells materialize as real dicts that the subsequent
      `pairs[-1].h`/`.t` store-result lines populate. ICons=5 cmds
      verified by command count on `test_basic` (3 cells × 5 cmds).
      **Pivot during B8**: added `list` as a parser type keyword
      (lexer T_LIST + parser arm desugaring to `TList TInt`) and
      typing arms for `head`/`tail` returning `TInt`/`TList TInt`,
      because the let-binding pattern `let l = 1::[] in sum_list(l)`
      gives `l : TList TInt` and the App arg-type check rejected
      passing it where the param declared `int`. The `list` keyword
      lets helpers declare `(l: list) : list` and types unify.)

### Phase C — Regions and copy-on-escape
- [x] C1. Surface syntax: `region (fun () -> body)` in parser + AST
      (Dedicated production `REGION LPAREN FUN LPAREN RPAREN ARROW
      seq_expr RPAREN` strips the thunk at parse time and builds
      `Region of expr`. New tokens: `REGION` keyword, `ARROW` (`->`).
      Inert structural arms in `alpha.ml`, `for_lift.ml` (both
      `free_vars` and `walk`). `knormal.ml` uses a loud failwith stub
      `"Region: lowering lands in C3"` — same pattern B4 used before
      B6 — so any pre-C3 program that reaches knormal with a Region
      node fails fast rather than silently inlining the body without
      the snapshot/restore pair. Probe
      `fun main() : int = region (fun () -> 42)` reaches the stub,
      proving parse → alpha → for_lift → typing all accepted the
      syntax. All five canaries byte-identical pre-/post-edit.)
- [x] C2. Type-level region tracking in `typing.ml` (minimal — just escape rule)
      (Single trivial arm: `| Region e -> infer env e`. No
      representability check, no escape rule, no region polymorphism
      — v1 accepts all return types per §C2 and relies on the C5
      per-type deep-copy walker for correctness. Landed together with
      C1 because it's a one-liner and the two form a frontend-only
      unit that emits no new IR.)
- [x] C3. IR: `IRegionEnter`/`IRegionExit`
      (Two new ops in `cfg.ml`: `IRegionEnter of int` and
      `IRegionExit of int * vreg option * Ast.typ`. Both side-effecting,
      never DCE'd (`dce.ml`), never CSE'd (side-effect flag falls
      through via `instr_def`). `IRegionEnter` has no uses/defs;
      `IRegionExit`'s return vreg is threaded through liveness,
      copy_prop, inline, monomorphize, unroll, sroa, regalloc_cfg —
      identity-passthrough arms only. Cost model: 2 cmds enter, 3 cmds
      exit (primitive-return placeholder; heap-return walker cost
      lands with C5).
      kexpr gains `KRegion of kexpr`. `knormal.ml` lowers
      `Region body → KRegion (normalize_to dest body)` so the body's
      final write still lands in the caller's dest slot (scoreboards
      survive NBT truncation, so no extra plumbing needed on the
      primitive path). `tco.ml` does NOT recurse into `KRegion` —
      tail calls inside a region body stay as plain `KCall → ICall`
      so the region exit still runs before the function returns.
      `cfg_build.ml` threads a `region_depth` counter through `lower`;
      `KRegion` emits `IRegionEnter k`, recurses with `k+1`, emits
      `IRegionExit (k, None, TUnit)` (placeholder type until C5
      plumbs the per-type walker dispatch), with a `block_is_sealed`
      guard so an exit is never appended to an already-terminated
      block. Cap is 4 lexical levels per §4.1; `k > 3` fails loudly
      at lowering time.
      `codegen_cfg.ml:is_reserved_slot` grows 8 entries
      (`$region_save_<k>_{scratch,conspool}` for `k ∈ [0,3]`).
      Codegen lowering is a failwith stub until C4.
      `inline.ml:is_leaf` rejects any function containing an
      IRegionEnter/IRegionExit — belt-and-braces, since the
      public-entry restriction below already prevents region-bearing
      functions from being inlined.
      `main.ml` adds a post-Phase-1 check: any non-template function
      that contains a region block AND is called by another non-
      template function fails with a clear message. Rationale: region
      save slots are global scoreboard slots indexed by lexical depth,
      and two region-bearing functions on the same call chain would
      clobber each other's level-0 save values, leading to the
      enclosing function's exit truncating back to the callee's save
      mark instead of its own. Lift path (future session): save/
      restore region save slots across non-leaf calls via
      `mcaml:stk frames`; not worth it for v1.
      Probes: `region (fun () -> 42)` reaches the C4 codegen stub
      (proving knormal + cfg_build accept the syntax end-to-end);
      5-level nesting fails at cfg_build; region inside a helper
      function fails at main.ml's public-entry check. All five
      canaries byte-identical vs. pre-Phase-C; `test_dyn_array.py`
      and `test_cons.py` still 8/8 green.)
- [x] C4. codegen: snapshot/restore bump pointers, `data remove` truncation loop
      (`codegen_helpers.ml` gains `cmd_region_enter` (2 score ops),
      `cmd_region_exit_primitive` (2 helper dispatches),
      `region_truncate_scratch_body` / `region_truncate_conspool_body`
      (3 self-guarded commands each: pop tail cell, decrement counter,
      self-recurse while counter > saved). `codegen_cfg.ml` state grows
      `region_exit_levels`; IRegionExit lowering pushes the exit cmds
      and flags the level; after the block walk, per-level
      `region_truncate_<k>_{scratch,conspool}.mcfunction` helpers are
      appended to the function's file list and deduped by filename in
      main.ml. C4 implements the primitive-return path only; heap-
      return walker dispatch lands with C5. Probe
      `region (fun () -> 1::2::3::[] |> head)` emits the expected
      2/5/5/5/3/2 command sequence (enter/cons×3/head/exit), the
      truncation helpers correctly pop back to the saved mark under
      sim, and `$ret = 1` matches the head-of-list semantics.
      **v1 limitation (plan §5.6 correction)**: the truncation helper
      does NOT use tick_guard-style slicing. Yielding mid-helper via
      `schedule ... 1t ; return 0` would return partial work to the
      synchronous caller, which then continues past IRegionExit with
      a dangling pool state. Regions must stay under ~20k cells per
      pool per region to fit Minecraft's maxCommandChainLength. A
      proper async exit sequence is future work — see §12.)
- [x] C5. Per-return-type deep-copy helper generation
      (Type annotation plumbing: `Region of typ ref * expr` in ast.ml;
      parser creates `ref TUnit`; alpha/for_lift share the ref;
      typing.ml's Region arm writes the inferred body type; knormal's
      Region arm reads the ref and produces
      `KRegion of kexpr * typ * string option` carrying both the
      return type and the ambient let-dest (which survives the
      KSeq-flattening of `Let(x, Region, body)` since KSeq otherwise
      lowers its first arg with `~dest:None`). cfg_build threads both
      into `IRegionExit (k, ret, ret_typ)`.
      codegen_cfg dispatches on `ret_typ`: `TInt/TBool/TUnit` use the
      C4 primitive path; `TList TInt` uses the new Strategy-B walker
      path (stash → truncate → rebuild), with `emit_cons_head` /
      `emit_cons_tail` also flagged since the stash walker reads
      cell fields through the existing cons_head / cons_tail macro
      helpers. TArrDyn and other types fail loudly at codegen.
      **Minor refinement to decision #4**: walker files turned out
      level-independent — the stash walker reads from mcaml:conspool,
      writes to mcaml:region_tmp conspool, and terminates on the nil
      sentinel (no save-slot reference); the rebuild walker drains
      region_tmp from the tail and appends to conspool with
      `t := $wr_prev` (no save-slot reference either). Single shared
      `region_walker_list_stash.mcfunction` and
      `region_walker_list_rebuild.mcfunction`, deduped by filename in
      main.ml. Flagged as a simplification against the per-level
      naming originally in #4 since it removed plumbing without
      losing correctness.
      Four new reserved scoreboard slots: `$wr_h` (current child
      handle), `$wr_cache_h` (stashed h-field value), `$wr_prev`
      (previous iteration's new handle; seeds nil), `$wr_tmp_h`
      (rebuild's h-field read), all added to
      `codegen_cfg.is_reserved_slot`.
      Two new storage paths in `tools/pack_datapack.py`:
      `mcaml:region_tmp conspool` (active in v1) and
      `mcaml:region_tmp scratch` (reserved for TArrDyn walker,
      unused). §4.5 documents these.
      Probe:
      `let l = region (fun () -> 1::2::3::[]) in sum_list(l, 0)`
      returns `$ret = 6` under sim.py, with the expected stash →
      truncate → rebuild sequence: build at child positions
      [0..2], stash into region_tmp in walk order (1,2,3), truncate
      conspool back to 0, rebuild by popping region_tmp from the
      tail (3,2,1) and re-appending with `t := $wr_prev` (which
      reverses twice so the final chain is in the original order
      1→2→3→nil at parent positions [0..2]). All five canaries
      byte-identical vs. pre-Phase-C; both Python exit suites still
      green.)
- [x] C6. Test: long-running `region`-wrapped computation with small return
      (`scripts/test_regions.mcaml` has 5 entry points, all returning
      `int` per §4.4's public-entry primitive-return contract:
      `test_region_int` (primitive exit path, 5-element list sum inside
      a region), `test_region_list_return` (walker round-trip — region
      returns `TList TInt`, outer scope sums the copied list),
      `test_region_nested` (depth-2 region nesting verifies that both
      `$region_save_0_*` and `$region_save_1_*` are saved and restored
      in the right order), `test_region_two_sequential` (two regions
      back-to-back in the same function verifies the second region's
      saved-conspool mark tracks the first region's post-exit value,
      not its own pre-enter value), `test_region_loop` (for-loop
      inside a region allocates 30 cons cells over 10 iterations,
      accumulating into a ref; the region exit truncates all 30 back
      to 0 on the way out).
      Test harness `/tmp/mcaml_out/test_regions.py` (not committed —
      same convention as the dyn-array and cons harnesses):
      compile, seed the new `mcaml:region_tmp {conspool,scratch}`
      storage paths in each fresh World (mirrors §4.5's init), call
      each entry point in a fresh World, and assert on BOTH the
      `$ret` value AND three post-conditions — `$conspool_next == 0`,
      `$scratch_next == 0`, and `mcaml:region_tmp conspool == []`
      after the function returns. The post-conditions verify that
      every exit path truly cleaned up and not just that the
      reductions happen to yield the right int.
      Note: MCaml's `for i = lo to hi` is exclusive on `hi` (a
      `for i = 0 to 4` over a 4-element array iterates indices 0..3).
      `test_region_loop` uses `1 to 11` to iterate 10 times;
      documented inline in the test for future readers.
      All five canaries byte-identical vs. pre-Phase-C; all 14
      Python-harness tests green (4 dyn-array + 5 cons + 5 region).)

### Post-memory roadmap (see §13 for design)

The original plan covered Phases A–C. Everything below is new scope added
after the memory work landed, to take MCaml from "functional with heap" to
"general-purpose ML-ish language with MineTorch-usable numerics." Tasks
here are load-bearing design decisions; §13 has the full rationale.

### Phase M — Native Mod operator (prereq for Phase N)
- [x] M1. `ast.ml`: add `Mod` to the `binop` variant
- [x] M2. `lexer.mll`: `%` → `PERCENT` token
- [x] M3. `parser.mly`: `PERCENT` token + precedence-table entry at
      `%left TIMES DIV PERCENT` + inline `binop` arm. No new grammar
      rule — the existing `expr op = binop expr` production picks up
      `Mod` through the inline, so the reduce/reduce hazard from
      adding a dedicated arm is avoided.
- [x] M4. `typing.ml`: extended the `(Add|Sub|Mult|Div), TInt, TInt → TInt`
      arithmetic arm to `(Add|Sub|Mult|Div|Mod)`.
- [x] M5. `knormal.ml` / `cfg_build.ml`: zero edits needed — the BinOp
      arm in knormal (`KBinOp(op, t1, t2)`) and the cfg_build arm
      (`IBinOp(d, op, v1, v2)`) are both generic over `op`, so `Mod`
      rode through both passes without change.
- [x] M6. `codegen_helpers.ml`: added `Mod → "%="` to `op_str`, lowering
      through the existing `cmd_score_binop` path. Emits exactly two
      commands per Mod (copy + `%=`), same cost as any other
      non-comparison binop. 3 cmds if const_fold already elided the
      self-copy; 2 cmds otherwise. Well under the §12.2 budget (the 10-
      cmd add/sub/cmp target; Mod isn't even in the Q16.16 cost table
      because it's an int-level op).
- [x] M7. `const_fold.ml` / `copy_prop.ml` / `dce.ml` / `local_cse.ml`:
      const_fold gained a both-known fold arm for `Mod` with
      div-by-zero protection (matches the existing `Div` arm's
      shape). local_cse's `is_commutative` predicate now lists `Mod`
      on the non-commutative side (grouped with `Sub`/`Div`). copy_prop
      and dce are op-agnostic and needed no edits. strength_reduce
      and cfg.ml's `string_of_binop` also got their `Mod` arms (the
      former rides through its existing `| _ -> None` catchalls so
      Mod simply contributes nothing to the IV classifier; the latter
      maps `Mod → "%"` for CFG dump readability).
- [x] M8. Tests: `scripts/test_mod.mcaml` covers six cases: `13 % 10`
      (small), `1234 % 65536` (fractional-part probe for the Q16.16
      path that lands in N), `20 % 5` (exact multiple → 0), a chained
      `(13 % 10) % 3`, a `let`-bound variable dividend `100 % 8`, and
      a for-loop rmw pattern accumulating `i % 5` across
      `i ∈ [0, 10)`. Validated through `sim.py` with one extension
      (Java-style semantics for the new `%=` op: result sign matches
      dividend, truncation toward zero, matching Minecraft's own
      `scoreboard players operation %=`).
      **[CORRECTED 2026-07-07]**: the trunc assumption above was
      wrong — in-game measurement on 1.21.x (mc_test_suite t05/t08)
      proved vanilla `/=` is floorDiv and `%=` is floorMod. sim.py
      and const_fold.ml now implement floor; MCaml's `/` and `%` are
      floor semantics by definition. See TODO.md "RESOLVED
      2026-07-07" and CLAUDE.md runtime conventions. All five canaries
      byte-identical vs. pre-Phase-M HEAD; all 15 pre-existing Python
      exit-suite tests still green.

### Phase N — Fixed-point Q16.16 numerics
- [x] N1. `ast.ml` / `typing.ml`: retype `Float` literal from `TInt` alias to real `TFloat`; add `TFloat` type
      (Two-file change. `ast.ml`: `TFloat` added to the `typ` variant
      slotted after `TInt`. `typing.ml`: `Float _ → TFloat` (was
      `TInt`). No downstream breakage: knormal's Float arm was
      already a `failwith` (float literals never compiled pre-N), so
      there was no existing path to regress. codegen_cfg's
      region-exit primitive-path match uses a `| _ -> failwith`
      catchall — adding TFloat to the grouped arm lands with N5 when
      the first float-returning function appears. §12.1 guarantees
      uniform int representation so no codegen changes are needed
      for the runtime path. All five canaries byte-identical; all
      15 Python-harness tests still green.)
- [x] N2. `lexer.mll`: `float` keyword → `T_FLOAT`
- [x] N3. `parser.mly`: `typ` arm for `T_FLOAT { TFloat }`, float literal already tokenized
      (N2+N3 bundled since each is a one-liner with no individually-
      testable behavior. Lexer adds `"float" → T_FLOAT` between
      `"int"` and `"bool"`. Parser declares the token, adds
      `T_FLOAT { TFloat }` to the `typ` nonterminal between `T_INT`
      and `T_BOOL`. No menhir conflicts. `(x: float)` now parses as
      TFloat; float literals still fail at knormal until N4.)
- [x] N4. `knormal.ml`: float literal `x` compiles to `KInt (round (x *. 65536.0))`
      (Replaces the pre-Phase-N failwith in knormal's `Float f` arm
      with `int_of_float (Float.round (f *. 65536.0))`. Rounds to
      nearest (half-away-from-zero via OCaml's `Float.round`), which
      is what a user typing a literal expects. Out-of-range literals
      (|x| ≥ 32768, or more precisely: scaled value outside int32)
      fail loudly at knormal time with a clear message — silent
      clamping on a hand-typed literal would hide user errors.
      Probes: `1.5 → 98304`, `-3.25 → -212992`, `32767.0 →
      2147418112` (within int32 max); `99999.0` fails at knormal
      with the range error. All 15 Python-harness tests still green.)
- [x] N5. `typing.ml`: float arithmetic arms (Add/Sub/Mult/Div/neg/compare on TFloat)
      (Design decision: `*` and `/` on TFloat are REJECTED at the
      typing level with a clear error message. Users route through
      explicit `fmul` / `fdiv` App-builtins, matching the project's
      existing pattern for surface-visible primitives (`array_make`,
      `head`, `is_nil`, etc.). Rationale: overloading `*` to dispatch
      on operand type would require knormal to track a per-variable
      type environment, which it currently does not. Making typing
      elaborate (AST-to-AST transform) would be a bigger refactor
      than the whole Phase N track combined. Future Phase E may
      revisit with type-directed dispatch.
      Add/Sub on TFloat are the exception — they reuse `+` / `-`
      because Q16.16 add is scalar-identical to int add
      ((x*65536) + (y*65536) = (x+y)*65536), so no new codegen path
      is needed. Comparisons likewise reuse `<`/`>`/`=`/etc because
      Q16.16 is a monotonic signed encoding — the scoreboard-int
      compare gives the right answer.
      New binop variants `FMult` / `FDiv` added to `ast.ml`,
      threaded through `cfg.ml string_of_binop`, `local_cse.ml
      is_commutative` (FMult commutative, FDiv not), `const_fold.ml`
      (no-fold pass-through for now; Q16.16 fold arms land in N9),
      and `codegen_helpers.ml cmd_score_binop` (explicit failwith
      stub pending N6/N7 lowering — same pattern as B4/C1 used
      before their codegen landed).
      New App builtins typecheck: `fmul(a, b): float` requires both
      args TFloat, `fdiv(a, b): float` same, `neg_f(a): float`
      requires one TFloat arg. knormal lowers `fmul`/`fdiv` to
      `KBinOp(FMult/FDiv, t1, t2)` via a dedicated App arm (matches
      `head`/`tail`/`is_nil` pattern); `neg_f` desugars to
      `KBinOp(Sub, t_zero, t_a)` so no new codegen path is needed.
      Probes: `1.5 + 2.25` emits int-level `+=` on encoded values
      (98304 + 147456 = 245760 = 3.75 * 65536 ✓); `neg_f(3.5)`
      emits `0 - 229376 = -229376 = -3.5 * 65536` ✓;
      `1.5 < 2.5` emits `execute store success … if score … < …`
      returning true (scalar compare is monotonic on Q16.16);
      `1.5 * 2.0` fails at typing with a clear pointer to fmul;
      `fmul(1.5, 2.0)` reaches codegen and hits the N5 failwith
      stub as expected. All 15 Python-harness tests still green.)
- [x] N6. `codegen_helpers.ml`: `fixed_mul.mcfunction` helper (~3 cmds with pre-shift, ~8 cmds with split-half variant; pick one, document tradeoff inline)
      (Went with **inline pre-shift**, NOT a helper file. Rationale:
      helper-file dispatch costs a `function mcaml:__fmul` call (1 cmd)
      plus parameter copies (2 cmds in + 1 cmd out = 3 cmds at the
      caller) on top of the helper's own ops, totaling 9 cmds per
      FMult. Inline pre-shift is 5 cmds per call (4 when regalloc has
      aliased `d = v1`), strictly better for hot-path matmul. The
      split-half variant would preserve all 16 fractional bits but
      costs ~8 cmds — worth it only if a workload actually hits the
      precision floor of pre-shift (bottom 8 bits of each operand
      discarded). NN activations around |x| ~ 1 with 5 significant
      digits are unaffected; values near 1/256 lose meaningful
      precision. Documented inline in cmd_score_binop's FMult branch.
      Sequence emitted per FMult:
          $fmul_t = v2
          $fmul_t /= $c256
          d       = v1          # elided if d = v1
          d       /= $c256
          d       *= $fmul_t
      Two new reserved scoreboard slots added to
      `codegen_cfg.is_reserved_slot`: `$c256` (literal 256 — scoreboard
      operation has no immediate-int form) and `$fmul_t` (destructible
      scratch copy of v2 so v2 stays live for any consumer after the
      FMult). `tools/pack_datapack.py` INIT_MCFUNCTION gains
      `scoreboard players set $c256 vars 256`; `/tmp/mcaml_out/sim.py`
      World constructor seeds `$c256 = 256` to mirror that init for
      test harnesses that construct a fresh World without running
      init.mcfunction.
      Intermediate overflow safety: `(v1>>8) * (v2>>8)` fits in int32
      exactly when the true product is within Q16.16 range
      (|x*y| < 32768), so overflow coincides with saturation — no new
      failure modes introduced. Cost (5 cmds) under §12.2's 8-cmd mul
      budget.
      Probes: `fmul(0.5, 0.5) = 0.25` exact; `fmul(4, 8) = 32` exact;
      `fmul(100, 50) = 5000` exact; `fmul(0.1, 0.1)` gives 0.00954 vs
      true 0.01 (4.6% relative error, as documented for the pre-shift
      variant). N7 adds FDiv following the same pattern; N9 adds the
      const-fold arm with Q16.16 semantics.
      All five canaries byte-identical; all 15 Python-harness tests
      still green.)
- [x] N7. `codegen_helpers.ml`: `fixed_div.mcfunction` helper
      (Went with **inline scale-up numerator**, same rationale as N6:
      helper-file dispatch adds ~3-5 cmds of call overhead per op.
      Sequence (4 cmds, 3 when d = v1):
          d = v1                   # elided if d = v1
          d *= $c256                ; d = a * 256
          d /= v2                   ; d = (a * 256) / b
          d *= $c256                ; d = ((a*256)/b) * 256 = (a*65536)/b
      Derivation: want c_encoded = (a * 65536) / b, but `a * 65536`
      overflows int32 for |a| > 2^15. Split the 65536 scale into
      two 256 multiplies around the divide. Constraint: the DIVIDEND's
      true value must be < 128 or the first `*= $c256` overflows.
      For NN inference this holds because dividends are activations
      (O(1) post-normalization). Values beyond 128 would need a
      split-half variant (~10 cmds, not implemented in v1).
      Reuses `$c256` from N6 — no new reserved slots. Divide-by-zero
      is NOT guarded; real Minecraft raises an error, sim.py's `/=`
      arm returns 0 silently.
      Probes: `fdiv(6, 2) = 3` exact, `fdiv(1, 4) = 0.25` exact,
      `fdiv(10, 3) = 3.332` (0.04% rel err vs 3.333...), `fdiv(100, 7)
      = 14.285` (0.004% rel err). Non-exact cases lose precision
      at ~1/65536 ≈ 1.5e-5 per result LSB, which is the Q16.16 floor.
      All five canaries byte-identical; all 15 Python-harness tests
      still green.)
- [x] N8. `cfg.ml`: decide between `IFixedMul`/`IFixedDiv` as new IR ops vs reusing `IBinOp` with typed operand metadata — go with the latter if feasible, to reuse the existing optimization stack
      (Decided in N5: **reuse IBinOp** with new `FMult` / `FDiv`
      variants on the `binop` constructor. Rationale: every existing
      optimization pass (copy_prop, dce, inline, monomorphize, unroll,
      regalloc_cfg, liveness, cost, sroa) rides through IBinOp
      op-agnostically, so adding new binop variants required zero
      changes to any of them. Only the three op-aware passes —
      local_cse (commutativity map), const_fold (both-known fold
      arm), codegen_helpers (lowering) — needed explicit arms. The
      alternative (`IFixedMul`/`IFixedDiv` as separate instrs) would
      have forced identity-passthrough arms in all 10+ optimization
      files, which is the B4/C3 pattern for instruction-level concerns
      (side-effecting ops, guard-chain pinning, etc.) — but FMult/FDiv
      have neither side effects nor special dataflow, so the binop-
      variant approach is strictly lower-surface.
      Non-goal: typed operand metadata on IBinOp. That would require
      every existing IBinOp construction and match site to learn the
      new field, which is a much larger diff than adding two variants.
      This task was documentation-only; the decision was implemented
      as part of N5's commit `753fc6b`.)
- [x] N9. `const_fold.ml`: fold `IFixedMul(IConst a, IConst b)` to `IConst ((a * b) lsr 16)` with overflow trap
      (Crucial invariant: folded and unfolded paths must produce
      byte-identical scoreboard results, or bisect across a fold
      boundary would yield false positives. The fold formulas
      therefore mirror the **runtime** lowerings exactly — including
      their precision loss — rather than using the mathematically
      exact `(a * b) lsr 16`:
        - FMult: `(ka / 256) * (kb / 256)`  (matches N6 pre-shift)
        - FDiv:  `((ka * 256) / kb) * 256`  (matches N7 scale-up)
      Both originally used OCaml integer division (truncating).
      **[CORRECTED 2026-07-07]**: vanilla `/=` floors (measured
      in-game, mc_test_suite t05/t08), so these fold arms — and the
      integer Div/Mod arms — now use `floor_div`/`floor_mod` in
      const_fold.ml, preserving the fold/runtime byte-parity
      invariant. Int32 overflow at any step skips the
      fold (since OCaml's 63-bit int would produce a value the
      runtime couldn't represent); the runtime instruction then fires
      as usual.
      Algebraic simps (FMult by 0 → 0, FMult by 1.0 → a,
      FDiv by 1.0 → a) deliberately NOT added: FMult by the Q16.16
      encoding of 1.0 (= 65536) gives `(ka/256) * (65536/256) =
      (ka/256)*256`, which is only equal to ka when ka is a multiple
      of 256. Folding to a copy would observably change the low 8
      bits. Same issue for FDiv by 1.0. Skip both — the runtime
      performs the shift-shuffle correctly.
      Probes: `let x = fmul(1.5, 2.0)` folds to `IConst 196608`
      (= 3.0 * 65536, exact); `let x = fmul(0.1, 0.1)` folds to
      `IConst 625` (= lossy runtime value); `let x = fdiv(10, 3)`
      folds to `IConst 218368` (byte-identical to the runtime-
      computed value from N7 probes). All 15 Python-harness tests
      still green.)
- [x] N10. `main.ml` / `tools/pack_datapack.py`: extend init to reserve any new scoreboard slots
      (Closed out with N7's discovery that FDiv reuses `$c256` from
      N6 and needs no dedicated scratch — the scale-up-numerator
      approach operates entirely in the dest slot. Final slot
      reservations: `$c256` initialized to 256 in INIT_MCFUNCTION and
      sim.py's World constructor; `$fmul_t` is a scratch-only slot
      (no init needed, the first FMult writes it). Both are in
      `codegen_cfg.is_reserved_slot`. No changes to `main.ml` — the
      driver's reset sequence touches pool counters, not constants,
      and `$c256` is intentionally NEVER reset (would break every
      subsequent fmul/fdiv call). Documented in §4.1's extension.)
- [x] N11. Tests: `scripts/test_fixed_point.mcaml` covering add/sub/mul/div, round-trip, overflow saturation, int↔float conversion
      (N11 required int↔float conversions so added `to_float`/`to_int`
      as App-builtins first. `to_float(a)` lowers to `KBinOp(Mult,
      a, 65536)`; `to_int(a)` lowers to `KBinOp(Div, a, 65536)`. No
      new codegen — they ride through the existing Mult/Div path.
      Constraint: `to_float(a)` overflows int32 for |a| >= 32768; not
      runtime-guarded, caller's responsibility.
      `scripts/test_fixed_point.mcaml` has 16 entry points:
      test_add, test_add_raw, test_sub_raw, test_neg_raw,
      test_mul_exact_raw, test_mul_lossy_raw, test_div_exact_raw,
      test_div_nonexact_raw, test_to_float_raw, test_to_int,
      test_cmp_lt, test_cmp_eq, test_cmp_gt_neg, test_mixed_pipeline
      ((1+2)*1.5 round-tripped via to_int), test_dot3_raw (three-
      term vector dot product, inputs chosen as clean powers-of-2
      fractions so the pre-shift mul is exact), and test_accum_raw
      (tail-recursive accumulation of 0.5 ten times, exercising the
      loop path with float add).
      Deliberate omission: overflow saturation is not tested because
      sim.py uses Python bignum arithmetic and doesn't wrap int32.
      Real Minecraft wraps; the runtime behavior at |x| > ~32k is
      wrap-to-negative per §12.2. A saturation test would require
      extending sim.py with a per-op int32 wrap, deferred until a
      workload demands it.
      Harness `/tmp/mcaml_out/test_fixed_point.py` (not committed;
      same convention as the A/B/C harnesses) compiles, runs each
      entry in a fresh World, asserts on the raw scoreboard int, and
      prints the decoded real value alongside the true float for
      immediate regression visibility. All 16 cases green on first
      run. MineTorch's critical path is now unblocked pending
      Phase Math (transcendental library). All five canaries still
      byte-identical; all 3 pre-existing exit suites still green.)

### Phase G — Global static arrays (prereq for Phase Math LUTs)
- [x] G1. `ast.ml` / parser: `Val of string * expr` already present,
      parser already accepts top-level `val name = [| ... |]`. No edit
      needed.
- [x] G2. `knormal.ml`: `global_arr_env` / `global_arr_dims` tables
      persisted across `normalize` / `normalize_fun` via `reseed_globals`,
      so per-function arr_env still starts fresh but resolves global
      names to their stable aids. `register_global_array name aid length`
      exposed for main.ml.
- [x] G3. `typing.ml`: `global_vals : (string, typ) Hashtbl.t` + the Var
      arm falls back to it after the local env lookup, so function
      bodies see globals as if they were free-variable bindings of the
      declared type. `register_global_val` exposed for main.ml.
- [x] G4. `main.ml`: collects `Val` defs from the program, requires
      RHS = array literal, restricts elements to `Int`/`Float` literals
      (float literals get the same Q16.16 encoding knormal applies),
      assigns the stable aid `__g_<name>`, registers with both
      Typing and Knormal BEFORE Phase 1 runs. Then after Phase 3 and
      before tick-split, synthesizes `__globals_init.mcfunction` with
      one `data modify storage mcaml:heap __g_<name> set value [...]`
      line per global. Emission is conditional on non-empty globals
      list so canary programs without `val` defs stay byte-identical.
- [x] G5. `tools/pack_datapack.py`: adds `LOAD_JSON_WITH_GLOBALS` with
      `["mcaml:init", "mcaml:__globals_init"]` and picks that variant
      when `__globals_init.mcfunction` is present in the compiled
      source set; falls back to the original `["mcaml:init"]` otherwise.
      Canary-safe.
- [x] G6. Tests: `scripts/test_globals.mcaml` has five entry points —
      dynamic-index read, for-loop accumulation over a global,
      cross-function helper (helper reads globals, caller dispatches),
      float-encoded LUT (same storage, Q16.16 elements), and
      compile-time static-index read. Harness
      `/tmp/mcaml_out/test_globals.py` runs `__globals_init` before
      each test to mirror the datapack load sequence. All 5 green on
      first run.
      **Limitations (v1):** val RHS must be a literal array (no
      computed globals); elements must be Int or Float literals
      (no references to other vals or consts); no runtime mutation
      (globals are read-only by convention — there's no compiler
      check, but writing through `[i] :=` would corrupt subsequent
      calls since the store persists until the next datapack load).
      **Cost:** dynamic-index read is 4 cmds at the caller + 1 in
      the macro helper (same path as regular static-array dynamic
      reads). Static-index reads fold to 1 cmd via IArrGetStatic.
      No per-call LUT init cost — populated once at datapack load.
      All five canaries byte-identical vs. pre-Phase-G HEAD; all 4
      pre-existing Python exit suites still green (31 tests). New
      test_globals.py harness passes 5/5.

### Phase Math — Transcendental library (rides on N, pure MCaml source)
- [x] Math1. `lib/math.mcaml`: `exp_fixed`, `log_fixed` via range reduction + 256-entry LUT (see §13 for the Q16.16-specific decomposition)
      (Math1a commit `c1acdc6` landed exp_fixed via int_exp_lut[11] +
      frac_exp_lut[256]. Positive-only variant (x in [0, 10)) to stay
      under the branch-overhead command count; negative handling is
      the caller's responsibility via `fdiv(1.0, exp_fixed(neg_f x))`.
      Cost: 21 cmds/call, 40% over the original §12.2 target but
      13× better than the no-LUT fallback. Precision ~0.26% worst
      case (exp(9.9)), typical <0.1%. The 15-cmd budget in §13.4
      was based on a faulty LUT-cost assumption; see §13.4 for the
      corrected ≤25 target.
      Math1b commit `0330e17` landed log_fixed via iterative
      doubling/halving range reduction + log_frac_lut[256]. Two
      recursive helpers (log_reduce_up, log_reduce_down) each with
      a single self-tail-call so TCO fires cleanly. Cost varies
      with x: ~35 cmds near x=1, up to ~120 near Q16.16 extremes;
      typical NN values land at ~50-60 cmds. Precision ~0.27%
      worst case at log(e), mostly <0.01% elsewhere.
      Both require Phase G's shared-static-LUT infrastructure — the
      LUTs are top-level vals populated once by __globals_init
      at datapack load. See §13.4 for the cost budget correction
      and the deferred optimization track.)
- [x] Math2. `lib/math.mcaml`: `sigmoid`, `tanh`, `gelu` as LUT-only (no reduction needed since domain is bounded)
      (Commit `8ca0dd2`. Each uses a 256-entry table over a bounded
      domain with clamping outside: sigmoid over [0,8), tanh over
      [0,4), gelu over [-4,4). sigmoid and tanh exploit their
      symmetries (1-x and -x respectively) so only half-domain LUTs
      are needed; gelu is asymmetric so covers the full range.
      gelu uses the exact erf-based form, not the tanh approximation —
      matches PyTorch's default and avoids a source of
      training/inference divergence.
      Cost: ~15 cmds per call (bounds check + LUT dispatch + minor
      arithmetic for the symmetric reflection). Precision ~5e-5
      absolute at bucket centers, up to ~1-2% at bucket edges; fine
      for NN activation functions which saturate heavily.)
- [x] Math3. `lib/math.mcaml`: `relu_f`, `vec_add_f`, `vec_scale_f`, `dot_f`, `matmul_f` (tensor primitives for MineTorch)
      (Commit `ae386e0`. Scope reduced per §13.9: relu_f ships as a
      shape-agnostic scalar; vec_add4_f and dot4_f ship as N=4
      demonstrations to validate the fmul/fdiv/raw_of_float pipeline
      composes inside real tensor loops; larger shapes are deferred
      to MineTorch's per-shape emitter. matmul_f / vec_scale_f are
      NOT shipped because (a) they follow the same monomorphize-
      per-shape pattern as vec_add4_f / dot4_f, (b) hand-written N=4
      variants would be dead templates, and (c) MineTorch's ONNX
      walker will emit them with concrete shapes per layer.
      Supporting compiler edits to make this work:
        - parser.mly: `arr[float, N]` and `mat[float, M, N]` type
          syntax alongside the existing int variants.
        - typing.ml: the `Array elems` arm now accepts uniform-TFloat
          literal arrays, producing TArrStatic(TFloat, n). Runtime
          representation unchanged; the declared element type
          matters downstream so `a[i]` returns TFloat for float
          arrays and flows into fmul/fdiv without a coercion.
      All tensor primitives tested on clean power-of-2 inputs where
      the pre-shift fmul loss is exactly zero; verified exact
      results for relu, dot4_f([1..4], [0.5, 0.25, 0.125, 0.0625])
      = 1.625, and vec_add4_f elementwise.)
- [x] Math4. `tools/pack_datapack.py`: split `math_init.mcfunction` out of `init.mcfunction` so the 5×256 LUT bootstrap lives in its own file
      (Subsumed by Phase G (commit `18d22a4`). Phase G synthesizes
      `__globals_init.mcfunction` from every top-level `val` in the
      compiled program — including lib/math.mcaml's int_exp_lut,
      frac_exp_lut, log_frac_lut, sigmoid_lut, tanh_lut, and
      gelu_lut — and pack_datapack.py's `LOAD_JSON_WITH_GLOBALS`
      already wires `mcaml:__globals_init` into the load tag when
      the file is present. No additional init split is needed:
      Phase G's mechanism is already the "math_init out of init"
      split that Math4 was targeting, just under a more general
      name that also handles non-math globals. The 5 LUTs × 256
      entries ~= 1280 `data modify` lines land in __globals_init
      unchanged, fired once at datapack load.)
- [x] Math5. Tests: cross-validate every function against a numpy reference with per-function tolerance bounds documented in the test
      (Built as `/tmp/mcaml_out/test_math.py`, not committed per the
      existing test-harness convention. Compiles lib/math.mcaml
      concatenated with a generated test wrapper, runs through
      sim.py, decodes Q16.16 return values, and compares to numpy
      references. Tolerance bounds documented inline:
        - exp_fixed: 0.3% relative
        - log_fixed: 0.5% relative with 0.02 absolute-error floor
          near x=1 where relative error is unstable (log(~1) has
          tiny true values)
        - activations (sigmoid/tanh/gelu): 0.02 absolute
      Probe set covers 52 total cases: 11 exp + 12 log + 11 sigmoid
      + 9 tanh + 9 gelu. All 52 pass on first run against
      math.exp/log/tanh/erf + explicit sigmoid/gelu references.
      Falls back from numpy to Python's math module if numpy is
      not installed — scalar-probe tests don't need the full numpy
      machinery.

**MineTorch is unblocked as of commit `ae386e0`.** The transcendental
library exists with validated precision against numpy, the Q16.16
runtime supports all the operations MineTorch's ONNX emitter needs,
and per-shape tensor primitives can be generated directly by
MineTorch's Python codegen. The only remaining work for a first
real ONNX compile is host-side (ONNX walker → .mcaml emission),
which is MineTorch's project, not MCaml's.

### Phase D — ADTs and pattern matching
- [x] D1. AST: `TypeDecl of string * constructor list`, `Match of expr * (pattern * expr) list`, `Pat*` variants
      (`ast.ml` gains `TAdt of string` in typ (nominal ADT reference —
      needed so D2's parser can accept `t` in type positions and D3 can
      type scrutinees), `constructor = string * typ list`, `pattern`
      (PWild/PVar/PInt/PCtor — PInt included because D5's decision
      trees dispatch on `matches N` so int-literal arms are natural),
      `Match` in expr, `TypeDecl` in def. Inert structural arms in
      for_lift (free_vars + walk — pattern binders excluded from fvs;
      walk threads them as TInt per §12.1 uniform representation) and
      alpha's `h`. One deliberate strengthening over "inert": alpha's
      Match arm renames pattern binders like Let/For binders, because
      leaving them unrenamed while the body's vars DO get renamed
      would capture-shift `let r = 5 in match e with Circle(r) -> r`
      to the outer let. knormal gets the loud D5 stub
      ("Match: lowering lands in D5"); typing gets a D3 placeholder
      Error arm. `codegen.ml`'s `compile_def_to_cfg` Val arm widened
      to `Val _ | TypeDecl _ -> None` — declared deviation from the
      "zero codegen edits" guardrail: it's the driver dispatch, not
      command emission, zero behavior change, and without it the
      build has a non-exhaustive-match warning. Suite 66/66 green;
      all five canaries byte-identical.)
- [x] D2. Parser: `type t = A | B of int | C of t * t` syntax, `match e with | p -> e | ...`
      (Lexer: `type`/`match`/`with`/`of` keywords + bare `|` → BAR
      (longest-match keeps `||`, `|>`, `[|`, `|]` intact). Parser:
      TypeDecl production with optional leading BAR; `typ` gains a
      bare-ID arm producing `TAdt name` so ctor fields and fun params
      can reference declared types (existence checked in D3);
      MATCH/pattern grammar with a `BELOW_BAR` virtual precedence
      marker (the BELOW_SEMI trick): `match_arm → pattern ARROW expr
      %prec BELOW_BAR` sinks the arm-reduce below every operator
      token, so arm bodies extend greedily (`p -> e * 2` keeps `* 2`;
      trailing `| arm`s attach to the innermost match, OCaml
      semantics). Without the %prec this surfaced as 17 shift/reduce
      conflicts in one state; with it menhir reports ZERO conflicts
      (only the 3 pre-existing unused-token warnings). Constructor
      application/nullary-ctor expressions need no parser support:
      `Circle(3)` is App, `Point` is Var — typing disambiguates via
      the Capitalized-ctor convention (enforced in pattern position
      by `pattern_of_id`; `_` → PWild). Note the arm-body-is-`expr`
      consequence: `;` ends the match rather than continuing the arm
      body — parenthesize for multi-statement arms. Probes: 3-ctor
      decl + match parses through alpha/for_lift and reaches the D3
      typing placeholder; decl-only program compiles clean. Suite
      66/66; all five canaries byte-identical.)
- [x] D3. Typing: nominal-type environment; pattern typing; exhaustiveness + redundancy check
      (typing.ml gains `adt_decls` (type → ctor list, decl order) and
      `ctor_info` (ctor → owning type, field types, **tag** = decl-
      order index, ready for D4 cells / D5 `matches <tag>` dispatch).
      `register_type_decl` validates: lowercase type names, Capitalized
      ctors, one GLOBAL ctor namespace (OCaml-module-style), and field
      representability — TInt/TFloat/TBool/TList/TAdt allowed; TArrDyn
      rejected in v1 (it's a base+len vreg PAIR per §3.4, not one cell
      field); TRef/TUnit/TArrStatic/TMat/selector/pos rejected. TAdt
      fields must be already-declared or self (source-order, no forward
      refs between decls). main.ml registers decls after alpha and
      BEFORE for_lift, whose walk consults Typing.infer.
      Ctor expressions: guarded `App` arm (arity + field types →
      TAdt) and a Var fallback for bare nullary ctors — no new AST
      node needed; Capitalized-vs-lowercase keeps ctors and fun names
      disjoint (alpha validates fun names lowercase). knormal gets
      ctor stubs on both paths so a well-typed ctor-but-no-match
      program can't silently emit a KCall to a nonexistent function.
      Match typing: scrutinee inferred, patterns checked against it
      (bindings shadow via assoc-prepend), all arm bodies must agree
      with arm 1. Exhaustiveness + redundancy use the full Maranget
      usefulness algorithm (specialize/default matrices, complete-
      signature test per column type, witness reconstruction) — exact
      on nested patterns, not a top-level approximation: probe
      `Leaf(n) | Node(Leaf(a), Leaf(b))` reports witness
      `Node(Node(_, _), Leaf(_))`; int scrutinees never complete
      their signature and the witness synthesizes an uncovered
      literal (`6` for arms 1|5). Redundant arms are hard Errors.
      Duplicate binders (`P(w, w)`) are caught in alpha.ml's
      rename_pattern — after renaming they'd be invisible to typing.
      16-probe battery green (stubs, witnesses, arity/type/cross-type/
      unknown-ctor/dup-ctor errors, greedy-BAR semantics, ADT-typed
      fun params). Suite 66/66; all five canaries byte-identical.)
- [x] D4. Runtime: generalize `conspool` into a single `objpool` with tag-discriminated cells (see §13 decision D.a). Alternative: keep conspool for lists and add a sibling pool per ADT — decide in D4 before touching codegen
      (Option (a) implemented: cons cells now live in
      `mcaml:objpool cells` as `{tag:1, h, t}` compounds; one
      `$objpool_next` counter, one arena-reset path. The h/t field
      names are kept so cons_head/cons_tail stay field-addressed at
      3 cmds; D5's generic ADT cells will use `{tag, f0, f1, ...}`.
      **Tags are per-type**: D3 assigns 0..n-1 in decl order within
      each type, and a tag is only interpreted under the scrutinee's
      static type — tags are NOT globally unique, and that's fine
      because the type checker guarantees a match only ever inspects
      cells of its scrutinee's declared type. Cons's tag is 1 (its
      decl-order index in the builtin list type).
      **ICons stayed at 5 commands, not the sanctioned 6**: the tag
      is a codegen-time constant, so it rides inside the
      `append value {tag:1,h:0,t:0}` literal — no separate tag-write
      command exists. The §13.5 "+1 cmd for the tag write" assumption
      was pessimistic; the same holds for D5 ADT allocation since
      ctor tags are always static. IHead/ITail unchanged at 3 cmds
      (only the storage path moved). Region enter (2 cmds), primitive
      exit (2 dispatches), truncate helper (3 guarded cmds), and both
      C5 walkers kept their §5.6 budgets; the stash/rebuild walkers
      preserve the tag through the region_tmp round-trip via the same
      literal trick (the list walker only ever traverses tag-1 cells).
      Migrated: codegen_helpers.ml (cmd_cons, cons_head/tail bodies,
      region enter/exit, truncate + walker bodies),
      codegen_cfg.ml (reserved slots `$objpool_next` /
      `$region_save_<k>_objpool`, helper filenames
      `region_truncate_<k>_objpool`), main.ml §4.4 reset,
      tools/pack_datapack.py INIT_MCFUNCTION, comments in
      cfg/dce/cost/knormal. sim/sim.py needed ZERO changes — its
      storage model is namespace-generic and its compound-literal
      parser already handles the 3-field cell. Zero live `conspool`
      references remain outside this plan's history.
      Verified: suite 66/66 + async, all four regenerated /tmp
      harnesses green (18 checks: 6 cons + 5 region incl. pool/
      region_tmp post-conditions + 7 dyn-array/params, plus 16
      fixed-point), five canaries byte-identical, command counts by
      CFG-dump/file inspection. The /tmp harnesses were regenerated
      pool-name-agnostic (they detect conspool vs objpool from the
      compiled output) so they now survive this kind of migration.)
- [x] D5. Pattern compiler: decision-tree lowering to nested `if` / scoreboard matches in knormal
      (Full Maranget decision-tree compilation in `knormal.ml`
      (`compile_match`, mutually recursive with `normalize_to`): rows
      carry (patterns, discharged-binder list, arm body); the leftmost
      first-row-refutable column is switched on. ADT columns read the
      scrutinee tag ONCE via `KTagGet` into a temp and dispatch with an
      IConst+IBinOp-Eq chain feeding KIf — scoreboard-only, never one
      storage read per arm. The 1-cmd `execute if score ... matches
      <tag>` direct form is the same future peephole B7 documented for
      is_nil. **Totality handling (documented choice)**: typing (D3)
      guarantees exhaustive+irredundant matches, so the tree has no
      failure leaf — on a complete ctor column the LAST ctor's subtree
      is the untested else-branch (defensive fallthrough to the last
      arm; chosen over a `say` trap because eliding the final test
      SAVES two commands per match and a wrong tag is impossible by
      construction). Single-ctor complete signatures dispatch with zero
      tag reads. Int columns compare the occurrence against each
      literal with the (exhaustiveness-guaranteed) default row as the
      else-branch. Field reads (`KFieldGet`) are emitted once per
      branch and only for fields some sub-pattern inspects or binds
      (they're never DCE'd, so an unused read would be 3 dead cmds).
      Wildcard rows duplicate into specializations (standard decision-
      tree code-size cost; paths are mutually exclusive at runtime).
      Ctor expressions: `App(Ctor, args)`/`Var Ctor` lower to
      `KAdtAlloc(d, tag, temps)`; with no ambient dest the allocation
      is dropped but field sub-expressions still evaluate (Cons arm
      precedent). Nullary ctors allocate uniformly ({tag:k} cell,
      3 cmds — see §13.5).
      New IR: `IAdtAlloc of vreg * int * vreg list` (3 + #fields cmds,
      tag rides in the append literal per the D4 precedent),
      `ITagGet`/`IFieldGet` (EXACTLY 3 cmds each via obj_tag /
      obj_f<k> macro getters, hidden $arr_result write like IArrGet).
      B4/C3 checklist applied: side-effecting in dce; operand-rewrite
      arms in copy_prop (uses + dest-kill), inline, monomorphize,
      unroll, regalloc_cfg; kill-dest in const_fold; note_use in sroa
      (both walks); cost 3+n/3/3; instr_def/instr_uses/string_of_instr
      in cfg.ml; local_cse rides the instr_def fallback; liveness is
      generic. main.ml's any_dyn_heap_use gate counts all three so an
      ADT-only program still gets the §4.4 arena reset. Region returns
      of TAdt fail loudly at codegen (dedicated arm next to TArrDyn's).
      Helper files: `obj_tag.mcfunction` + per-index
      `obj_f<k>.mcfunction`, deduped by filename in main.ml like
      cons_head/cons_tail. sim.py needed ZERO changes (paths are
      namespace-generic).
      Probes verified by CFG dump + command count + sim.py: 3-ctor
      match (tag read once, Rect fallthrough untested, $ret=42, pool
      reset to 0); nested ctor-in-ctor + nullary-only enum +
      int-literal patterns (651 across 6 call sites); ADT built in one
      function, matched in another, match inside a for loop, and a
      TCO'd self-tail-call inside a match arm (31). Inexhaustive-match
      rejection re-probed at typing ("unmatched value: Point").
      Suite 66/66; five canaries byte-identical; all four /tmp
      harnesses green — ICons still 5 cmds, IHead/ITail still 3,
      region budgets unchanged.)
- [x] D6. Retire `TList`/`Cons`/`Nil`/`head`/`tail`/`is_nil` special cases; relower lists onto `type 'a list = Nil | Cons of 'a * 'a list` (or keep the fast path for ints as an optimization, decide in D6)
      (Decided AGAINST retirement — option (b) of §8.10, documented in
      §13.5 before implementation: the TList runtime is committed ABI
      that full retirement would regress (per-mention {tag:0} nil
      cells, +3 cmds on is_nil, C5 walker rewrite — a §13 escalation
      with no win). What landed instead: `[]` and `h :: t` as PATTERNS
      on a TList scrutinee, via dedicated `PNil`/`PCons` AST variants
      (NOT ctor_info entries — Nil/Cons stay out of the nominal-ADT
      namespace so expression typing can never allocate cells behind
      the -1 sentinel). Parser: layered pattern grammar (atom / cons
      chain) gives right-assoc `::` in pattern position with ZERO new
      menhir conflicts and no BELOW_BAR interaction (pattern CONS is
      consumed before ARROW is seen). Typing: check_pattern arms
      (PCons = [TInt; TList TInt], v1 monomorphic), specialize_nil/
      specialize_cons matrices, and a two-ctor complete-signature
      test in `useful` — witnesses are exact: missing-[] reports
      `[]`, missing-:: reports `(_ :: _)`, nested gaps report e.g.
      `(_ :: (_ :: _))` and `(2 :: [])`. knormal compile_match: TList
      column dispatches on the existing 2-cmd Eq-against--1 HANDLE
      compare (no tag read, ever — a non-nil handle always points at
      a tag-1 cell); cons sub-occurrences read through the existing
      KHead/KTail (3 cmds each) under the same used-fields filter as
      KFieldGet, so `h :: _` emits NO cons_tail dispatch (pinned by
      grep in the harness). Zero new IR ops, zero codegen/optimizer/
      sim changes. head/tail/is_nil builtins stay for straight-line
      code; match subsumes the is_nil/head/tail traversal idiom.
      Ctor-in-list patterns are untypeable in v1 (B2: `::` rejects
      non-int heads) — Phase E's job. Verified: probe CFG dump +
      command counts BEFORE suite work (nil arm = 2-cmd compare, cons
      arm = 3-cmd reads, wildcard elision); scripts/test_list_match
      .mcaml (8 entries: []/cons dispatch, binders, wildcard tail,
      tail-recursive sum via match, list-in-ctor, int-literal heads,
      nested cons) + /tmp/mcaml_out/test_list_match.py harness
      (uncommitted, D9 conventions: $ret + §4.4 post-conditions +
      wildcard grep + inexhaustive-rejection probe). Suite 66/66 +
      async; all five prior /tmp harnesses green; five canaries
      byte-identical; ICons/IHead/ITail budgets untouched.)

> Post-D4/D5 in-game MANUAL_TEST.md check completed 2026-07-08:
> combined test_adts + test_cons pack loaded clean, all probed entry
> points matched sim ($ret 42/309/22/15/24) — objpool init, tagged
> cells, and the obj_tag/obj_f<k> macro getters verified in real
> Minecraft.

> Phase D exhaustive in-game verification completed 2026-07-08
> (post-D7/D8): scripts/mc_test_suite_phase_d.mcaml (commit `a7f6784`,
> 40 self-checking entries covering D1–D9 — ADT dispatch incl. the
> elided last-ctor path, nested decision trees, bool/float/list/ADT
> ctor fields, D6 list patterns, D7 tuples incl. eval-order pins, D8
> records incl. chained r.tl.x, pool interleaving, alloc-in-arms)
> packed via pack_datapack.py and run in real Minecraft: ALL 40
> PASSED, $objpool_next = 0 after run_all_d (§4.4 reset confirmed
> in-game). Pre-flight verifier: tools/sim_check_phase_d.py (also pins
> the zero-obj_tag / no-unused-obj_f greps). Phase D is closed.
- [x] D7. Tuples as single-constructor ADTs (sugar): `(a, b)` → `Pair(a, b)` at parse time
      (NOT the parse-time ctor desugar the task line predates — decided
      in §13.5 (commit `08a8b62`) as STRUCTURAL, per the D6 "dedicated
      variants, not namespace entries" precedent: `TTuple of typ list`,
      `Tuple of expr list`, `PTuple of pattern list`. Type surface is
      OCaml's `int * int`: the typ grammar layers into star-separated
      `typ_atom`s while `ctor_typs` keeps top-level TIMES as the field
      separator, so `of int * t` stays two fields and a tuple-typed
      ctor field is written `of (int * int) * t` (typ_atom gains
      `LPAREN typ RPAREN`). Zero new menhir conflicts. Runtime: one
      `{tag:0, f0...}` objpool cell via the existing KAdtAlloc with tag
      0 — 3+n cmds (5 for a pair, verified); components read via
      KFieldGet (3 cmds) under the D5 used-fields filter (`(a, _)`
      emits no obj_f1, pinned by harness grep); a TTuple match column
      is an always-complete single-ctor signature → ZERO obj_tag
      dispatches (pinned by grep). Maranget: specialize_tuple + TTuple
      arms in check_pattern/useful; witnesses render as tuple syntax
      (`(1, _)`, `(Rect(_, _), _)`). Elements follow the D3 ctor-field
      representability rules (TUnit/TArrDyn/TRef/TArrStatic rejected);
      tuple params/returns ride the scalar handle convention with zero
      knormal/cfg_build/codegen edits. Destructuring-let
      `let (a, b) = e in ...` landed as parse-time sugar for a one-arm
      match — typing's exhaustiveness check rejects refutable patterns
      there (`let (0, b) = ...` errors with witness `(1, _)`). Zero new
      IR ops; zero codegen/optimizer/sim edits (one cosmetic arm in
      codegen_cfg's region-return failwith message). Implementation
      commit `14dabd0`.)
- [x] D8. Records as named-field single-constructor ADTs: `{ x = 1; y = 2 }` → `Point(1, 2)` at parse time
      (Decl-level nominal, but per the D6 lesson NO ctor is synthesized
      into ctor_info (a user-spellable name could collide or leak into
      expression typing's ctor fallback). Dedicated AST — `RecordDecl`,
      `Record of (string * expr) list`, `PRecord`, `Field of expr *
      string` — plus typing-side tables `record_decls` (type → decl-
      order fields) and `record_fields` (field → owner/index/type).
      ONE GLOBAL FIELD NAMESPACE mirroring D3's ctor namespace: a field
      name belongs to at most one record type, so literals and `r.x`
      resolve with zero annotations (cross-decl reuse is a decl-time
      error). Record values type as `TAdt name`, reusing the TAdt arms
      for param passing, ctor-field/tuple-element representability, and
      the D5 region-return rejection; adt_decls/record_decls stay
      disjoint. Literals require the EXACT field set (unknown/dup/
      missing = typing errors), evaluate in SOURCE order, and allocate
      `{tag:0, f0...}` in DECL order via KAdtAlloc tag 0 (knormal owns
      the rewrite — the parser owns no field tables, and infer stays
      analysis-only). Patterns may omit fields (missing = PWild); the
      Maranget column normalizes rows to decl-order vectors and then
      dispatches exactly like a tuple: single-ctor complete signature,
      zero obj_tag reads, used-fields filter (omitted/`_` fields emit
      no obj_f<k> read — pinned by grep). Witnesses render in record
      syntax (`{x = 1; y = _}`). Field access `r.x` lands via a new
      DOT lexer token (longest-match keeps `0.5` a FLOAT; selector dots
      live inside the selector token) → 3-cmd KFieldGet; `{`/`}` lexer
      rules land and the pre-existing menhir unused-token warnings drop
      from 3 to 1 (only the IN precedence note remains). Zero new IR
      ops; zero codegen/optimizer/sim edits. Implementation commit
      `6a653db`. Tests: `scripts/test_tuples_records.mcaml` (14 int-
      returning entries per §4.4: tuple round-trip/swap-through-helper/
      destructuring-let/wildcard/nested, tuple-in-ctor + ctor-in-tuple,
      record access/permuted literal/permuted pattern/omitted field/
      cross-function/record-in-ctor, tuple+record match in a for loop)
      + `/tmp/mcaml_out/test_tuples_records.py` (D9 conventions,
      uncommitted: $ret + §4.4 post-conditions + zero-obj_tag and
      no-unused-obj_f grep pins + inexhaustive/redundant rejection
      probes). All 21 harness checks green; suite 66/66 + async; five
      canaries byte-identical; all six prior /tmp harnesses green.)
- [x] D9. Tests: `scripts/test_adts.mcaml` covering variants, nested patterns, exhaustiveness errors, wildcard patterns
      (`scripts/test_adts.mcaml` has 8 int-returning entry points per
      §4.4's public-entry contract: test_ctor_fields (0/1/2-field
      ctors through a helper, complete-signature dispatch),
      test_nullary_enum (nullary-only enum, uniform {tag:k} cells),
      test_nested_patterns (ctor-in-ctor decision tree, the D3
      witness-battery shapes now executed), test_wildcard_binders
      (PVar binds a field, PWild emits NO obj_f read — verified by
      grep on the emitted file), test_int_literals (PInt arms +
      variable default binder), test_cross_function (ADT built in one
      function, matched in another; TCO'd self-call inside a match
      arm), test_helper_returns_adt (handle-return convention), and
      test_match_in_for_loop (match dispatch per iteration over a
      for_lift-synthesized loop).
      Harness `/tmp/mcaml_out/test_adts.py` (not committed — same
      convention as the A/B/C/N harnesses): compiles, runs each entry
      in a fresh World, asserts on $ret AND the §4.4 post-conditions
      ($objpool_next == 0, objpool cells == [] after the arena
      reset). All 8 green on first run; sim.py unchanged.
      Exhaustiveness/redundancy REJECTION stays a typing-time behavior
      pinned by D3's probe battery — re-probed this session
      ("match is not exhaustive — example of an unmatched value:
      Point"); the .py harness only runs well-typed programs.)

### Phase E — Hindley-Milner inference + let-polymorphism

Decisions for the whole phase are in §13.10 (settled before E1/E2 work
began). Headline calls: destructive `TVar of typ option ref` (no
TScheme in typ — schemes live in typing.ml's env, declared deviation
from the E1 wording), scan-the-env generalization, syntactic-value
restriction, 'a list lifted this phase (new E4b), parameterized user
decls (`type 'a option`) deferred to Phase G follow-up, residual tvars
default to TInt at the knormal boundary, annotations optional-but-
checked (return annotations become CHECKED — a strengthening), monotype
self-recursion with source-order generalization.

- [x] E1. `ast.ml`: extend `typ` with `TVar of typ option ref` (schemes stay OUT of typ per §13.10 decision 2)
      (One-line variant addition, commit `634a792` together with E2.
      Zero non-exhaustive-match fallout outside typing.ml — every
      downstream pass matches typ with catch-alls, confirming the
      "knormal and below never see a TVar" boundary needs no new
      defensive arms.)
- [x] E2. `typing.ml`: rewrite `infer` as unification-based, replacing the current equality checker (annotations still required; every behavior + error string preserved; battery green + canaries byte-identical)
      (Commit `634a792`. Engine: `resolve` (path compression), `occurs`,
      `unify` + `Unify_fail`, `unify_msg` (legacy-string preservation),
      `unify_types` (E8-quality default naming both types),
      `zonk_default` (deep resolve, unbound → TInt — the E6 boundary
      helper, already wired into the Region typ-ref write),
      `string_of_typ` with stable 'a/'b tvar naming, env-side
      `scheme`/`mono`/`instantiate` with a shadowing public `infer`
      wrapper so main.ml/for_lift signatures are untouched. Every
      equality check in infer/check_pattern routed through unify with
      its exact pre-E error string (ten-message probe battery verified,
      incl. both D3 witness shapes). check_pattern + `useful` resolve
      types before dispatch; TVar-scrutinee pinning arms added for
      ctor/record/tuple patterns and `r.x` (inert until E4 — no surface
      syntax mints a tvar yet). One internal-op arm: FMult/FDiv BinOps
      keep the generic rejection the old catch-all gave them.
      **§13.10 amendment (documented in-code and below)**: tvars only
      bind to single-scoreboard-int types — `tvar_bindable` rejects
      TArrDyn/TArrStatic/TMat/TRef/TUnit/TSelector/TPos with an
      annotate-explicitly message, closing the "generalized
      `fun pair_up(x) = (x, 0)` applied to a darr silently drops the
      length vreg" miscompile hole; non-uniform params keep requiring
      annotations exactly as today. Full battery green: suite 66/66 +
      async, Phase D 40/40, all seven /tmp harnesses, five canaries
      byte-identical.)
- [x] E3. Let-generalization at `let` bindings; instantiation at uses (syntactic-value restriction per §13.10 decision 3)
      (Commit `c93b1e0`. `is_value` (literals/Var/Nil/Cons-Tuple-Record-
      ctor of values), `generalize` scanning the scheme env PLUS the
      global tables — a tvar shared with another def's still-uninferred
      fun_sigs entry is never quantified, so forward-shared constraints
      can't evaporate at instantiation. `fun_schemes` table with
      per-call-site `instantiate_fun`; App lookup order is fun_schemes
      → fun_sigs (raw monotype: self-recursion + forward calls,
      decision 7) → TInt fallback. The App arg-mismatch message gains a
      "(cannot unify X with Y)" suffix — legacy prefix preserved.
      Behavior-inert while annotations were still required: battery
      green, canaries byte-identical.)
- [x] E4. Annotations on `fun` params and return types become optional
      (Commit `67b56d8`, together with E5/E6. Parser: `param := ID |
      ID COLON typ`, optional return; omitted → `TVar (ref None)`
      minted in the action — no option types, no new AST shape; ZERO
      new menhir conflicts (only the pre-existing IN warning);
      regenerated parser.ml/.mli checked in. `Typing.type_fun_def`
      unifies the declared return with the body type — the decision-6
      strengthening; the full battery confirmed no existing script
      carried a wrong return annotation. Probes: unannotated
      `double(21)`=42, `id` at bool+int in one program=42 under sim,
      return-mismatch error names both types.)
- [x] E4b. Lift B2's monomorphic-list restriction to 'a list
      (Commit `6e48e9c`. Nil mints a fresh elem tvar per mention
      (residuals default to TInt at the boundary — bare `[]` behavior
      preserved); Cons unifies head against the tail's element type
      (new both-types message replaces the B2 "v1 only supports int
      lists" rejection); head/tail/is_nil become 'a-list-generic,
      dropping B8's accept-anything laxity (unification types the
      let-bound-list pattern directly). PCons checks the head
      sub-pattern against the element type — ctor-in-list patterns are
      typeable, closing the D6 scope note — and `useful`'s cons
      specializations thread the column element type (exact witness:
      `(Rect(_, _) :: [])`). Zero runtime/IR/codegen change; `list`
      keyword still = `TList TInt`; region returns of TList non-int
      still fail loudly at codegen (re-verified).)
- [x] E5. `for_lift.ml`: the `walk` env must tolerate unresolved `TVar`s
      (Commit `67b56d8` — ZERO for_lift edits needed. The walk's env
      types share the def's tvar REFS, so synthesized helper params
      ride the same refs; they get constrained through the helper's
      call site during main's typing pass and default with everything
      else in the zonk pass. The oracle's speculative walk-time
      unifications are a subset of real typing's (same expressions,
      laxer App rule — fun_sigs is empty during for_lift), so no
      contradiction is possible. §13.10 E5 corollary documents the one
      pathological edge: a region body whose type is prematurely
      zonk-defaulted at walk time — unreachable in practice because
      region-in-helper is rejected at main.ml (C3).)
- [x] E6. knormal boundary: main.ml zonks each def, binding residual `TVar`s to TInt before `compile_def_to_cfg`
      (Commit `67b56d8`. Phase 1 split into 1a type-and-generalize
      (source order, synthetic helpers skipped), 1b zonk every def via
      `Typing.zonk_default` (destructive bind is safe — ALL typing,
      including the for_lift oracle, is complete), 1c compile. knormal
      and below never see a TVar; `fun f(x) = 7` compiles with x : int.)
- [x] E7. `monomorphize.ml`: template path verification
      (No code change, as predicted. Evidence: `tvar_bindable` makes
      TArrStatic/TMat/TArrDyn unbindable to tvars, so templates remain
      annotation-driven; suite t32/t33 (dotp mono a/b) still emit
      `dotp__arr10_arr11` / `dotp__arr12_arr13` clones; primitives_v1
      canary (arr-param templates throughout) byte-identical through
      the whole phase.)
> Phase E exhaustive self-checking suite (post-E8):
> `scripts/mc_test_suite_phase_e.mcaml` — 42 checks covering the full
> phase surface (core inference incl. partial/checked annotations, TCO
> + non-tail recursion under inference, residual TInt defaulting; id/
> swap/pair/fst/len/append/last instantiated across int/bool/float/
> list/tuple/ADT/record; let-generalization proper; the whole 'a-list
> surface incl. ctor-in-list, tuple/record lists, list-of-lists,
> generic head/tail/is_nil; tvar pinning through field access and
> record/tuple/ctor patterns; darr+for_lift shared-tvar helpers; the
> E7 template path with an inferred scalar param; a deliberate forward
> call; match-in-for-loop; pool interleaving; two inline region checks
> incl. walker copy-out of an inferred-int appended list). Pre-flight:
> `tools/sim_check_phase_e.py` — runs the suite under sim (42/42 +
> §4.4 post-conditions), greps the zero-clones guarantee for all seven
> polymorphic helpers + the dotp3__arr* template clones + the
> obj_tag/obj_f1 elision pins, and fires 12 compile-time rejection
> probes (value restriction, both annotation mismatches, occurs check,
> tvar uniform restriction, N5 float-`*` asymmetry, exhaustiveness/
> redundancy under inferred scrutinees incl. the `(_ :: _)` witness,
> decision-7 poly-use-before-decl, bool comparison, cons element
> mismatch naming both types). Packs clean via pack_datapack.py for
> the in-game run (`/function mcaml:run_all_e`, expect ALL 42 PASSED
> and `$objpool_next` = 0 after).

- [x] E8. Tests: `scripts/test_polymorphism.mcaml` + /tmp harness
      (Commit `ab19836`. 10 int-returning entries per §4.4: id at
      int/bool/list/tuple/ADT, len at three element types, swap at two
      tuple shapes, un-annotated inference from use, E3
      let-generalization proper (`let n = [] in` used at int AND bool
      elems), ctor-in-list dispatch. `/tmp/mcaml_out/test_polymorphism
      .py` (uncommitted, D9 conventions) asserts $ret + §4.4
      post-conditions, greps ZERO clones for id/swap/len (§13.1:
      polymorphic functions compile once), and probes five rejections:
      value restriction (`ref []` at two elem types), annotation
      mismatch, occurs check (actionable), unify-fail naming both
      types, and the tvar single-int restriction (darr needs an
      annotation). 18/18 green. Suite 66/66 + async; Phase D 40/40;
      all EIGHT /tmp harnesses green; five canaries byte-identical
      through the entire phase.)

### Phase F — First-class lambdas (specialization + escape-analysis fallback)
- [x] F1. Parser/AST: `fun x -> e`, `Lambda of (string * typ) list * expr` AST node,
      `TFun of typ list * typ` threaded through the type system (§13.12
      decisions). NO partial application (decision 1, unchanged).
      (Session 2, commit `f492835`. Sub-decision 1
      (lambda params): bare `(string * typ) list` var binders, exactly
      as recommended — no pattern-destructuring lambda params in v1.
      Sub-decision 2 (grammar): `FUN LPAREN params = param_list RPAREN
      ARROW body = expr %prec BELOW_BAR { Lambda(params, body) }` —
      mirrors Fun's production, body at `expr` (not `seq_expr`) with
      the SAME `%prec BELOW_BAR` match_arm already uses, which turned
      out to be REQUIRED, not cosmetic: without it menhir reports 18
      shift/reduce conflicts (ARROW has no declared precedence, so the
      reduce action of a bare `FUN ... ARROW expr` rule is unresolved
      against a shift of any following operator). Region's own literal
      `REGION LPAREN FUN LPAREN RPAREN ARROW ...` production stays a
      fully separate, untouched token sequence (it never builds through
      `expr`, so it cannot interact with the new rule) — confirmed zero
      new conflicts by actually running menhir both before and after.
      **New 4th scope cut discovered during implementation** (not one
      of the 3 the kickoff flagged): arrow-type ANNOTATION surface
      syntax (`f: int -> int`, distinct from the Lambda EXPRESSION
      grammar, which needs none) is scoped to **arity 0 and 1 only**
      this session — `t -> r` and `() -> r` — mirroring G4's own
      single-param scope cut for type application (§13.11 decision 4).
      A true n-ary `(t1, t2) -> r` surface form would need `LPAREN
      nonempty_typ_comma_list RPAREN ARROW typ`, which shares a
      `LPAREN typ` prefix with the existing grouping atom `LPAREN typ
      RPAREN` and cannot be disambiguated by menhir's LALR(1) lookahead
      at the decision point; deferred as a mechanical follow-up. A
      2+-ary LAMBDA EXPRESSION (`fun (x, y) -> ...`) is fully usable
      regardless — only an EXPLICIT annotation for a 2+-ary function
      TYPE is out of v1 scope. `TFun` right-associates (`int -> int ->
      int` = a function returning a function), needed no extra grammar.
      Typing: all 12 functions from decision 1 got their TFun arm
      (`occurs`, `tvar_bindable`, `unify`, `zonk_default`, `copy_with`,
      `free_tvars`, `string_of_typ`, `check_typ_ok`, `subst_typarams`
      recurse; `check_field_type`/`check_record_field_type`/
      `check_tuple_elem` reject, per decision 2). `infer` gained a
      `Lambda` arm (`TFun(param_types, infer body)` — exists mainly to
      serve for_lift's own degraded-mode oracle call, since the REAL
      Phase 1 pass never sees a raw Lambda; F2 converts every one) and
      a NEW "value application" `App` arm inserted before the
      ctor_info/global cascade: when the callee name resolves in the
      LOCAL scheme env to a TFun scheme, the call type-checks as a
      value application (arity-checked, args unified against the
      TFun's params) instead of falling through to the global-function
      lookup. This requires alpha.ml to rename an `App`'s callee too
      when it resolves as a local binder (previously alpha never
      touched `App`'s function-name string at all — call position
      always meant "the literal global function", so a local variable
      could never be invoked via `f(x)` syntax); proven safe for every
      existing program because the rename only fires when `f` is
      found in the alpha env, which no lambda-free program's App
      callee ever is (top-level Fun names are never added to that
      env).)
- [x] F2. Closure conversion IR: one form pre-analysis, treats every lambda
      the same. (Session 2, commit `f492835`. Sub-decision 3: YES, reuses/extends
      for_lift.ml's existing free-variable walk rather than a new
      module — a lambda is lifted exactly like a for-loop helper
      (captures as leading params, `for_lift.ml`'s existing TRef-capture
      filtering reused verbatim), with the ONE structural difference
      that a lambda is a VALUE (may be stored/returned/passed) so its
      occurrence is replaced by a new `Closure of string * expr list`
      AST node (fname + captured-value exprs) rather than an immediate
      call. New `Ast.expr` variant, NOT a new IR layer — this IS "the
      one uniform closure-conversion IR representation" the F2 task
      line asks for: every Lambda, known or escaping, becomes exactly
      one Closure node with zero distinction (F3's job, next session).
      Lambda-lifted helpers are named `<parent>__lam<N>` (deliberately
      NOT containing "__for", so `for_lift.is_synthetic_name`'s
      substring check doesn't mistake them for a for-helper and skip
      their real typing — unlike for-helpers, a lambda helper takes
      every capture as an explicit param and needs ordinary top-level
      typing). `typing.ml` gained a `Closure` arm: looks up the
      helper's already-registered `fun_sigs` entry (populated by
      `build_sigs`, which runs after for_lift appends the helper —
      confirmed by main.ml's phase order), splits its flat param-type
      list at `List.length captured_exprs`, unifies each capture
      against its slot, and types the whole node `TFun(own_param_types,
      ret_type)`. Everything below typing stays a LOUD STUB, same
      posture Phase D's D1 used for Match before D5: `knormal.ml` gained
      a `closure_env` side table (seeded from a TFun-typed param in
      `normalize_fun`, mirroring `dyn_env`'s existing pattern) so
      calling a closure-typed local fails immediately with a clear
      message instead of silently emitting a bogus `KCall` against a
      nonexistent global function named after the vreg; constructing a
      `Closure` (i.e. any lambda actually reaching a `Let`/return/arg
      position) ALSO fails immediately with a clear message. Verified
      by direct smoke test (not just theory): a HOF passing/calling a
      lambda literal types successfully end-to-end and fails loudly at
      knormal exactly at the call; a lambda stored in a tuple is
      rejected at TYPING with the decision-2 message; a closure handle
      that is only ever passed through (never called or constructed in
      that function) compiles and emits real `.mcfunction` files with
      zero stub firing — confirming a closure handle is inert, opaque
      scalar plumbing everywhere except at construction/call, exactly
      as decision 1 intends. `cfg_build.ml` needed NO changes (TFun
      params fall into the existing scalar-copy `_` prelude arm, and
      `is_template`'s TArrStatic/TMat check is unaffected) — confirmed
      by direct read before touching it, per the guardrail's own
      framing. Full battery reverified green with ZERO code changes to
      any file outside {ast.ml, parser.mly/parser.ml, alpha.ml,
      for_lift.ml, typing.ml, knormal.ml}: main suite 66/66+async,
      Phase D 40/40, Phase E 42/42+12 probes, all nine `/tmp` harnesses,
      five canaries byte-identical (verified against
      `canary_hashes_f_baseline.txt`).)
- [x] F3+F4. Escape analysis + specialization. (Session 3, commit
      `48dc9c3`. **F2 completion, done first as this session's own
      prerequisite** (the gap the session-3 kickoff itself flagged):
      knormal's `Closure`/App-through-`closure_env` failwith stubs are
      replaced with a real, uniform, pre-classification lowering — new
      `KClosureMake`/`KApply` kexpr forms and `IClosureMake`/`IApply`
      CFG ops (§13.12 decision 6, full writeup below), threaded through
      every exhaustive-match consumer (dce, copy_prop, regalloc_cfg,
      unroll, const_fold, sroa ×2, inline, monomorphize, cost,
      codegen_cfg's loud F5-deferred stub). A dedicated
      `Let (x, Closure (fname, caps), e2)` knormal arm seeds
      `closure_env` for direct-lambda let-bindings (mirrors the
      existing `Let (x, Ref e1, e2)` arm); a defensive
      `Hashtbl.mem Typing.fun_sigs f` check in the generic `App` arm
      turns the one knowingly-out-of-v1-scope case (a let-bound HOF-
      factory return, e.g. `let g = make_adder(5) in g(10)` — knormal
      has no per-variable type environment to detect this shape) into
      a loud compile error instead of a silent wrong `KCall`.

      New module `closure_spec.ml` (F3+F4 together — implemented as one
      pass, not two, since the classification and the rewrite share the
      same def-tracing walk; see decision 6) runs between `Inline.run`
      and `Monomorphize.run` (`main.ml:212-224`). Same-function case:
      an `IApply` whose closure operand is defined *exactly once* in
      the owning function (cfg_func is non-SSA; a branch-merged def is
      conservatively unresolvable — no reaching-definitions analysis
      needed for a write-once vreg) and traces, through single-def
      `ICopy` chains, to one `IClosureMake`, rewrites in place to an
      ordinary `ICall` — no cloning. Cross-function single-hop case: a
      call argument at a TFun-typed parameter position that resolves
      the same way, where the callee uses that parameter throughout its
      own body *only* as the closure-operand of its own `IApply`s (no
      ref-store/return/self-tail-forward/re-passed-to-another-call —
      all conservatively disqualifying), clones the callee once per
      (callee, resolved lambda identities) key, capped by
      `MCAML_SPECIALIZE_LIMIT` (default 8) clones per source callee.
      **Bug found and fixed during implementation**: the first version
      left the original TFun parameter slot's type unchanged in the
      clone, so the very next fixed-point iteration re-detected the
      same already-specialized position as fresh and re-cloned it,
      nesting mangled names until `iter_cap` cut it off — fixed by
      retiring the resolved position's type to `TInt` in the clone.
      **Second bug found and fixed**: leaving the original closure
      argument in place at the redirected call site kept the
      originating `IClosureMake` artificially live for DCE (an unread
      but still-passed argument still counts as a use) — fixed by
      replacing that argument with a fresh dummy `IConst 0` instead of
      dropping-and-renumbering the whole parameter list. Fully
      specialized-away originals (zero remaining internal callers) are
      retired via `is_template <- true`, reusing the existing "never
      emitted directly" plumbing — justified because a TFun-typed
      parameter, unlike every other param type, can never be supplied
      by an external datapack invocation (`tools/README.md`'s
      entrypoint convention sets scores via `/scoreboard`, which cannot
      construct a closure cell), so such a function is only a genuine
      public entry point if something inside the program still calls
      it.

      Verified end-to-end in `scripts/test_lambdas.mcaml` /
      `/tmp/mcaml_out/test_lambdas.py`: a same-function immediate
      invocation and a cross-function HOF (`apply_twice`-style), both
      with and without captures, all fully specialize (grep confirms
      zero `apply`/`closure(`/`obj_tag`/`obj_f` anywhere in the
      compiled output) with correct runtime `$ret` values under sim.py.
      An ambiguous-merge Escaping probe (`if c then lam1 else lam2`
      feeding a HOF parameter — two distinct `IClosureMake`s reaching
      the same vreg, so def-count ≠ 1) correctly fails loudly at the
      F5-deferred codegen stub rather than silently miscompiling.
      Full battery green: suite 66/66+async, Phase D 40/40, Phase E
      42/42+12 probes, all nine `/tmp` harnesses, five canaries
      byte-identical.

      **What's Known (fully specialized, zero apply-dispatch) after
      this session**: a lambda passed directly as a call argument or
      let-bound then called, either within one function or across a
      single HOF call boundary, with or without captures — reached
      whether or not `Inline.run` happens to have already collapsed the
      intervening call. **What still hits the F5-deferred stub
      (Escaping in v1's conservative sense)**: a closure read back out
      of a `ref`, returned from a function and then called, forwarded
      through *two or more* HOF parameter hops, forwarded across a
      self-tail-recursive back-edge, arriving via ambiguous control-flow
      merge, or beyond `MCAML_SPECIALIZE_LIMIT` — every one of these
      fails LOUDLY (compile-time error), never silently.)
- [ ] F4-followup. Drop-and-renumber the retired parameter slot instead of passing a dummy zero (currently a harmless one-extra-argument-pass per specialized call, not a correctness issue — deferred, not required for the zero-cost claim since the dummy-argument fix already makes the originating IClosureMake DCE-able)
- [ ] F5. Apply-dispatch runtime for escaping lambdas: a closure objpool (reuse Phase D's objpool), the `mcaml:apply` macro-dispatch function, env-unpack prelude at lifted function entry
- [ ] F6. Diagnostics: `[closure]` per-lambda report (specialized vs escaping + reason + cost estimate); `MCAML_STRICT_HOT=1` env knob to promote escaping-in-hot-loop to a compile error; `cost.ml` integration so `tick_split`/`tick_guard` budgets account for apply-dispatch cost
- [ ] F7. Tests: literal lambdas in HOFs specialize; closures captured in ADTs take the apply path; strict-hot mode fires on the right patterns

### Phase G — Remaining ML conveniences
- [ ] G1. Mutual recursion: `fun f ... and g ...`
- [ ] G2. Nested `let rec`
- [ ] G3. Modules / namespaces / qualified names (requires lexer fix to allow `.` in qualified names, or pick an alternative separator)
- [x] G4. Parameterized user type decls (`type 'a option = None | Some of 'a`) — deferred from Phase E per §13.10 decision 4; needs a `'` lexer token (currently illegal char), decl syntax, and arity-checked TAdt application. The D8 record nil-story wants this eventually.
      (Decisions: §13.11, commit `201b09b`. Implementation: commit
      `264801b` — `TAdt` widened to `(string, typ list)`, `TParam of
      string` for decl-side type vars, `TYVAR` lexer token (zero
      collisions), left-recursive postfix type application on
      `typ_atom` (`int option`, nested, `(int*int) option`; `list`
      joins for free, closing the E4b annotation gap), `check_typ_ok`
      arity/scope validator, `subst_typarams` instantiation at every
      ctor application/pattern/Maranget site. Runtime/codegen
      untouched by construction; zero monomorphization of user types
      (zero-clones grep passes). Baseline + all guardrails green: 5
      canaries byte-identical, suite 66/66+async, Phase D 40/40, Phase
      E 42/42, all 8 prior /tmp harnesses, new 22-check
      `test_param_types` harness (15 positive + 6 rejection probes) —
      `scripts/test_param_types.mcaml` + `/tmp/mcaml_out/
      test_param_types.py`. Deferred as follow-ups: multi-param decls
      like `('a, 'b) either` (G4b) and parameterized record decls like
      `type 'a cell = { v : 'a }` (G4c) — neither needed by the D8
      nil-story target, which only needs `node option` as a field
      type.)

## 3. Load-bearing design decisions

These were settled in the design discussion that produced this plan. Do not
revisit without a concrete reason.

### 3.1 Static path is preserved verbatim

`TArrStatic` keeps the current per-aid storage model (`mcaml:heap <aid>`),
keeps `arr_env` in `knormal.ml`, keeps the `#arr:<aid>` monomorphize token,
keeps per-aid macro helper files, and keeps every M3/M4 optimization. The new
dynamic path is purely additive. **Do not unify the two runtimes.** Unifying
would regress SROA/LICM on matmul-shaped workloads, which is the stated target.

### 3.2 Three separate pools with independent bump counters

| Pool | NBT path | Bump counter | Cell layout |
|------|----------|--------------|-------------|
| Per-invocation scratch | `storage mcaml:scratch cells` | `$scratch_next` | flat int |
| Long-lived / permanent | `storage mcaml:permheap cells` | `$permheap_next` | flat int |
| Heap objects (cons + ADTs) | `storage mcaml:objpool cells` | `$objpool_next` | tagged compound |

Heap objects use a tag-discriminated compound layout (D4, §13.5 option a):
cons cells are `{tag: 1, h, t}`; D5's generic ADT cells are
`{tag: <ctor id>, f0, f1, ...}`. Tags are per-type (D3 assigns 0..n-1 in
decl order) and are only interpreted under the scrutinee's static type —
they are not globally unique. The compound layout (not flat ints) keeps
`head`/`tail` field-addressed at 3 commands instead of 5. Dynamic arrays
use flat ints so contiguous `base + idx` addressing works. The pools never
share storage. (Pre-D4 history: cons cells lived in their own
`mcaml:conspool pairs` pool as untagged `{h, t}`.)

### 3.3 No user-visible `free`, no refcounting, no tracing GC

Reclamation happens only at region boundaries, inserted by the compiler. The
programmer writes `cons`, `head`, `tail`, `Array.make`, `arr[i]`, and never
touches memory management. This is the only design that keeps MCaml pure. An
earlier draft of this plan included an opt-in `free` builtin — **that was
rejected** because it makes `cons` no longer a pure expression.

If a future workload genuinely needs finer reclamation than regions can
express, the upgrade path is to layer tracing GC on top of the same IR, not
to expose `free` in the surface language.

### 3.4 Heap values pass by handle, never by copy

A `TList` value is a single int (the handle of the head cell). A `TArrDyn`
value is a pair of vregs `(base, len)`. Function calls, tail calls, and
variable assignments move only these ints — never the underlying cells.
Sharing between old and new lists works because cons cells are immutable
after allocation (purity invariant). The only place heap data is actually
walked is inside copy-on-escape at region exits.

### 3.5 Regions bracket, not free

`region (fun () -> body)` is a structured block, not a free-form effect.
Inside the block, the programmer writes pure functional code. At block exit,
the compiler:

1. Deep-copies the return value into the parent arena (if it contains heap
   handles — primitives are left alone).
2. Truncates the relevant pools back to their pre-block bump positions.
3. Restores the bump counters.

No runtime decides what to reclaim — it's purely lexical. This makes regions
composable and analyzable without any dataflow tracking.

### 3.6 New IR ops are opaque to all existing passes

`IHeapAlloc`/`IHeapGet`/`IHeapSet`/`ICons`/`IHead`/`ITail` are
side-effecting, have explicit vreg reads and at most one vreg write, and do
not interact with SROA/LICM/inline/regalloc beyond standard liveness. Any
pass that needs to understand heap semantics is new code, not a
modification to an existing pass. The existing passes treat new ops the
same way they already treat `IArrSet` — as opaque side-effecting
instructions with explicit operands.

### 3.7 Side-effecting ops must never be DCE'd or CSE'd

Every new instruction that writes to NBT storage or bumps a counter is
side-effecting. `dce.ml` must keep them; `local_cse.ml` must not merge two
allocations at the same program point; `copy_prop.ml` may rewrite operand
vregs but must leave the pool identifier opaque. This mirrors the existing
treatment of `IArrSet`/`IArrSetStatic` — verify in the relevant passes when
adding the new ops.

## 4. Runtime contract

### 4.1 Reserved scoreboard slots (extend `codegen_cfg.ml:96`)

Add these to the reserved-slot set alongside `$ret`, `$arr_result`,
`$tick_iters`, `$arr_set_val`:

- `$objpool_next` — bump counter for the unified object pool (D4; was
  `$conspool_next` pre-D4)
- `$scratch_next` — bump counter for scratch pool
- `$permheap_next` — bump counter for permheap pool
- `$arr_idx` — carrier for pre-computed `base + idx` on dynamic array access
- `$region_save_<k>_scratch` / `$region_save_<k>_objpool` — snapshot slots
  for region entries (one pair per nesting level k ∈ [0,3]; 4 levels of
  nesting is almost certainly enough for v1)

### 4.2 Nil sentinel

`nil : TList t` = the integer `-1` in any `TList`-typed vreg. A freshly
allocated cell's handle is always `>= 0`, so the sentinel is unambiguous.
`is_nil(l)` compiles to `scoreboard players get <l> vars` followed by
`execute if score … matches -1`.

### 4.3 Init sequence

`init.mcfunction` grows six new lines, added by `tools/pack_datapack.py`:

```
data modify storage mcaml:objpool cells set value []
data modify storage mcaml:scratch cells set value []
data modify storage mcaml:permheap cells set value []
scoreboard players set $objpool_next vars 0
scoreboard players set $scratch_next vars 0
scoreboard players set $permheap_next vars 0
```

### 4.4 End-of-invocation reset

Every public entry-point function (anything callable via `/function
mcaml:<name>` from outside the compiled program) gets a compiler-inserted
reset block just before its final return terminator:

```
data modify storage mcaml:scratch cells set value []
scoreboard players set $scratch_next vars 0
data modify storage mcaml:objpool cells set value []
scoreboard players set $objpool_next vars 0
```

`permheap` is **not** reset — it persists across invocations by design.

**Public-entry primitive-return contract.** The reset block zeros the
scratch and objpool pools unconditionally. Any `TList` / `TArrDyn`
handle returned from a public-entry function is therefore dangling
immediately after the caller's `/function mcaml:<name>` dispatch
completes: the handle integer is still sitting in the `vars`
scoreboard, but the NBT cells it pointed to have been wiped. This is
the same constraint CLAUDE.md notes for `$ret` across tick boundaries
("bind it to a ref"). Regions inherit this — Phase C's copy-on-escape
correctly moves a list out of the child region into the parent's
arena, but at the public-entry boundary both arenas get flattened.
C6 test programs must return primitives (int, bool, unit) from any
entry point called directly from Minecraft; if the test wants to
verify a list, sum/fold it inside the entry before returning.

### 4.5 Region_tmp NBT paths (Phase C / C5)

Strategy-B deep-copy walkers (§5.6) stash the return value in a
scratch NBT path before truncation, then re-append from the stash
after truncation. Two new paths, added to `init.mcfunction` via
`tools/pack_datapack.py` alongside the pool paths in §4.3:

```
data modify storage mcaml:region_tmp objpool set value []
data modify storage mcaml:region_tmp scratch set value []
```

These are **storage paths**, not scoreboard slots — §12's escalation
trigger on "new reserved scoreboard slot not listed in §4.1" does not
apply. Permheap has no region_tmp counterpart because permheap is
never truncated.

The objpool region_tmp path is consumed by
`region_walker_list_stash.mcfunction` (appends) and
`region_walker_list_rebuild.mcfunction` (drains from the tail). Both
walkers preserve each cell's `tag` through the round-trip — for the
v1 list walker the tag is statically 1, so it rides in the append
literals at zero command cost. The scratch region_tmp path is
reserved for the TArrDyn walker (not implemented in v1; TArrDyn
region returns fail loudly at codegen time until a future session
extends the walker set).

The "public entry-point" determination in v1 is every top-level `fun`
that isn't called by any other function in the same compilation unit. If
that's too aggressive, reduce to "every function named in the user's source
at the top level." Conservatively over-resetting is safe because the
invariant is that only handles valid at reset time can be observed by the
next caller, and those handles belong to permheap.

## 5. Command-level lowering cheat sheet

Reference for §A6, §B6, §C4. Copy-paste-able into codegen code.

### 5.1 `ICons(d, h, t)` — 5 commands, no macro dispatch

```
data modify storage mcaml:objpool cells append value {tag:1,h:0,t:0}
execute store result storage mcaml:objpool cells[-1].h int 1 run scoreboard players get <h> vars
execute store result storage mcaml:objpool cells[-1].t int 1 run scoreboard players get <t> vars
scoreboard players operation <d> vars = $objpool_next vars
scoreboard players add $objpool_next vars 1
```

D4 note: §13.5 sanctioned a 6th command for the tag write, but the tag
is a codegen-time constant (Cons = 1), so it rides inside the append
literal — ICons stays at 5 commands. D5's ADT allocation gets the same
treatment since ctor tags are always static.

### 5.2 `IHead(d, c)` — 3 commands

```
execute store result storage mcaml:tmp args.idx int 1 run scoreboard players get <c> vars
function mcaml:cons_head with storage mcaml:tmp args
scoreboard players operation <d> vars = $arr_result vars
```

Where `cons_head.mcfunction` is a single line:

```
$execute store result score $arr_result vars run data get storage mcaml:objpool cells[$(idx)].h 1
```

`ITail` is symmetric with `.t`.

### 5.3 `IHeapGet(d, scratch, base, idx)` — 5 commands

```
scoreboard players operation $arr_idx vars = <base> vars
scoreboard players operation $arr_idx vars += <idx> vars
execute store result storage mcaml:tmp args.idx int 1 run scoreboard players get $arr_idx vars
function mcaml:scratch_get with storage mcaml:tmp args
scoreboard players operation <d> vars = $arr_result vars
```

With `scratch_get.mcfunction`:

```
$execute store result score $arr_result vars run data get storage mcaml:scratch cells[$(idx)] 1
```

### 5.4 `IHeapSet(scratch, base, idx, v)` — 6 commands

```
scoreboard players operation $arr_idx vars = <base> vars
scoreboard players operation $arr_idx vars += <idx> vars
scoreboard players operation $arr_set_val vars = <v> vars
execute store result storage mcaml:tmp args.idx int 1 run scoreboard players get $arr_idx vars
function mcaml:scratch_set with storage mcaml:tmp args
```

(No readback — it's a store.) With `scratch_set.mcfunction`:

```
$execute store result storage mcaml:scratch cells[$(idx)] int 1 run scoreboard players get $arr_set_val vars
```

### 5.5 `IHeapAlloc(d, scratch, n)` for constant `n`

```
scoreboard players operation <d> vars = $scratch_next vars
data modify storage mcaml:scratch cells append value 0       (* repeated n times *)
scoreboard players add $scratch_next vars <n>
```

For runtime `n`, emit a TCO'd self-recursive helper `scratch_alloc_loop`
that counts down and appends one zero per iteration. The existing
`tick_guard` pass will automatically slice very large allocations across
ticks with no additional work.

### 5.6 Region enter/exit

Enter (for nesting level `k`):

```
scoreboard players operation $region_save_<k>_scratch vars = $scratch_next vars
scoreboard players operation $region_save_<k>_objpool vars = $objpool_next vars
```

Exit (small-return case, primitive return type):

```
(* scratch: restore counter and truncate list via data remove loop *)
(* repeated (old_next - saved_next) times: *)
data remove storage mcaml:scratch cells[-1]
scoreboard players operation $scratch_next vars = $region_save_<k>_scratch vars
(* same for objpool *)
```

The `data remove` loop must be generated as a helper to stay under
`maxCommandChainLength` when the block allocated a lot. Emit a
`region_truncate_<k>.mcfunction` helper that uses `tick_guard`-style slicing
for large truncations.

Exit (heap return): emit a per-type deep-copy walker before the truncation.
For `TList`, the walker is tail-recursive: it walks the head chain, and for
each cell reads `{h, t}` from the child region and re-allocates the cell in
the parent region, returning the parent-region handle of the copied head.
Base case is nil. For `TArrDyn`, the walker is a simple counted loop that
copies `len` cells into a fresh parent-region allocation.

## 6. Pass-by-pass change matrix

Same as §7 of the design summary, reproduced here with specific file/line
hooks:

| Pass | File | Change |
|------|------|--------|
| `alpha` | `alpha.ml` | None |
| `typing` | `typing.ml` | Add `TArrStatic`/`TArrDyn`/`TList`; escape rule for regions (Phase C) |
| `for_lift` | `for_lift.ml` | None |
| `knormal` | `knormal.ml` | New kexprs for Cons/Head/Tail/dyn-alloc/region; do NOT touch `arr_env` path |
| `tco` | `tco.ml` | None — tail calls with handle params already work |
| `cfg_build` | `cfg_build.ml` | Emit new IR ops; region bracket ops (Phase C) |
| `liveness` | `liveness.ml` | None (new ops have explicit uses/defs) |
| `dominators` | `dominators.ml` | None |
| `licm` | `licm.ml` | None (new ops are side-effecting, not hoistable) |
| `unroll` | `unroll.ml` | None |
| `sroa` | `sroa.ml` | **Confirm** it only pattern-matches on `IArr*` static ops. It already does, but verify |
| `monomorphize` | `monomorphize.ml` | **Confirm** it only triggers on `#arr:<aid>` tokens. No changes |
| `inline` | `inline.ml` | None |
| `const_fold` | `const_fold.ml` | Optional: fold `IHeapGet` with known const idx to direct access |
| `copy_prop` | `copy_prop.ml` | Confirm opaque treatment of pool identifier; rewrite operand vregs only |
| `local_cse` | `local_cse.ml` | Confirm new ops are flagged side-effecting and never merged |
| `dce` | `dce.ml` | Confirm new ops are flagged side-effecting and never dropped |
| `strength_reduce` | `strength_reduce.ml` | None |
| `regalloc_cfg` | `regalloc_cfg.ml` | None — handles flow as ordinary int vregs |
| `codegen_cfg` | `codegen_cfg.ml` | Add lowerings; add reserved-slot entries; emit end-of-invocation resets |
| `codegen_helpers` | `codegen_helpers.ml` | Add shared-helper file emitters |
| `tick_split` | `tick_split.ml` | None |
| `tick_guard` | `tick_guard.ml` | None |
| `main.ml` | `main.ml` | Register new helper files in the per-pipeline emit set |

## 7. Testing protocol

Each phase has a pair of test artifacts that must pass before the phase is
marked complete.

### Phase A exit tests (after A1–A9)

- `scripts/test_dyn_array.mcaml` — programs that:
  - `Array.make 10 0` then fill via `a[i] := i` in a loop, sum via another
    loop, assert result.
  - Pass a `TArrDyn` to a helper function, mutate, return.
  - Mix static and dynamic arrays in the same function to verify the paths
    don't interfere.
- Simulator coverage in `/tmp/mcaml_out/dynsim.py` or extend `sim.py` with
  support for the new storage paths (`mcaml:scratch`, `mcaml:permheap`).
- A/B the existing `test_all.mcaml` and `primitives_v1.mcaml` with and
  without the new code — output must be byte-identical. This catches
  accidental regression on the static path.
- Run with `MCAML_DUMP_CFG=1` on a dyn-array program and eyeball the
  emitted commands.

### Phase B exit tests (after B1–B7)

- `scripts/test_cons.mcaml` — programs that:
  - Build a list `1 :: 2 :: 3 :: []`, traverse with head/tail, sum, assert.
  - Tail-recursive `fibs_up_to` with accumulator + manual `reverse`. Verify
    output against a Python reference.
  - Nested list operations (list of lists).
  - Pass a list to a helper function, return from a helper.
- Extend the simulator to model `mcaml:conspool`.
- Verify `ICons` emits exactly 5 commands per cell (dump CFG, count).

### Phase C exit tests (after C1–C5)

- `scripts/test_regions.mcaml` — programs that:
  - Wrap a list-building loop in `region`, return an int. Verify the
    conspool is empty after the block.
  - Wrap a list-building loop in `region`, return the list. Verify the
    returned list is in the parent arena (copy-on-escape worked) and the
    child arena is truncated.
  - Nested regions. Inner region returns something that outer region then
    returns.
  - A/B with a long-running loop inside vs. outside a region to verify the
    region-wrapped version doesn't OOM the heap.
- Measure command counts on the copy-on-escape path to confirm the `O(N)`
  cost matches expectation.

## 8. Session kickoff prompts

Paste one of these into a fresh session based on which phase you're in.
**Always** start a new session this way — do not assume the previous
session's context carries over.

### 8.1 Generic kickoff (any phase)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md. This is the cross-session plan for
adding dynamic arrays, cons lists, and regions to MCaml. Check section 2
(Current status) for open tasks. Check section 3 (Load-bearing design
decisions) — these are settled, do not relitigate. Check section 4 (Runtime
contract) and section 5 (Command-level lowering) for the concrete ABI you
must match.

Before starting any task: verify the current state of the codebase matches
what the plan expects. If you find that work from a previous session was
partially completed or the plan's "current status" looks stale, stop and
tell me what you found before proceeding.

Today I want to work on: [FILL IN — e.g., "Phase A tasks A1 and A2", or
"the A6 codegen helpers"].
```

### 8.2 Phase A kickoff (dynamic arrays)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md §§1–7. We are in Phase A: dynamic
arrays. The static array path must remain completely untouched — do not
modify arr_env, per-aid helpers, SROA, LICM, or monomorphize. TArrStatic
stays bit-identical to today's TArr.

Verify the current status section (§2). Pick the next open Phase A task
that has no unmet dependencies. Before writing any code, confirm with me
which task you're starting, and outline the specific file edits you plan to
make.

After each task: rebuild with the command sequence from CLAUDE.md, run the
existing test suite (at minimum test_all.mcaml and primitives_v1.mcaml) to
confirm no regression on the static path, update §2 of the plan, and commit
with a message referencing the task ID.
```

### 8.3 Phase B kickoff (lists and cons)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md §§1–7. We are in Phase B: lists
and cons. Phase A (dynamic arrays) must be complete — verify by checking
that §2's Phase A tasks are all marked [x] AND that scripts/test_dyn_array.
mcaml runs cleanly. If either check fails, stop and tell me.

Cons cells live in mcaml:conspool (compound cells), not in mcaml:scratch.
Do not merge the two pools — cons cells want field-addressed access for
head/tail and dynamic arrays want flat indexing. This is settled in §3.2.

ICons must emit exactly the 5-command sequence from §5.1, with no macro
helper call on the write path (pairs[-1] is a literal). head/tail use the
3-command sequence from §5.2 with the macro helpers. If you find yourself
emitting more commands than that, stop and re-read §5.

Pick the next open Phase B task and outline your plan before editing.
```

### 8.4 Phase C kickoff (regions and copy-on-escape)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md §§1–7. We are in Phase C: regions
and copy-on-escape. Phases A and B must be complete and their test
programs passing.

Regions are purely lexical (§3.5). The compiler snapshots bump counters at
region entry and truncates + restores at region exit. There is no runtime
region tracking — regions are not values, not first-class, not passable.
The programmer writes `region (fun () -> body)` and the compiler brackets
the body with the snapshot/restore.

Copy-on-escape is emitted per return type as a deep-copy walker function.
For primitive returns no walker is emitted. For TList, the walker is
tail-recursive and allocates in the parent region. For TArrDyn, it's a
counted loop. Generate these walkers lazily at codegen time when a region
with a matching return type is first encountered.

The escape rule in typing.ml (§C2) is: a `region` block's return value
type must be representable. You don't need full region polymorphism for
v1 — just accept all return types and rely on the runtime copy to make
things correct.

Pick the next open Phase C task and outline your plan before editing.
```

### 8.6 MineTorch critical path kickoff (Phases M → N → Math)

Use this to start the fixed-point-numerics track that unblocks MineTorch.
It is a three-phase sequence but one kickoff: the phases are small enough
that a single session can usually cover M and start N, and the design
decisions are all in §12.

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md §§1-2 and §12 (post-memory
roadmap). We are on the MineTorch critical path: Phases M (native Mod
operator), N (Q16.16 fixed-point numerics), and Math (transcendental
library in pure MCaml source). The goal of this track is to land a
usable `TFloat` type and a validated `lib/math.mcaml` so that
MineTorch (the sibling ONNX→mcfunction project) can start generating
real inference code.

Load-bearing decisions from §12 that must not be relitigated:

  - §12.1  Uniform int representation ABI. TFloat is a 32-bit
           scoreboard int reinterpreted as Q16.16. No boxing.
  - §12.2  Q16.16 only; IEEE-754 emulation is explicitly rejected
           (precision not worth the tick cost). Multiply picks the
           pre-shift variant OR the split-half variant in N6, not
           both. Document the choice inline.
  - §12.3  Mod is a hard prereq for N, not optional. Phase M lands
           first, end of story. MC's `scoreboard players operation
           %= ` already exists; MCaml just hasn't wired it through.
  - §12.4  Transcendentals (exp, log, sigmoid, tanh, gelu) are
           library code in lib/math.mcaml, NOT compiler built-ins.
           Range reduction + 256-entry LUT, ~15 cmds/call. Bootstrap
           via a separate math_init.mcfunction that init.mcfunction
           calls, to keep init lean.

Execution order:

  1. Phase M. Land all 8 tasks (M1-M8). Rebuild with the CLAUDE.md
     command sequence. Verify all five canaries byte-identical and
     every Python exit suite (test_dyn_array.py, test_cons.py,
     test_regions.py) still green. Smoke-test `x % 10` and
     `x % 65536` as probes. Commit with "Phase M: native Mod".

  2. Phase N. Land N1-N11 in order. The tricky one is N6/N8
     (multiply lowering): decide whether to use pre-shift or
     split-half and whether to introduce `IFixedMul` as a new IR
     op or reuse `IBinOp` with an operand-type tag. Prefer reusing
     IBinOp unless a concrete reason forces otherwise — the
     optimization stack already handles IBinOp uniformly. Add
     `scripts/test_fixed_point.mcaml` covering add/sub/mul/div,
     overflow saturation, int<->float conversion, and run it
     through /tmp/mcaml_out/sim.py. Commit per sub-task.

  3. Phase Math. Write lib/math.mcaml as pure MCaml source using
     array_make for the LUTs or `let t = [| ... |]` static arrays.
     Cross-validate every function against a numpy reference in a
     new /tmp/mcaml_out/test_math.py harness. Document the
     per-function precision tolerance in the test. Add
     tools/pack_datapack.py support for splitting math_init off
     from init. Commit per function.

Before starting any task: verify the current state of the codebase
matches what §2 expects. If you find partially-completed work or
the status looks stale, stop and tell me what you found before
proceeding.

After each sub-task: rebuild, run the canaries + Python exit
suites, update §2 of the plan, commit with the task ID in the
message. Do NOT combine tasks into mega-commits — one commit per
task so the bisect trail is clean if Math reveals a bug in N.

Escalation: stop and flag me if (a) a canary changes output,
(b) a Q16.16 operation's cost exceeds the §12.2 budget (>10 cmds
for add/sub/cmp, >8 for mul, >15 for exp/log), or (c) §12's
decisions turn out to be wrong for a concrete reason. Otherwise
proceed through the phase sequence without interruption.

MineTorch is unblocked the moment Math lands and test_math.py
reports every transcendental within tolerance of numpy. That is
the exit criterion for this track.
```

### 8.5 Resume-from-blocked kickoff

Use this when a previous session stopped mid-task and you need to pick up
where it left off rather than starting a clean task.

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md. The last session was working on
[TASK ID] and stopped because [REASON]. Verify the current codebase state:
git diff to see what's uncommitted, git log to see recent commits, and
check whether the task's file hooks (§6) show partial edits.

Do not assume the previous session's mental model. Re-derive from §§3–5
what the task requires, compare against what's actually in the code, and
tell me what you find before making any new edits.
```

### 8.7 Phase D kickoff (ADTs and pattern matching)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status, §3 and
§12 for settled design decisions, §§4–5 for the runtime ABI, §13 for
escalation triggers. Read CLAUDE.md for the pipeline layout and the manual
rebuild command. Phases A/B/C/M/N/G/Math are all complete and MineTorch is
unblocked; verify §2 agrees and `git status` is clean before starting.

We are starting Phase D: ADTs and pattern matching (tasks D1–D9).

Settled decisions — do not relitigate:
- D4 pool layout is Option (a) from §13.5: ONE unified
  `mcaml:objpool cells` pool with tag-discriminated compound cells
  `{tag: <ctor id>, f0, f1, ...}`, one `$objpool_next` counter, one
  arena-reset path. The conspool→objpool migration (cons becomes
  `{tag, h, t}`) happens in D4 itself, NOT in this session.
- Integer `/` and `%` are FLOOR semantics (vanilla-measured; see
  CLAUDE.md runtime conventions). Any decision-tree arithmetic the
  pattern compiler emits must assume floor.
- Match compilation (D5) reads the scrutinee's tag ONCE into a
  scoreboard slot via the macro getter, then dispatches entirely with
  `execute if score ... matches N` — never one storage read per arm.

This session's scope is the FRONTEND ONLY — D1, D2, D3:
- D1: ast.ml — `TypeDecl of string * constructor list`,
  `Match of expr * (pattern * expr) list`, pattern variants.
- D2: parser.mly/lexer.mll — `type t = A | B of int | C of t * t` and
  `match e with | p -> e | ...`. Watch the seq_expr/expr split; run
  menhir and confirm zero new conflicts.
- D3: typing.ml — nominal type environment for declared ADTs, pattern
  typing, exhaustiveness + redundancy checks with clear errors.
Follow the B4/C1 stub convention: knormal.ml gets a loud failwith
("Match: lowering lands in D5") so any Match/TypeDecl reaching the
middle end fails fast. Add inert structural arms in alpha.ml and
for_lift.ml (both free_vars and walk).

Guardrails for this session:
- Zero edits to knormal lowering, cfg, codegen, or any runtime file.
- All existing outputs stay byte-identical: rebuild per CLAUDE.md, then
  run `cat lib/math.mcaml scripts/mc_test_suite.mcaml | ./mcaml -o
  build_suite && python3 tools/sim_check_suite.py build_suite` (must
  print SUITE PASSED, 66 checks) plus the five canaries from §7.
- Probe programs: a type decl + match that parses and types, an
  inexhaustive match that fails typing with a useful message, a
  redundant arm that warns/fails, and a well-typed match that reaches
  the D5 knormal stub and fails loudly there.

After each task: update §2 of DYNMEM_PLAN.md and commit with the task ID
in the message. If you hit any §13 escalation trigger, stop and tell me.
Before writing code, confirm which task you're starting and outline the
planned file edits.
```

### 8.8 Phase D session 2 kickoff (D4 — objpool migration)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status, §3 and
§13.5 for settled design decisions, §§4–5 for the runtime ABI, §13 for
escalation triggers. Read CLAUDE.md for the pipeline layout and the manual
rebuild command. Phase D frontend (D1–D3) landed in commits
3dccc3f / 91907a8 / e0d5ca6; verify §2 agrees and `git status` is clean
before starting.

This session is D4 ALONE: generalize conspool into the unified objpool.
It is the highest-risk step of Phase D — full focus, do not start D5 even
if it looks easy from here.

Settled decisions — do not relitigate:
- §13.5 Option (a): ONE unified `mcaml:objpool cells` pool with
  tag-discriminated compound cells, ONE `$objpool_next` counter, ONE
  arena-reset path. Cons cells become `{tag: 1, h, t}` — the h/t field
  names are KEPT so cons_head/cons_tail stay field-addressed at 3 cmds;
  generic ADT cells (D5) will use f0/f1/…. Cons's tag value is 1 per
  §13.5's example. Note in the plan that tags are per-type (D3 assigns
  0..n-1 in decl order) and are only interpreted under the scrutinee's
  static type — they are not globally unique, and that's fine.
- Nil sentinel stays -1 (§4.2); is_nil is unchanged.
- ICons grows to EXACTLY 6 commands (§5.1's five + one tag write). This
  is sanctioned by §13.5 and supersedes the §5/§13 escalation budget for
  ICons. IHead/ITail stay EXACTLY 3 — only the storage path changes.
- D4 adds NO new IR ops (ADT alloc / tag read / field read are D5).
  The only observable change is where and how cons cells live.

Migration scope — grep for `conspool`; every hit must move or be
consciously kept, ending at zero live references:
- codegen_helpers.ml: cmd_cons (+tag write), cons_head/cons_tail bodies,
  region truncation helper bodies.
- codegen_cfg.ml reserved slots: $conspool_next → $objpool_next,
  $region_save_<k>_conspool → $region_save_<k>_objpool.
- main.ml: end-of-invocation reset commands (§4.4); the
  any_dyn_heap_use gate keeps counting ICons/IHead/ITail.
- Region machinery (C4/C5): truncate helpers, save slots, and the C5
  stash/rebuild list walkers. The walkers MUST preserve each cell's tag
  when copying — a rebuild that re-appends {h, t} without the tag would
  corrupt every post-region match the moment D5 lands.
  `mcaml:region_tmp conspool` → `mcaml:region_tmp objpool` (§4.5).
- tools/pack_datapack.py: INIT_MCFUNCTION lines (§4.3).
- sim/sim.py: model `mcaml:objpool cells` (compound cells incl. tag).
- DYNMEM_PLAN §§3.2, 4.1, 4.3–4.5, 5.1–5.2, §10 glossary: update the
  ABI tables in the same commits so the plan never lies about the
  runtime. Fix any CLAUDE.md mention of conspool if one exists.

Guardrails:
- Baseline BEFORE the first edit: rebuild per CLAUDE.md, run
  `cat lib/math.mcaml scripts/mc_test_suite.mcaml | ./mcaml -o
  build_suite && python3 tools/sim_check_suite.py build_suite`
  (must print SUITE PASSED, 66 checks) and hash the five canaries
  (test_all, stress_nested_if, test_arr_set, primitives_v1,
  demo_classifier).
- The five canaries stay byte-identical — none touch cons or regions.
- Cons/region outputs will legitimately change; their gate is semantic:
  suite green (66/66) after the sim.py objpool extension, plus the
  Python exit harnesses (test_cons.py, test_regions.py, test_dyn_array.py,
  test_fixed_point.py in /tmp/mcaml_out). Those harnesses are not
  committed — if /tmp was cleared, regenerate them per the plan's
  conventions before migrating, so you have a pre/post signal.
- Verify by CFG dump / command count: ICons exactly 6, IHead/ITail
  exactly 3, region enter/exit budgets unchanged (§5.6).
- No commit may leave the runtime half on conspool and half on objpool —
  the migration is atomic per commit even if you split doc updates out.

After the task: update §2 of DYNMEM_PLAN.md and commit with the task ID.
D4 changes runtime conventions and init, so end by reminding me to rerun
tools/MANUAL_TEST.md's five-minute in-game check before the next datapack
ship. If you hit any §13 escalation trigger other than the sanctioned
ICons 5→6, stop and tell me. Before writing code, confirm the migration
order and outline the planned file edits.

Session 3 is then D5 (pattern compiler — tag read ONCE into a scoreboard
slot via the macro getter, dispatch entirely with `execute if score ...
matches <tag>`, decision-tree arithmetic assumes floor / and %) together
with D9 tests.
```

### 8.9 Phase D session 3 kickoff (D5 + D9 — pattern compiler and tests)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status, §3 and
§13.5 for settled design decisions, §§4–5 for the runtime ABI (§§3.2,
4.1, 4.3–4.5, 5.1 are post-D4: unified objpool, tagged cells), §13 for
escalation triggers. Read CLAUDE.md for the pipeline layout and the
manual rebuild command. D4 landed in commit 1b63cd6; verify §2 agrees
and `git status` is clean before starting.

This session is D5 (pattern compiler) together with D9 (tests).
D6/D7/D8 are OUT of scope even if they look easy from here.

Settled decisions — do not relitigate:
- Cell layout is D4's: `{tag: <ctor id>, f0, f1, ...}` in
  `mcaml:objpool cells`, one `$objpool_next` counter. Tags are
  per-type (D3's ctor_info assigns 0..n-1 in decl order) and are only
  interpreted under the scrutinee's static type. Ctor tags are
  codegen-time constants, so allocation writes the tag inside the
  `append value {...}` literal — NO separate tag-write command (the
  D4 precedent; ICons stayed at 5 cmds this way).
- Match compilation reads the scrutinee's tag ONCE into a scoreboard
  slot via a macro getter (cons_head-style single-line helper reading
  cells[$(idx)].tag), then dispatches entirely with `execute if score
  ... matches <tag>` — never one storage read per arm. Any arithmetic
  the decision tree emits assumes floor / and % (vanilla-measured).
- Typing already did exhaustiveness + redundancy (D3, full Maranget);
  the lowering may therefore assume every match it sees is exhaustive
  and irredundant. A defensive final else-arm falling through to the
  last arm's body (OCaml's warning-then-bind behavior is NOT wanted —
  matches are total by construction) or a loud in-game `say` trap is
  acceptable; pick one and document it.
- Lists stay on their B4–B8 fast path (ICons/IHead/ITail, nil = -1,
  is_nil unchanged). Retiring TList onto the general ADT machinery is
  D6, not this session.
- Region returns of TAdt values fail loudly at codegen, exactly like
  TArrDyn does today. The generic tag-preserving walker is future
  work; do not attempt it here.

New IR surface (this is the session that adds it — D4 added none):
- ADT allocation, tag read, and field read need IR ops (working names
  IAdtAlloc / ITagGet / IFieldGet; knormal kexprs to match). Follow
  the B4/C3 checklist: side-effecting flags in dce (alloc bumps the
  counter and writes NBT; tag/field reads share IArrGet's hidden
  $arr_result write), identity-passthrough arms in copy_prop, inline,
  monomorphize, unroll, regalloc_cfg, const_fold (kill dest), sroa
  (note_use on handle operands), cost, string_of_instr. local_cse
  rides the instr_def fallback.
- Command budgets: IAdtAlloc = 3 + <#fields> cmds (mirrors ICons: 5 =
  3 + 2 fields); ITagGet / IFieldGet = EXACTLY 3 each via the macro-
  getter pattern (§5.2). Field getters are per-index files
  (obj_f0.mcfunction, obj_f1.mcfunction, ...) plus one obj_tag file,
  deduped by filename in main.ml like cons_head/cons_tail. Exceeding
  any of these budgets is a §13 escalation.
- Nullary ctors: decide the representation FIRST and document it in
  §13.5 — the simple option is to allocate a one-field cell {tag: k}
  uniformly (costs 3 cmds per mention, keeps tag-read uniform); the
  optimization (immediate small-int encoding, no cell) breaks
  tag-read uniformity and is NOT worth it unless a concrete blocker
  appears. If you diverge from allocate-uniformly, stop and flag it.

D9 scope: scripts/test_adts.mcaml + /tmp/mcaml_out/test_adts.py (same
uncommitted-harness convention; the four existing harnesses were
regenerated pool-name-agnostic in the D4 session and are available).
Cover: multi-ctor variants with 0/1/2+ fields, nested patterns
(ctor-in-ctor), wildcard and variable binders, int-literal patterns,
match-in-function-body driven cross-function, ADT values passed to and
returned from helpers (handle convention), and a match inside a for
loop. Exhaustiveness/redundancy REJECTION is a typing-time behavior
already pinned by D3's probe battery — include one compile-fail probe
in the session log but the .py harness only runs well-typed programs.

Guardrails:
- Baseline BEFORE the first edit: rebuild per CLAUDE.md, suite green
  (66 checks), hash the five canaries; the four /tmp harnesses must
  be green (regenerate per §2 D4's note if /tmp was cleared again).
- The five canaries stay byte-identical — none declare types or match.
- Suite + all existing harnesses stay green; cons/region command
  sequences must NOT change (D5 adds ops, it must not perturb B/C
  lowerings): ICons 5, IHead/ITail 3, region budgets per §5.6.
- Verify new-op budgets by CFG dump / command count on a probe
  program before writing the D9 harness.
- knormal's D1 ctor/Match stubs must be GONE at session end — no
  loud-stub path may survive into a commit that claims D5 done.

After the task: update §2 (and §13.5's nullary-ctor note) and commit
with the task IDs (D5, D9 — separate commits). If you hit any §13
escalation trigger, stop and tell me. Before writing code, confirm
the lowering strategy (decision-tree shape, nullary representation,
helper-file naming) and outline the planned file edits.

Session 4 is then D6 (retire the TList special case onto the ADT
machinery, or explicitly decide to keep the int-list fast path) —
do not start it in this session.
```

### 8.10 Phase D session 4 kickoff (D6 — list/ADT unification decision)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status, §3 and
§13.5 for settled design decisions, §§4–5 for the runtime ABI, §13 for
escalation triggers. Read CLAUDE.md for the pipeline layout and the
manual rebuild command. D5 landed in 3805e57, D9 in c2a4799, and the
post-D4/D5 in-game MANUAL_TEST check is done (see §2 note); verify §2
agrees and `git status` is clean before starting.

This session is D6 ALONE: decide the fate of the TList special case,
then implement the decision. D7/D8 are OUT of scope even if the
decision makes them look easy.

Make the DECISION FIRST, document it in §13.5 before writing code
(same protocol as D5's nullary-ctor note). The options, with the cost
facts that matter:

  (a) Full retirement — Nil/Cons become ordinary ctors of a declared
      `type list = Nil | Cons of int * list`; `::`/`[]`/`head`/`tail`/
      `is_nil` desugar to ctor applications and matches. ICons→IAdtAlloc
      and IHead/ITail→IFieldGet are budget-neutral (5=3+2 and 3=3), BUT
      nil stops being the free -1 sentinel: every `[]` mention allocates
      a {tag:0} cell (3 cmds + pool growth per mention, including one
      per loop iteration in list-building loops) and `is_nil` goes from
      a 2-cmd compare to a 3-cmd tag read + 2-cmd compare. The C5
      region walkers and their nil-terminated traversal must be
      rewritten (they currently terminate on -1 with no cell read).
      This option regresses committed budgets — treat that as the §13
      escalation it is unless you find a nil-avoidance scheme.

  (b) Keep the fast path, EXTEND the pattern compiler to lists — the
      likely winner; evaluate it first. Runtime stays exactly B4–B8:
      -1 nil sentinel, {tag:1,h,t} cells, ICons 5 / IHead 3 / ITail 3,
      is_nil unchanged, region walkers untouched. What's added is
      surface: `[]` and `h :: t` become valid PATTERNS on a TList
      scrutinee. The decision tree tests nil with the existing
      Eq-against--1 compare on the HANDLE (no tag read — a non-nil
      list handle always points at a tag-1 cell, so the nil test alone
      discriminates the two-ctor signature), and the cons case reads
      sub-occurrences through the existing IHead/ITail (they ARE the
      field getters, already 3 cmds). Work: lexer/parser pattern arms
      for NIL and CONS (watch D2's BELOW_BAR precedence trick — `::`
      in pattern position must not conflict with expr `::`), typing
      arms in check_pattern + a two-ctor complete-signature case in
      the Maranget usefulness matrices for TList, and a TList column
      kind in knormal's compile_match. head/tail/is_nil builtins stay
      for straight-line code; document that match subsumes them.

  (c) Keep everything as-is, no list patterns — pure documentation
      decision. Cheapest, but leaves `match` unable to see lists,
      which undercuts D5's value for the most list-shaped code in the
      language. Pick this only if (b) hits a concrete blocker.

Settled constraints that survive whatever you pick:
- Nil sentinel -1 (§4.2) and the §5.1–5.2 command budgets are
  committed ABI unless §13 escalation says otherwise.
- The C5 stash/rebuild walkers hardcode tag:1 and the h/t field names;
  any cell-layout change must update them in the same commit.
- Tags are per-type; the builtin list type's Cons is tag 1 (D4), and
  if lists gain a nominal decl the Nil/Cons tags must not disturb the
  {tag:1} cells the walkers and cmd_cons emit.
- Exhaustiveness/redundancy for list patterns must go through the same
  D3 Maranget machinery — no side-channel approximation.

Guardrails:
- Baseline BEFORE the first edit: rebuild per CLAUDE.md, suite green
  (66 checks), hash the five canaries; all five /tmp harnesses green
  (test_dyn_array, test_cons, test_regions, test_fixed_point,
  test_adts — regenerate per §2 conventions if /tmp was cleared).
- The five canaries stay byte-identical.
- Cons/region command sequences must not change under option (b);
  under option (a) any change is a flagged escalation, not a silent
  landing.
- New list-pattern lowering verified by CFG dump + command count on a
  probe (nil arm = the 2-cmd compare, cons arm = 3-cmd IHead/ITail
  reads) BEFORE extending the test suite.
- Extend scripts/test_adts.mcaml (or a new scripts/test_list_match
  .mcaml + harness) with list-pattern entries: []/cons dispatch,
  binder patterns h :: t, nested list-in-ctor and ctor-in-list
  patterns, a tail-recursive sum via match (replacing the is_nil/
  head/tail idiom), and an inexhaustive list match rejected at typing.

After the task: update §2 and §13.5, commit with the task ID (D6;
split the decision-doc commit from the implementation commit if the
diff is large). If you hit any §13 escalation trigger, stop and tell
me. Before writing code, confirm the chosen option and outline the
planned file edits.

Session 5 is then D7+D8 (tuples and records as single-ctor ADT sugar,
both parse-time desugarings) — do not start them in this session.
```

### 8.11 Phase D session 5 kickoff (D7 + D8 — tuples and records)

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status, §3
and §13.5 for settled design decisions (especially the D6 note: its
"dedicated variants, not namespace entries" precedent applies here),
§§4–5 for the runtime ABI, §13 for escalation triggers. Read CLAUDE.md
for the pipeline layout and the manual rebuild command. D6 landed in
e0d86d8 (decision) + 6cdb455 (implementation); verify §2 agrees and
`git status` is clean before starting.

This session is D7+D8: tuples and records as single-constructor ADT
sugar. Both should be zero-runtime-change tasks — at runtime a tuple
or record is just a single-ctor ADT cell ({tag:0, f0, f1, ...}),
allocated by the existing IAdtAlloc (3+n cmds) and read by the
existing IFieldGet (3 cmds), and D5's single-ctor complete-signature
rule already dispatches matches on them with ZERO tag reads. Expect
zero new IR ops and zero codegen/optimizer/sim edits. Phase E
(polymorphism), G3 (modules), and first-class field names are OUT of
scope.

Make the representation DECISIONS first and document them in §13.5
before writing code (D5/D6 protocol). The §2 task lines say "desugar
at parse time to ctor applications", but they predate D6, whose
lesson was that dedicated variants beat namespace tricks. Weigh:

  D7 tuples — (a) parse-time desugar `(a, b)` → a synthesized nominal
      ctor. Problem: nominal decls are monomorphic and keyed by ctor
      name, but tuple SHAPES vary per use site ((int, int) vs
      (list, int)); the parser can't know field types, and per-arity
      int-only decls would mistype every non-int field. (b — evaluate
      first) structural: `TTuple of typ list` in typ, dedicated
      `Tuple of expr list` expr + `PTuple of pattern list` pattern —
      the D6 precedent, keeping tuples out of the user ctor namespace
      entirely. Typing checks fields exactly; the Maranget column
      case for TTuple is an always-complete single-ctor signature
      (specialize = unfold the fields; exhaustive iff sub-patterns
      are). knormal lowers Tuple → KAdtAlloc with tag 0 and PTuple
      columns → KFieldGet reads under the D5 used-fields filter — no
      tag test ever. Field representability mirrors D3's ctor-field
      rules. Type surface: `(int, int)` vs `int * int` — note `of
      int * t` ALREADY uses TIMES to separate ctor fields in decls,
      so a bare `typ TIMES typ` arm collides there (OCaml's answer:
      `of int * t` stays two fields, a tuple field needs parens);
      pick a surface that keeps menhir at zero conflicts.

  D8 records — records have a natural nominal home: the user declares
      `type point = { x : int; y : int }`, so this is a decl-level
      desugar to a single-ctor ADT (ctor synthesized from the type
      name) + a field-name → decl-order-index table alongside
      ctor_info. Decide where literals `{ x = 1; y = 2 }` desugar:
      parse time works only if the parser owns field tables (it
      shouldn't); a typing-time rewrite to ctor form is the likely
      winner. Accept permuted field order in literals and patterns by
      sorting to decl order at rewrite time. Decide the field-access
      surface: `r.x` needs a DOT token the lexer doesn't have (check
      the float `0.5` and selector regex interactions) vs
      destructuring-only via match — pick one and document it. Decide
      whether record patterns may omit fields (missing = PWild).
      Note LBRACE/RBRACE are declared in parser.mly but the lexer has
      NO `{`/`}` rules — they're two of the three pre-existing
      warnings; D8 adds the rules and the warning count legitimately
      drops.

  Shared — decide whether destructuring-let (`let (a, b) = e in ...`)
      lands now as sugar for a one-arm match or is deferred; either
      is fine, document the choice.

Settled constraints that survive whatever you pick:
- The D4/D5 objpool ABI is untouched: compound {tag, f0...} cells,
  static per-type tags, IAdtAlloc/ITagGet/IFieldGet at 3+n/3/3
  (§13.5). Tuples and records must compile to exactly this machinery.
- One global ctor namespace (D3). Any synthesized ctor name must be
  collision-proof against user code — avoid the namespace entirely
  (structural) or reserve the form and reject user spellings of it.
- Exhaustiveness/redundancy through the D3 Maranget machinery — no
  side-channel approximation. Witnesses must render as tuple/record
  syntax, never internal ctor names.
- §4.4 public-entry contract: test entry points return ints.

Guardrails:
- Baseline BEFORE the first edit: rebuild per CLAUDE.md, suite green
  (66 checks), hash the five canaries; all SIX /tmp harnesses green
  (test_dyn_array, test_cons, test_regions, test_fixed_point,
  test_adts, test_list_match — regenerate per §2 conventions if /tmp
  was cleared).
- The five canaries stay byte-identical; zero new menhir conflicts.
- New lowering verified by CFG dump + command count on probes BEFORE
  extending the test suite: tuple build = 3+n cmds, field read =
  3 cmds, tuple/record match = zero obj_tag dispatches (grep the
  emitted file), unused pattern fields emit NO obj_f<k> read.
- Tests: scripts/test_tuples_records.mcaml (or one file each) + /tmp
  harness per D9 conventions: tuple build/match round-trip, tuple-in-
  ctor and ctor-in-tuple nesting, tuple as fun param/return (handle
  convention), record decl/literal/pattern with permuted fields,
  field access via whichever surface you picked, wrong-arity /
  unknown-field / duplicate-field typing errors, and single-ctor
  exhaustiveness (a one-arm tuple match typechecks; a trailing
  `| _ -> ...` after it is rejected as redundant).

After the task: update §2 and §13.5, commit with the task IDs (D7,
D8; split decision-doc commits from implementation commits if the
diffs are large). If you hit any §13 escalation trigger, stop and
tell me. Before writing code, confirm the chosen representations and
outline the planned file edits.

Phase D then has no open tasks; next per §13.7 is Phase E (HM
inference + let-polymorphism) — do not start it in this session.
```

### 8.12 Phase E kickoff (E1–E8 — HM inference + let-polymorphism)

Re-pasteable across sessions: check §2 for which E tasks are open and
pick up from there.

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status (all
of Phase D is closed and in-game verified, commit a7f6784), §3 and
§13 for settled decisions (§13.1 uniform representation is the
load-bearing one for this phase), §13.5 for the D6/D7/D8 precedents,
§13 (bottom) for escalation triggers. Read CLAUDE.md for the pipeline
and the manual rebuild command. Verify `git status` is clean before
starting.

This phase is E1–E8: rewrite typing.ml's equality checker as
Hindley-Milner unification with let-polymorphism. §13.1 makes this
cheap at runtime: every value is one scoreboard int, so a polymorphic
function compiles ONCE — no clones per instantiation, zero new
codegen paths. The ONLY types that ever specialize are
TArrStatic/TMat (length-in-type), which keep the existing
monomorphize template path unchanged (E7 is a verification task, not
new code). Phase F (lambdas) is OUT of scope — E8's polymorphic test
functions are first-order only (id, swap over ('a * 'b), list
length/sum — no map/fold, those need F).

This is the largest single rewrite since M2 (typing.ml is ~900 lines
and every phase A–D behavior routes through infer). Expect 2–3
sessions. Suggested order: decisions + E1/E2 first (engine lands with
annotations still REQUIRED and every existing behavior preserved —
this alone must leave the whole test battery green), then E3/E4
(generalization + optional annotations), then E5/E6/E8. Update §2 and
commit at each boundary; stop at a green state, never mid-rewrite.

Make the DECISIONS first and document them in a new §13.10 before
writing code (D5/D6 protocol):

  1. Unification representation — (evaluate first) MinCaml-style
     destructive: `TVar of typ option ref` (None = unbound, Some t =
     link), occurs check, path compression on resolve. The
     alternative (persistent substitution maps) doubles the plumbing
     for no benefit at this scale. Decide how generalization finds
     free tvars: level-based (Rémy) vs scan-the-env; scan is O(n²)
     but the env is tiny — pick and document.
  2. Where schemes live — the E1 task line says `TScheme of tvar
     list * typ` inside typ; consider instead keeping typ scheme-free
     and making the ENV map name → scheme (standard, and it keeps
     every existing `typ` consumer — Maranget matrices, check_pattern,
     knormal, cfg_build — ignorant of schemes). If you deviate from
     the E1 wording, document why.
  3. Value restriction — MCaml has `ref e`. Generalize only
     syntactic values (literals, ctors of values, tuples/records of
     values, Nil, functions once F lands) or only non-expansive
     RHSes; `let r = ref ... in` must NOT generalize. Document the
     rule and its test.
  4. Scope of polymorphic TYPES — inference gives polymorphic
     FUNCTIONS over existing types. Decide explicitly whether this
     phase also lifts B2's monomorphic-list restriction ('a list:
     ctor-in-list patterns, Cons accepting any head) and whether
     parameterized USER decls (`type 'a option = None | Some of 'a`)
     land now or as a follow-up task (they need decl syntax, a tick
     token `'a` in the lexer — check interactions with nothing: `'`
     is currently an illegal char — and arity-checked TAdt
     application). The record nil-story (§13.5 D8 note) wants 'a
     option eventually; it does NOT have to be this phase. Whatever
     you pick, update the E-task list in §2 to match.
  5. Residual-tvar defaulting (E6) — a function like
     `fun f(x) = 0` never constrains x. Decide: default unresolved
     tvars to TInt at the knormal boundary (uniform representation
     makes this sound) vs reject with "cannot infer". Recommend
     default-to-TInt with the decision documented; it matches the
     existing App-fallback culture.
  6. Annotation semantics (E4) — annotations become optional but
     stay CHECKED: an annotation is a unification constraint, not
     dead syntax. Parser: `param := ID | ID COLON typ`, return typ
     optional — verify zero new menhir conflicts.
  7. Recursion — self-recursive calls unify against the function's
     own MONOTYPE (no polymorphic recursion, standard HM);
     generalization happens after the def is inferred. Function decl
     order stays source order (same rule as type decls). Mutual
     recursion stays out (G1).

Behaviors that MUST survive the rewrite (these are load-bearing, all
pinned by existing tests/probes):
- D3 Maranget exhaustiveness/redundancy needs CONCRETE types at
  match-analysis time — resolve/force scrutinee types before the
  matrices run; witnesses must not print '_weak1'-style tvars.
- The Capitalized-ctor convention, one global ctor namespace, one
  global record-field namespace, record literals requiring the exact
  field set.
- fmul/fdiv asymmetry: `*`/`/` on TFloat stay REJECTED with the
  pointer to fmul/fdiv (N5 decision) — unification must not silently
  accept them.
- for_lift synthesized helpers (E5): walk's env currently calls
  Typing.infer as a concrete-type oracle and main.ml SKIPS typing for
  __for helpers (they reference enclosing locals). Decide how the
  walk tolerates unbound tvars (thread the real env, or default) and
  document.
- fun_sigs consumers: build_sigs feeds App checking; the App
  unknown-signature fallback (returns TInt) must keep working for
  synthesized helpers.
- §4.4 public-entry contract and every runtime convention — typing is
  the only layer changing; knormal and below must see fully-resolved
  concrete typs exactly as today.

Guardrails (the full battery, now EIGHT checks):
- Baseline BEFORE the first edit: rebuild per CLAUDE.md; suite 66/66
  + async (tools/sim_check_suite.py); Phase D suite 40/40
  (./mcaml -o build_phase_d < scripts/mc_test_suite_phase_d.mcaml;
  python3 tools/sim_check_phase_d.py build_phase_d); hash the five
  canaries; all SEVEN /tmp harnesses green (test_dyn_array,
  test_cons, test_regions, test_fixed_point, test_adts,
  test_list_match, test_tuples_records — regenerate per §2
  conventions if /tmp was cleared).
- The five canaries stay byte-identical through the ENTIRE phase —
  typing is upstream of codegen, so any hash drift means inference
  changed a resolved type somewhere. That is an instant stop-and-
  investigate.
- Zero new menhir conflicts. Every pre-existing typing error message
  that a test greps for keeps firing (rewrite the message text only
  if you update the probe in the same commit).
- E8 tests: scripts/test_polymorphism.mcaml + /tmp harness per D9
  conventions — polymorphic id used at int/bool/list/tuple types in
  one program, first-order polymorphic list helpers, a
  tuple-polymorphic swap, value-restriction rejection probe, an
  un-annotated fun inferring its param types from use, an annotation-
  mismatch error probe, and HM diagnostic quality checks (unify-fail
  error names both types, occurs-check error is actionable).

If the rewrite reveals that preserving some existing behavior is
impossible under HM (e.g. an App-fallback ambiguity), STOP and flag
it per §13 — do not paper over it with special cases.

After each session: update §2 (mark E-task progress with commit
hashes), keep decision-doc commits separate from implementation
commits, and leave the tree green. When E is fully closed, author
§8.13 for Phase F.
```

### 8.13 Phase F kickoff (F1–F7 — first-class lambdas)

Re-pasteable across sessions: check §2 for which F tasks are open and
pick up from there.

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status (all
of Phase E is closed: HM inference + let-polymorphism landed, commits
25cc860..ab19836; G4 — parameterized user type decls, pulled ahead of
this phase — is also closed, decisions 201b09b, implementation
264801b), §13.6 for the settled two-strategy design (specialize
aggressively, fall back gracefully — do NOT revisit), §13.5 for the
closure cell layout ({tag: $CLOSURE, code, env_0, ...} in the existing
objpool), §13.10 for the Phase E decisions Phase F builds on (esp. the
tvar single-int restriction — a closure handle IS a single int, so
'a -> 'b tvars stay sound), §13.11 for G4's decisions — `Ast.typ` now
also carries `TAdt of string * typ list` (applied user types) and
`TParam of string` (decl-side type variable, substituted away before
typing.ml's `unify` — never reaches it unsubstituted). `TFun` is a
SIBLING constructor to both, not a replacement for either: every
function G4 touched to add a `TAdt`/`TParam` arm (`check_typ_ok`,
`subst_typarams`, `string_of_typ`, `occurs`, `free_tvars`,
`copy_with`, `zonk_default`, `unify`, `tvar_bindable`, plus
`check_field_type`/`check_record_field_type`/`check_tuple_elem`) also
needs a `TFun` arm — grep those names in typing.ml before writing
decision 1's arrow-type code so the same pass covers all three new
constructors in one sweep rather than three. §13 (bottom) for
escalation triggers. Read CLAUDE.md for the pipeline and the manual
rebuild command. Verify `git status` is clean before starting.

This phase is F1–F7: `fun x -> e` lambdas, closure conversion, escape
analysis, whole-program defunctionalization for Known lambdas, and the
apply-dispatch runtime for Escaping ones. Two lowering strategies, ONE
language surface (§13.6): Known lambdas (never stored/returned/passed
to an escaping HOF param) get MLton-style specialization — the HOF is
cloned per unique closure that flows in, at zero runtime cost;
Escaping lambdas get a closure objpool cell + `mcaml:apply` macro
dispatch (~4 cmds fixed + 2/captured var + ~2x macro wall-clock).
Expect 3–4 sessions. Suggested order: decisions + F1/F2 first (parse +
one uniform closure-conversion IR form, everything still rejected at
codegen so the battery stays trivially green), then F3/F4
(escape analysis + specialization — this alone makes literal-lambda
HOFs work end-to-end), then F5 (apply-dispatch runtime), then F6/F7.

Make the DECISIONS first and document them in a new §13.12 before
writing code (D5/D6 protocol) — §13.11 is now taken by G4's decisions:

  1. Arrow types — HM needs `TFun of typ list * typ` (or curried
     equivalent) in Ast.typ. Decide: n-ary uncurried (matches the
     existing call convention, no partial application) vs curried with
     auto-currying (the F1 task line mentions partial application —
     decide whether it survives scoping; n-ary + no-partial-app is the
     cheap v1). Whatever lands must extend tvar_bindable: a closure
     handle is ONE int, so TFun becomes tvar-bindable — that is what
     makes polymorphic HOFs (map : ('a -> 'b) -> 'a list -> 'b list)
     typeable in Phase F, and it must NOT break the §13.10 amendment
     for the non-uniform types.
  2. Where lambdas may appear in v1 — argument position only vs
     let-bound vs stored-in-ADT. §13.6 already prices escaping
     closures; decide the v1 SURFACE scope and the exact "escaping"
     definition F3 classifies against.
  3. fun_sigs/fun_schemes interaction — HOF params are TFun-typed;
     decide how build_sigs represents a HOF's signature and whether
     specialization clones re-enter the fn_table before or after
     monomorphize (the F3 task line says between inline and
     monomorphize — confirm or amend with rationale).
  4. Closure tag value — §13.5 says {tag: $CLOSURE, ...}; pick the
     concrete reserved tag (ADT tags are per-type so a dedicated
     sentinel is safe; document why it can't collide).
  5. tick_guard/tick_split interaction — apply-dispatch inside a
     TCO'd loop: decide how cost.ml prices ICall-via-apply and whether
     MCAML_STRICT_HOT (F6) fires at typing or at codegen.

Behaviors that MUST survive (all pinned by the existing battery):
- Everything Phase E pinned: §13.10 decisions, the tvar single-int
  restriction, zero clones for value-polymorphic functions (lambda
  SPECIALIZATION clones are new and expected — the E8 zero-clones grep
  pins id/swap/len specifically, keep it passing).
- The §4.4 public-entry contract, every §4.1 reserved slot, ICons/
  IHead/ITail budgets, the D5 decision-tree shapes, region walker
  domain (TList TInt only).
- for_lift's oracle degraded mode and the two-pass main.ml driver
  (type+generalize, then zonk+compile) — closure conversion must slot
  between them or after, not inside typing.

Guardrails (the full battery, now TEN checks):
- Baseline BEFORE the first edit: rebuild per CLAUDE.md; suite 66/66 +
  async; Phase D suite 40/40; Phase E suite 42/42
  (tools/sim_check_phase_e.py — includes its 12 rejection probes);
  hash the five canaries; all NINE /tmp harnesses green
  (test_dyn_array, test_cons, test_regions, test_fixed_point,
  test_adts, test_list_match, test_tuples_records, test_polymorphism,
  test_param_types — regenerate per §2 conventions if /tmp was
  cleared; test_param_types.py isn't checked in, only its source
  scripts/test_param_types.mcaml is — see G4's commit for the harness
  body to recreate).
- Five canaries byte-identical until a phase task deliberately
  changes codegen for lambda-free programs (none should — lambdas are
  purely additive; any drift is a stop-and-investigate).
- Zero new menhir conflicts; every pre-existing typing error message
  keeps firing (probe-update-in-same-commit rule applies).
- F7 tests per D9 conventions: literal lambdas in HOFs specialize
  (grep the clone files), closures captured in ADTs take the apply
  path, MCAML_SPECIALIZE_LIMIT fallback fires, MCAML_STRICT_HOT
  promotes the right patterns, and the [closure] diagnostic lines
  match the §13.6 contract.

If escape analysis or specialization forces a §3 decision to bend
(e.g. §3.6 "new IR ops are opaque"), STOP and flag per §13 — do not
special-case through it.

After each session: update §2 with commit hashes, keep decision-doc
commits separate from implementation commits, and leave the tree
green. When F is fully closed, author §8.14 for Phase G.
```

### 8.14 G4 kickoff (parameterized user type decls — pulled ahead of Phase F)

Re-pasteable across sessions: check §2 G4 for status.

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status (all
of Phases A–E plus M/N/Math are closed; G4 is being pulled AHEAD of
Phase F because it has no dependency on lambdas), §13.10 for the
Phase E decisions this builds on (esp. decision 2 schemes-in-env, the
tvar single-int amendment, and decision 4 which deferred this task),
§13.5 for the D6/D7/D8 "dedicated variants, not namespace entries"
precedents, §13 (bottom) for escalation triggers. Read CLAUDE.md for
the pipeline and the manual rebuild command. Verify `git status` is
clean before starting.

This task is G4: parameterized user type declarations —
`type 'a option = None | Some of 'a`, `type 'a box = Box of 'a` —
with arity-checked type application (`int option`) in annotation and
ctor-field positions. This is the record nil-story's prerequisite
(§13.5 D8 note: `type node = { v : int; next : node option }`).
Runtime cost is ZERO by construction: §13.1 uniform representation
means an instantiated 'a is always one scoreboard int, cells stay
{tag, f0...}, tags stay per-type decl-order — typing is the only
layer that changes, exactly like Phase E. Expect 1–2 sessions.

Make the DECISIONS first and document them in a new §13.11 before
writing code (D5/D6 protocol) — and in the same commit, amend §8.13's
"document them in a new §13.11" line to point Phase F at §13.12
(numbering by landing order):

  1. AST representation of applied types — `TAdt of string` must
     grow arguments. Evaluate: (a) widen to `TAdt of string * typ
     list` ([] = existing nullary uses; every current TAdt mention
     updates mechanically, OCaml's exhaustiveness finds them all) vs
     (b) a separate `TAppAdt of string * typ list` beside bare TAdt
     (no churn, but every future consumer must remember two arms).
     Recommend (a) — one representation, and the compiler enumerates
     every site to fix. Whatever lands: unify gets
     TAdt(a,xs)/TAdt(b,ys) → a=b && pairwise; occurs/free_tvars/
     copy_with/zonk_default/string_of_typ (render as `int option`)
     get args arms; knormal/codegen never inspect the args (tags are
     already per-type).
  2. Decl-side type variables — `'a` in `Some of 'a` is a BINDER,
     not a unification var. Recommend a dedicated `TParam of string`
     in typ, legal ONLY inside registered ctor field types;
     instantiation at every ctor use/pattern substitutes TParam ->
     the use's type arguments (fresh tvars when inferring). Do NOT
     reuse TVar refs for decl params — a destructive bind would
     corrupt the decl for every later use. tvar_bindable and the
     representability checkers get TParam arms (representable: the
     tvar single-int amendment guarantees every instantiation is one
     int); unify treats a surviving TParam as an internal error.
  3. Lexer for `'a` — `'` is currently an illegal character. Add a
     TYVAR token (`''' ['a'-'z' 'a'-'z' '0'-'9' '_']*` — check the
     exact ident charset against ID's). AUDIT collisions before
     committing: string/`cmd!` payload lexing, selector tokens, and
     the FLOAT/DOT rules must be unaffected (grep lexer.mll for every
     rule that could consume a quote). Zero new menhir conflicts is
     the gate, as always.
  4. Type application surface syntax — OCaml postfix: `int option`,
     nested `int option option`, parenthesized `(int * int) option`.
     Grammar: left-recursive `typ_atom: t = typ_atom; name = ID
     { ... }` beside the existing bare-ID arm; bare use of a
     parameterized type name and applying a NON-parameterized one are
     ARITY ERRORS at typing (decl arity recorded at registration).
     Decide v1 param count: single 'a only (recommend — covers
     option/box/list-shaped decls; multi-param `('a, 'b) either`
     is a mechanical follow-up) — document either way.
  5. Does `list` join the postfix grammar? The E4b probe found
     `shape list` annotations unparseable (the `list` keyword is
     hardwired to TList TInt). Recommend YES as part of G4:
     `typ_atom T_LIST → TList t` postfix arm beside the keyword arm
     (bare `list` stays TList TInt for back-compat). This closes the
     E4b annotation gap for free. Records: parameterized RECORD
     decls (`type 'a cell = { v : 'a }`) — recommend DEFER; document
     that record decls stay monomorphic (the nil-story only needs
     `node option` as a FIELD type, which works once ADT application
     lands).
  6. Typing mechanics — adt_decls value grows the param list;
     ctor_info fields may contain TParam. Ctor APPLICATION
     (`Some(e)`): instantiate the owner's params with fresh tvars
     (or the annotation's args), unify field types, return
     TAdt(owner, args). Ctor PATTERN: substitute the scrutinee's
     args into field types before recursing (the PCtor TVar-pinning
     arm pins to TAdt(owner, fresh...)). Maranget: the
     complete-signature test keys on the owner name (args don't
     change the ctor set); specialize substitutes args into field
     types so witnesses stay concrete. Self-reference through an
     application (`type tree2 = Leaf | N of tree2 option`) must
     resolve via the register-name-first rule (D3).

Behaviors that MUST survive (all pinned by the existing battery):
- Every §13.10 Phase E decision and the tvar single-int amendment;
  zero clones for polymorphic functions (a `'a option` value is one
  handle — NO monomorphization of user types, ever).
- Monomorphic ADT decls type and compile byte-identically (canaries +
  both self-checking suites); tags stay decl-order per-type; the D5
  decision-tree shapes and obj_tag/obj_f<k> budgets are untouched.
- One global ctor namespace, Capitalized-ctor convention, record
  field namespace, D3's decl-before-use ordering.
- Every pre-existing typing error message (probe-update-in-same-
  commit rule applies; arity errors are NEW messages — name the type,
  the declared arity, and the applied arity).

Guardrails (the full battery, now TEN checks):
- Baseline BEFORE the first edit: rebuild per CLAUDE.md; suite 66/66
  + async; Phase D suite 40/40; Phase E suite 42/42
  (tools/sim_check_phase_e.py — includes its 12 rejection probes);
  hash the five canaries; all EIGHT /tmp harnesses green (regenerate
  per §2 conventions if /tmp was cleared).
- Five canaries byte-identical through the whole task (typing-only
  change — any drift is stop-and-investigate).
- Zero new menhir conflicts; lexer audit per decision 3.
- Exit tests: scripts/test_param_types.mcaml + /tmp harness per D9
  conventions — 'a option round-trip (Some/None dispatch through a
  polymorphic get_or), option at int/bool/tuple/ADT payloads in one
  program, nested `int option option`, `node option` record field
  (the nil-story shape: a nil-free linked record), option-of-list +
  list-of-option, exhaustiveness witness rendering applied types
  (`Some(_)`), plus rejection probes: bare `option` (arity 0 vs 1),
  `int int option`-style over-application, applying a
  non-parameterized type, unbound `'b` in a decl
  (`type t = K of 'b`), and ctor arg type mismatch naming the
  instantiated (not TParam) types. Consider folding a couple of
  runtime checks into a mc_test_suite_phase_e-style addition or a
  small standalone self-checking suite — decide and document.

If the TAdt widening reveals a pass that DOES inspect ADT args
downstream of typing (there should be none — knormal/codegen key on
tags and ctor_info only), STOP and flag per §13 rather than threading
args through it.

After the session: update §2 G4 with commit hashes (decision-doc
commit separate from implementation), leave the tree green, and note
whether multi-param decls and parameterized records were deferred
(they become G4b/G4c bullets if so).
```

### 8.15 Phase F session 2 kickoff (F1 + F2 — lambda parser/AST + closure-conversion IR)

Re-pasteable across sessions: check §2 for which F tasks are open.

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status (all
of Phases A–E, M/N/Math, and G4 are closed; Phase F decisions landed
in §13.12, commit `dc4f32c` — decisions ONLY, zero code changed yet).
Read §13.12 in full before writing any code — it settles all five
headline decisions (TFun of typ list * typ, n-ary, NO partial
application; v1 lambda scope = first-class everywhere except stored
in a Tuple/Record/ADT-ctor field; fun_sigs/fun_schemes need no new
table, F4 folds into Monomorphize's existing clone key rather than a
new phase; closure tag -2; IApply costing + MCAML_STRICT_HOT living in
optimize.ml) with file:line citations into the current typing.ml/
ast.ml/main.ml/cost.ml. Do NOT relitigate these. Also read §13.6
(specialize-aggressively/fall-back-gracefully, unchanged), §13.5
(closure cell layout {tag: -2, code, env_0, ...} in the existing
objpool), §13.10 (Phase E decisions this builds on, esp. the tvar
single-int amendment — a closure handle IS one int, so `'a -> 'b`
stays sound), §13.11 (G4's TAdt/TParam widening — TFun is a THIRD
sibling constructor, not a replacement for either), and §13 (bottom)
for escalation triggers. Read CLAUDE.md for the pipeline and the
manual rebuild command. Verify `git status` is clean before starting.

This session is F1 + F2 ONLY — do not start F3 even if it looks easy
from here. Everything lambda-shaped stays REJECTED at knormal/codegen
by the end of this session (a loud stub, same posture Phase D's D1
used for Match before D5 landed) so the full battery — main suite,
Phase D suite, Phase E suite, all nine /tmp harnesses, five canaries —
stays green throughout with ZERO behavioral change for lambda-free
programs.

F1 scope: `fun (params) -> e` lambda EXPRESSIONS (not top-level defs —
`Fun` already exists), a new `Lambda` expr node, and `TFun` threaded
through the type system. F2 scope: one uniform closure-conversion IR
representation that treats every lambda identically (no Known/
Escaping distinction yet — that's F3's job) — this is the shape F3's
escape analysis will consume and F4/F5 will lower differently per
classification.

Three sub-decisions §13.12 left open (F1-implementation-time scope
cuts, same D5/D6 protocol — settle these FIRST, document alongside
the F1 commit, before writing the grammar):

  1. Lambda parameter representation. The original F1 task line says
     `Lambda of pattern list * expr` (destructuring params like
     `fun (a, b) -> ...`), but every existing pattern-bearing construct
     in this codebase (Match, destructuring-let) already needs
     irrefutability/exhaustiveness machinery that a lambda param would
     also need (a refutable lambda param has no failure branch to fall
     into — there's no runtime pattern-match failure in this
     language). Recommend the same scope cut §13.12 decision 1 made
     for partial application: v1 lambda params are bare `(string *
     typ) list` var binders ONLY, mirroring `Fun`'s own param grammar
     and reusing its optional-annotation convention (E4's `ID |
     ID COLON typ`) verbatim. Defer pattern-destructuring lambda
     params to a mechanical follow-up. Decide and document either way
     — if you instead implement full pattern params, you must also
     decide irrefutability checking (probably: reuse destructuring-
     let's existing "Maranget exhaustiveness check rejects refutable
     patterns" path, D7 precedent).
  2. Grammar shape. `parser.mly:116-121` shows `Fun`'s existing
     `FUN name = ID LPAREN params = param_list RPAREN (COLON ret_type
     = typ)? EQUAL body` production. Recommend mirroring it exactly
     for the expr-level lambda: `FUN LPAREN params = param_list RPAREN
     ARROW body = expr` (reusing `param_list` verbatim, no new
     nonterminal). Check this against the EXISTING special-cased
     region syntax at `parser.mly:273`: `REGION LPAREN FUN LPAREN
     RPAREN ARROW body = seq_expr RPAREN { Region (ref TUnit, body) }`
     — this already hand-unwraps a zero-param `fun () -> body` into
     bare `body` for `Region`'s AST shape. Decide: does the new general
     `Lambda` production subsume this (region's rule becomes `REGION
     LPAREN e = expr RPAREN` and `main.ml`/`knormal.ml` unwrap a
     `Lambda ([], body)` shape specially for Region), or does the
     region rule stay a fully separate literal token sequence
     untouched? Either way, run menhir and confirm ZERO new conflicts
     — do not assume, per the G4 precedent (§13.11 decision 4's own
     wording).
  3. F2's free-variable/capture analysis vs. `for_lift.ml`.
     `for_lift.ml` already computes free variables and lifts a nested
     scope (a `for`-loop body) into a synthetic top-level helper by
     threading captured variables as extra params — structurally very
     close to what closure conversion needs to do for a lambda body.
     Decide: does F2 reuse/extend `for_lift.ml`'s existing free-
     variable walk (a lambda is lifted to a synthetic top-level
     function taking its captures as extra leading params, exactly
     like a for-loop helper, with the closure-conversion IR wrapping
     that synthetic function name + captured values into a cell), or
     is it a wholly separate new pass/module (e.g. `closure_convert.ml`)
     that duplicates the free-variable computation? Recommend
     investigating reuse first — if `for_lift.ml`'s walk cleanly
     generalizes, it avoids a second free-variable analysis existing
     in the codebase with its own edge cases. Document the choice and
     why before implementing F2's IR.

Facts already gathered this phase (avoid re-deriving — cite directly):
current `typ`/`expr`/`def` full definitions, the exhaustive bodies of
`occurs`/`tvar_bindable`/`unify`/`zonk_default`/`copy_with`/
`free_tvars`/`string_of_typ`/`check_field_type`/`check_record_field_
type`/`check_tuple_elem`, `fun_sigs`/`fun_schemes` population + the
App lookup order, `main.ml`'s full phase order and the `fn_table`
handoff between `Inline.run`/`Monomorphize.run`, `cost.ml`'s `ICall`
pricing, `tick_guard.ml`/`tick_split.ml` summaries, the ADT tag
numbering scheme, and the reserved-slot list — all captured with
file:line citations in §13.12 and its drafting research; re-read
§13.12 rather than re-running a fresh sweep.

Behaviors that MUST survive (restated from §13.12's closing list):
every §13.10/§13.11 decision incl. the tvar single-int amendment; zero
clones for value-polymorphic non-lambda functions; the §4.4
public-entry contract and every §4.1 reserved slot; ICons/IHead/ITail
budgets; the D5 decision-tree shapes; the region-walker domain staying
`TList TInt` only (verified: `TFun` automatically falls into
`codegen_cfg.ml`'s existing untyped catch-all at line ~300/310 — a
lambda escaping via region-return already fails loudly with zero new
code, confirmed by direct read this phase); `for_lift`'s oracle
degraded mode and the two-pass `main.ml` driver.

Guardrails (the full battery, now carrying forward all nine /tmp
harnesses):
- Baseline BEFORE the first edit — already verified clean as of commit
  `dc4f32c`; re-verify in the fresh session: rebuild per CLAUDE.md;
  `cat lib/math.mcaml scripts/mc_test_suite.mcaml | ./mcaml -o
  build_suite && python3 tools/sim_check_suite.py build_suite` (66/66
  + async); `python3 tools/sim_check_phase_d.py` (40/40); `python3
  tools/sim_check_phase_e.py` (42/42 + 12 probes); hash the five
  canaries (`diff -rq` against a fresh compile is sufficient, no need
  to reinvent a hashing scheme); all nine /tmp harnesses
  (test_dyn_array, test_cons, test_regions, test_fixed_point,
  test_adts, test_list_match, test_tuples_records, test_polymorphism,
  test_param_types — each is self-compiling/self-running via `python3
  /tmp/mcaml_out/<name>.py`, regenerate from its `scripts/*.mcaml`
  source if /tmp was cleared).
- Five canaries stay byte-identical through F1/F2 — lambda-free
  programs must not change AT ALL (lambdas are purely additive; any
  drift is stop-and-investigate, not a thing to special-case around).
- Zero new menhir conflicts (verified by actually running menhir).
- `Lambda`/`TFun` must be threaded (or deliberately, loudly rejected)
  through every pass CLAUDE.md's module layout lists — alpha.ml,
  for_lift.ml, typing.ml (12 functions per §13.12 decision 1),
  knormal.ml (loud stub: "Lambda: lowering lands in F2/F3" — same
  pattern D1 used for Match), cfg_build.ml (no change needed if
  knormal fully stubs it). If F2 lands a real closure-conversion IR
  form, knormal's stub moves to wherever closure conversion doesn't
  yet handle escape classification (i.e., codegen_cfg.ml gets the
  loud "not supported until F5" stub instead).
- The Maranget/pattern-compiler battery (D3/D5/D6 exhaustiveness) must
  stay untouched — lambda params are NOT patterns in v1 per
  sub-decision 1 above (unless you deliberately chose otherwise and
  documented why).

If closure conversion or the `for_lift.ml` reuse question forces a §3
decision to bend (e.g. §3.6 "new IR ops are opaque to all existing
passes"), STOP and flag per §13 — do not special-case through it.

After the session: update §2 with commit hashes (sub-decision
documentation commit separate from implementation commits, same
discipline as every prior phase), leave the tree green, and note in
§2 which of the three open sub-decisions above were settled and how.
Session 3 is then F3 + F4 (escape analysis between Inline and
Monomorphize; specialization folded into Monomorphize's existing clone
key, per §13.12 decision 3).
```

### 8.16 Phase F session 3 kickoff (F3 + F4 — escape analysis + specialization)

Re-pasteable across sessions: check §2 for which F tasks are open.

```
Read /Users/alexmok/MCaml/DYNMEM_PLAN.md — §2 for current status
(Phases A–E, M/N/Math, G4, and Phase F session 2 (F1+F2) are all
closed; F1+F2 landed in commit `f492835` — implementation — and
`03d63e6` — plan doc/sub-decisions). Read §13.12 in full (all five
headline decisions plus the F1/F2 session-2 notes now folded into §2's
Phase F checklist) before writing any code. Also read §13.6
(specialize-aggressively/fall-back-gracefully), §13.5 (closure cell
layout), §13.10/§13.11 (tvar single-int amendment; TAdt/TParam
widening precedent for "widen an existing constructor, don't add a
parallel table"), and §13 (bottom) for escalation triggers. Read
CLAUDE.md for the pipeline and the manual rebuild command. Verify
`git status` is clean before starting.

**Read this before anything else — a load-bearing gap in the current
baseline, discovered while drafting this kickoff, not assumed away:**
F1+F2 chose the "stub at knormal" branch explicitly left open by the
prior session's own guardrails (§8.15's text: "If F2 lands a real
closure-conversion IR form, knormal's stub moves to wherever closure
conversion doesn't yet handle escape classification"). Concretely
today: `knormal.ml` raises `failwith` the instant it sees a `Closure`
construction OR a call through a `closure_env`-tracked local — meaning
**zero functions that use a lambda in any way currently survive past
knormal**, so **`fn_table` (post-inline) never contains a single
lambda-shaped CFG to classify.** F3 (escape analysis over `fn_table`)
therefore has NOTHING to analyze until closure construction and
closure application are lowered into SOME real CFG-level
representation. This session's actual first task — call it F2's
completion, not optional — is closing that gap: decide the concrete
`kexpr`/CFG IR shape(s) for "materialize a closure value" and "call a
closure value" (decision 5 already named the call-side op — `IApply of
vreg option * vreg * vreg list` in `cfg.ml`, dispatch macro deferred to
F5 — but nothing today MINTS one), get it flowing knormal → cfg_build →
`fn_table`, and ONLY THEN can F3 classify anything. `codegen_cfg.ml`
inherits the loud stub at THIS point (exactly as §8.15 anticipated):
"IApply lowering lands in F5" — a much narrower, more defensible stub
boundary than knormal's current blanket rejection, and the one
`cfg_build.ml`/`codegen_cfg.ml` changes this session should aim to land
on.

Before designing that lowering, investigate whether Known-classified
closures need real cell allocation AT ALL. Decision 3 frames F4 as
"whole-program defunctionalization" (MLton-style) — the classic result
is that a `Known` closure's captures thread through as ORDINARY EXTRA
ARGUMENTS to a cloned callee, with NO runtime closure cell ever
materialized; only `Escaping` closures (ref-stored, returned, re-passed
past a HOF's budget) need the real `{tag:-2, code, env_0, ...}` cell
and `IApply` dispatch. If that holds, the CFG-level "uniform form" F2
guardrails asked for may only need to be as rich as a monomorphize-
style PSEUDO-ARG token on a call argument that is a known-literal-or-
alias `Closure` — mirroring the EXISTING `"#arr:<aid>"` pseudo-arg
knormal already emits for array-bound names (`knormal.ml:823-828`,
consumed by `monomorphize.ml`'s `extract_maps`/`ensure_clone`/
`rewrite_caller`, `monomorphize.ml:187-261`) — with a real `IApply`-
producing lowering reserved for the genuinely-escaping cases only. This
is NOT decided — investigate and settle it as this session's first
sub-decision, following the exact D5/D6/G4/F1 protocol (research, state
the options, pick one, document why, THEN implement). If you instead
decide every Closure needs a real cell regardless of classification,
that's a legitimate answer too — but state why the MLton-style
zero-allocation path for Known closures doesn't work here before
picking the more expensive uniform path.

F3 scope (per §2's task line): a new standalone pass over the whole
`fn_table`, sitting between `Inline.run` and `Monomorphize.run`
(`main.ml:214` / `main.ml:219`, confirmed strictly sequential over the
same `fn_table : (string, Cfg.cfg_func) Hashtbl.t`) — needs the same
post-inline whole-program visibility the inliner itself needs, per
decision 3. Produces a per-lambda `{Known | Escaping of reason}`
classification using the boundary decision 2 already settled
precisely (quoted in §13.12: called immediately through zero or more
let/param aliases, or passed to a HOF parameter that is itself only
ever called within that HOF, stays `Known`; a `ref`-store, a
function-return, a non-calling parameter, or re-passing past another
HOF's exhausted `MCAML_SPECIALIZE_LIMIT` makes it `Escaping via
<reason>` instead). Do not relitigate this boundary — implement it.

F4 scope: NOT a new re-entrant phase — an EXTENSION of
`monomorphize.ml`'s existing per-argument-shape clone key
(`extract_maps`/`ensure_clone`/`rewrite_caller`, cited above), adding
"closure identity of a Known-classified TFun argument" as a second
specialization axis alongside the existing array-shape axis. Clones
re-enter `fn_table`/`fn_order` through the exact mechanism
`Monomorphize.run` already uses for array clones (`main.ml:222-226`) —
zero new plumbing in `main.ml` if F4 is a real extension rather than a
parallel pass. `MCAML_SPECIALIZE_LIMIT=K` (default 8) reuses
Monomorphize's existing per-source-function clone-count bookkeeping as
the SAME counter Known-lambda clones increment; beyond K, "give up
cloning and route through apply-dispatch instead" is new logic — and
since real apply-dispatch CODEGEN is F5's job, the fallback path this
session lands on should itself be a clearly-labeled, loud, narrow stub
(NOT a silent wrong compile), consistent with the "codegen_cfg.ml:
IApply lowering lands in F5" boundary above.

Facts already gathered — cite directly, do not re-derive: `main.ml`'s
full phase order and the exact `Inline.run`/`Monomorphize.run` call
sites (`main.ml:214`, `:219`, `:222-226`); `cost.ml`'s `ICall` pricing
(`cost.ml:36`, `:45-47`) and the `IApply` pricing decision 5 already
settled (`4 + 2 * K_max_captured`, a single whole-program constant
computed once escape analysis has enumerated every Escaping closure
shape — NOT per-call-site); `monomorphize.ml`'s full clone-key
mechanism (`is_pseudo_arr`/`aid_of_pseudo` at `:21-25`, `extract_maps`
at `:187-205`, `ensure_clone` at `:207-239`, `rewrite_caller` at
`:241-261`, `run` at `:263`); the closure cell layout and tag `-2`
(§13.12 decision 4); `MCAML_STRICT_HOT`'s home in `optimize.ml`'s Phase
3, not typing (§13.12 decision 5, unchanged — this session should NOT
need to implement the strict-hot check itself unless F3's
classification makes it trivial, but do not let it scope-creep in if
it's not trivial; F6 is a separate later task).

Behaviors that MUST survive (restated, now including F1+F2's own
list): every §13.10/§13.11/§13.12 decision including the tvar
single-int amendment; zero clones for value-polymorphic non-lambda
functions AND zero clones for lambda-free HOF-shaped functions that
happen to take a `TFun` param but are never called with a literal/
known closure (only ACTUAL Known-closure call sites should clone); the
§4.4 public-entry contract and every §4.1 reserved slot; ICons/IHead/
ITail budgets; the D5 decision-tree shapes; the region-walker domain
staying `TList TInt` only; `for_lift`'s oracle degraded mode and the
two-pass `main.ml` driver; every one of F1+F2's own smoke-test
behaviors (a HOF passing/calling a lambda literal types successfully;
a lambda stored in a tuple/record/ADT field is rejected at typing; a
closure handle merely passed through without being called or
constructed compiles and runs as inert scalar plumbing) — re-run these
as a sanity check before assuming F3/F4 changed nothing structurally
about the F1/F2 typing layer (they shouldn't; F3/F4 sit below typing).

Guardrails (the full battery, now including F1/F2's baseline):
- Baseline BEFORE the first edit — rebuild per CLAUDE.md; `cat
  lib/math.mcaml scripts/mc_test_suite.mcaml | ./mcaml -o build_suite
  && python3 tools/sim_check_suite.py build_suite` (66/66 + async);
  `python3 tools/sim_check_phase_d.py` (40/40); `python3
  tools/sim_check_phase_e.py` (42/42 + 12 probes); hash the five
  canaries against `/tmp/mcaml_out/canary_hashes_f_baseline.txt`
  (regenerate the compare set with a fresh `./mcaml` compile of each of
  test_all/primitives_v1/demo_classifier/stress_nested_if/
  test_arr_set — must still match byte-for-byte, lambdas are purely
  additive); all nine `/tmp` harnesses (test_dyn_array, test_cons,
  test_regions, test_fixed_point, test_adts, test_list_match,
  test_tuples_records, test_polymorphism, test_param_types).
- Five canaries stay byte-identical THROUGH F3/F4 too — escape
  analysis and specialization are new machinery that only fires when a
  `TFun`-shaped value is actually in play; a lambda-free program must
  not change AT ALL.
- If F3/F4 needs a NEW reserved scoreboard slot beyond §4.1, or a new
  IR op beyond the `IApply` decision 5 already named, that's fine and
  expected (decision 5 anticipated exactly this) — but document it in
  §4.1/CLAUDE.md's module layout as you go, per §3.6's "new IR ops are
  opaque to all existing passes" discipline (DCE/CSE/copy_prop/
  liveness/regalloc must all either handle the new op correctly or
  visibly skip it, the same way they already skip `$ref_*`-prefixed
  SR carriers and macro-getter hidden writes).
- Zero new menhir conflicts is N/A this session (no grammar changes
  expected) — but if F3/F4's design ends up needing one, run menhir and
  confirm, don't assume.

If the MLton-style zero-allocation investigation above, or the
IApply/pseudo-arg design question, forces a §3 decision to bend (most
likely candidate: §3.6 "new IR ops are opaque to all existing passes,"
if a pseudo-arg-style token turns out to need bespoke handling in
DCE/CSE/liveness the way array pseudo-args already do), STOP and flag
per §13 — do not special-case through it silently.

After the session: update §2 with commit hashes (decision-record commit
separate from implementation commits, same discipline as every prior
phase — including the NEW closure-lowering-boundary decision this
kickoff surfaced, which is not one of §13.12's original five and needs
its own citation trail same as F1's three sub-decisions did), leave the
tree green, and note in §2 exactly which lambda usages now fully
compile end-to-end (Known, fully specialized, zero apply-dispatch) vs.
which still hit the narrower F5-deferred stub (Escaping). Session 4 is
then F5 (apply-dispatch runtime: the closure objpool cell, the
`mcaml:apply` macro-dispatch function, env-unpack prelude) plus
whatever of F6 (diagnostics, `MCAML_STRICT_HOT`) falls out naturally —
do not start F5's actual runtime codegen this session unless F3+F4
leaves genuinely no Escaping closures anywhere in the test battery (in
which case say so explicitly rather than silently skipping F5's own
kickoff).
```

### 8.17 Phase F session 4 kickoff (F5 — apply-dispatch runtime)

```
Read DYNMEM_PLAN.md §2 for current status (Phases A–E, M/N/Math, G4,
and Phase F sessions 2–3 (F1–F4) are all closed; F3+F4 landed in commit
`48dc9c3` — implementation — plus a separate plan-doc commit documenting
decision 6 and updating §2's Phase F checklist). Read §13.12 in full,
especially decision 6 (the closure lowering boundary this session's own
predecessor had to invent: why `IClosureMake` is NOT side-effecting,
and what that implies about which instances survive to codegen) and
decision 5 (the `IApply` cost formula, `MCAML_STRICT_HOT`'s home in
`optimize.ml`/Phase 3, not typing). Read §13.6 (specialize-aggressively/
fall-back-gracefully) and §13.5 (closure cell layout, tag `-2`, unified
objpool). Read CLAUDE.md for the pipeline and manual rebuild command
(add `closure_spec.cmo` between `inline.cmo` and `const_fold.cmo` if not
already present in your working copy — session 3 wired it into
`main.ml` between `Inline.run` and `Monomorphize.run`). Verify `git
status` is clean before starting.

**What F3+F4 leaves for you.** `closure_spec.ml` fully resolves two
shapes to zero-cost ordinary `ICall`s (same-function immediate
invocation, and cross-function single-hop through one HOF parameter,
both with and without captures) — verified in
`scripts/test_lambdas.mcaml`. Everything else is deliberately left as a
surviving `IClosureMake`/`IApply` pair that hits a loud
`codegen_cfg.ml` stub the instant it's actually compiled:
`(!r_holding_a_closure)(...)`-style ref-then-call patterns (these
currently fail EARLIER, at knormal's defensive `Typing.fun_sigs`
membership check, with a related but distinctly-worded message — see
decision 2's v1 scope note and the F2-completion entry in §2 — not at
the F5 stub; if F5's design changes what knormal accepts, re-examine
that check), lambdas forwarded through two or more HOF parameter hops,
lambdas forwarded across a self-tail-recursive back-edge, lambdas
merged from ambiguous control flow (`if c then lam1 else lam2` — the
`test_lambdas.py` harness's own reject probe exercises exactly this),
and anything beyond `MCAML_SPECIALIZE_LIMIT` (default 8) clones of one
source callee. F5's job is to make EVERY ONE of these actually compile
and run correctly via real apply-dispatch, not to re-litigate which
ones F3+F4 should have specialized instead (that boundary is settled;
extending it is a legitimate FUTURE follow-up, not F5's task).

**F5 scope, concretely:**
1. Closure cell layout (§13.5, decision 4): `{tag: -2, code, env_0,
   env_1, ...}` in the unified objpool (`mcaml:objpool cells`, the same
   pool ADTs/tuples/records/cons cells already share). `code` needs a
   concrete encoding — an integer identifying which lifted lambda
   helper to dispatch to. Decide (and document, following the exact
   decision-record protocol every prior sub-decision in this plan
   used): is `code` a small dense integer assigned per-lambda-helper
   at compile time (a new global table, lambda helper name → code),
   or the helper's already-existing name hashed/interned some other
   way? Whichever you pick, `codegen_cfg.ml`'s `IClosureMake` lowering
   needs to actually allocate this cell (mirrors `cmd_adt_alloc`'s
   existing `IAdtAlloc` lowering almost exactly — read
   `codegen_helpers.ml`'s `cmd_adt_alloc` before writing a new one).
2. `mcaml:apply` macro-dispatch function: given a closure handle and a
   fixed argument-count convention, reads the cell's `code` field,
   dispatches to the corresponding lifted lambda helper. Since
   Minecraft has no runtime function-pointer/computed-goto primitive,
   this is necessarily a `execute if score $code matches N run function
   mcaml:<helperN>` chain (or an `execute store` into a macro token
   dispatched via `function ... with storage`, mirroring the existing
   macro-getter pattern in `codegen_helpers.ml` for arrays/cons/ADTs —
   read that pattern before inventing a new one). Decide whether the
   dispatch chain is one shared function covering EVERY closure-typed
   call site program-wide (simplest, but every call site pays the cost
   of testing against every possible `code` value in the worst case)
   or synthesized per distinct "closure shape signature" seen at
   `IApply` sites (narrower chains, more generated files) — this is
   exactly the kind of design question §13's escalation protocol wants
   surfaced and decided before implementation, not improvised mid-way.
3. Env-unpack prelude: a lifted lambda helper (`<parent>__lamN`) today
   takes its captures as ordinary LEADING parameters (for_lift's
   existing lifting convention, unchanged since F2) — when invoked via
   `mcaml:apply` rather than a direct `ICall`, something has to read
   `env_0, env_1, ...` back OUT of the cell and INTO those leading
   params before controls transfers. Decide where this unpacking lives:
   inside `mcaml:apply` itself (one unpack per dispatch, parameterized
   by captured-count) or as a per-helper thin wrapper function. Cost
   this against decision 5's `IApply` pricing (`4 + 2 *
   K_max_captured`) — you likely need to actually COMPUTE
   `K_max_captured` now (a single whole-program constant: the max
   captured-variable count across every closure shape that survives to
   an `IApply` site after F3+F4 has run) rather than the placeholder 0
   session 3 left in `cost.ml`'s `IApply` arm (grep for "K_max_captured"
   there — it's flagged as exactly this session's task).
4. `IClosureMake`/`IApply` lowering in `codegen_cfg.ml`: replace both
   loud stubs (search for "lands in F5" — there are two, one per op)
   with real command emission using the mechanisms above.

**Guardrails, extending session 3's own battery:**
- Baseline BEFORE the first edit: rebuild per CLAUDE.md; the same full
  battery session 3 ran (suite 66/66+async, Phase D 40/40, Phase E
  42/42+12, all nine `/tmp` harnesses) plus `scripts/test_lambdas.mcaml`
  via `/tmp/mcaml_out/test_lambdas.py` (uncommitted — recreate it from
  this session's description if it's not in your working `/tmp` state)
  — all green, five canaries byte-identical (this session's own
  reproducible hash method: `cat <dir>/*.mcfunction | sort | sha256sum`
  per script; there is no committed canary-hash file to diff against,
  regenerate and compare against your own pre-edit run).
- The five canaries must STILL be byte-identical after F5 lands — F5 is
  new machinery that only fires on Escaping closures, and the canary
  programs contain none.
- `scripts/test_lambdas.mcaml`'s four Known-path entries must STILL
  compile to the exact zero-apply-dispatch output session 3 verified
  (grep for `apply`/`closure(`/`obj_tag`/`obj_f` — none should appear)
  — F5 must not regress F3+F4's zero-cost path by, e.g., accidentally
  routing a Known closure through apply-dispatch.
- Add NEW test coverage for each Escaping shape F5 makes real:
  ref-stored-then-called (once F5 also decides whether to lift
  knormal's current defensive-reject on this pattern — that's a
  legitimate scope question THIS session should explicitly decide, not
  silently leave stubbed), multi-hop-forwarded, ambiguous-merge (the
  existing reject probe should now compile and RUN instead of
  rejecting — turn it into a positive test), and budget-exceeded (>8
  distinct closures into one HOF, forcing the fallback path).
- If any of this forces a §3 decision to bend, or reopens decision 6's
  "IClosureMake is not side-effecting" tradeoff, STOP and flag it per
  §13 — don't special-case through it silently.

After the session: update §2 with commit hashes (decision-record commit
separate from implementation, same discipline as every prior phase),
leave the tree green, and note in §2 whether F5 closes EVERY Escaping
shape from session 3's list or whether some (e.g. ref-then-call) are
deliberately deferred further with their own loud stub. F6
(diagnostics, `MCAML_STRICT_HOT`) is explicitly optional this session —
land it only if it falls out naturally, per the original F kickoff's
own framing; do not scope-creep into it if it doesn't.
```

## 9. Rollback and A/B flags

**[LANDED 2026-07-08]** `MCAML_NO_M3A=1` (skip the const_fold/copy_prop/
local_cse/dce fixed point — both sweeps) and the umbrella `MCAML_O0=1`
(unoptimized baseline: implies NO_INLINE + NO_M3A + NO_LICM + NO_SR +
NO_UNROLL + NO_SROA). Every pass kill switch now reads through
`Cfg.pass_disabled`, so O0 is enforced in one place. O0 deliberately
does NOT touch monomorphize (array-param programs need it to compile),
tick_split, or tick_guard (server-protection mechanisms) — disable the
tick mechanisms separately on BOTH sides of a comparison if needed.
**[LANDED 2026-07-08, same session — TTail fallthrough miscompile,
CANARIES INTENTIONALLY MOVED]** Exhaustive O0 verification exposed a
latent codegen bug: the TTail dispatch was a bare `function mcaml:<f>`
line, so when the callee returned, execution fell through into the
guarded exit-arm/merge lines that follow the dispatch in emission
order — with guard cond slots the callee had clobbered (TTail has no
save/restore helper). Optimized builds passed only because their exit
arms were accidentally idempotent under re-execution; under
MCAML_NO_M3A the phase-D suite's d05_tree_recursion returned 2 instead
of 5 (minimal repro: count_leaves_tco — the un-copy-propagated Leaf arm
writes `$r1 = 1` after reading it, so each ancestor frame's replay
corrupts acc). Fix: codegen_cfg.ml emits every TTail dispatch as
`return run function mcaml:<f>` (MC 1.20.5+, within the pack_format 41
baseline; sim.py extended to model `return run <cmd>`). This also stops
mid-loop tick_guard yields from replaying every ancestor's exit arm
during unwind. Non-tail direct calls need no change: liveness's
guard-chain pinning forces any guarded call with guarded successors
through the save/restore helper path.
CONSEQUENCE FOR CANARY GATES: every TCO'd function's tail-dispatch line
gains the `return run ` prefix — that exact prefix is the ONLY change
(verified: all five canaries + all three suite builds are byte-identical
after stripping it). `canary_hashes_f_baseline.txt` and any other stored
hashes must be regenerated once from a post-fix compile.
VERIFIED (hermetic worktree at 98a5e87 + these edits only): all three
suites (66 + 40 + 42-check + async + §4.4 post-conditions + grep pins +
12 rejection probes) green under sim at default, NO_M3A=1, and O0=1;
O0 output byte-identical to the six flags stacked; each individual flag
green on the 66-check suite; repro programs correct at all three
levels.
IN-GAME VERIFIED 2026-07-08 (post-fix binary incl. Phase F F1–F4): all
four dist/ packs run manually in real Minecraft — mcaml_test_suite
(run_all ALL 66 PASSED; async_start PASS, $ret = 1800030000 across
ticks — the sharpest probe of `return run` dispatch + tick_guard yield
unwind in the real parser), mcaml_phase_d_suite (run_all_d ALL 40
PASSED, $objpool_next = 0), mcaml_phase_e_suite (run_all_e ALL 42
PASSED, $objpool_next = 0), and mcaml_phase_d_o0 (the MCAML_O0=1
compile of the phase D suite — the exact configuration that
miscompiled d05_tree_recursion pre-fix — ALL 40 PASSED). The canary
hash baseline (/tmp/mcaml_out/canary_hashes_f_baseline.txt) was
regenerated from the post-fix compiler; only test_all /
demo_classifier / test_arr_set moved (primitives_v1 and
stress_nested_if contain no TTail dispatches and kept their hashes).

Add these environment flags in the same style as the existing
`MCAML_NO_*` toggles (CLAUDE.md "Build & run" section):

- `MCAML_NO_DYN_HEAP=1` — disable all dynamic-heap codegen. Any use of
  `TArrDyn` or `TList` in source becomes a compile-time error. Lets you
  A/B a program that uses only static arrays against the full pipeline to
  confirm no overhead leaked into the static path.
- `MCAML_NO_REGION=1` — disable `region` blocks. `region (fun () -> body)`
  compiles as if the body were inline (no snapshot, no restore, no copy).
  Used to A/B the region machinery's overhead.
- `MCAML_DUMP_HEAP=1` — stderr dump of every heap allocation site with its
  pool, size, and location. For debugging leaks and unexpected allocations.

Add the flag handling in `main.ml` next to the existing `MCAML_NO_INLINE`
etc. reads, and gate the relevant passes on the flags.

## 10. Glossary

Quick reference. See §4 for the full contract.

| Term | Meaning |
|------|---------|
| pool | One of the three NBT lists: `scratch`, `permheap`, `objpool` |
| objpool | Unified heap-object pool (D4): tag-discriminated compound cells for cons and ADTs |
| tag | Per-type ctor index (D3, 0..n-1 in decl order) stored in each objpool cell; interpreted only under the scrutinee's static type |
| bump counter | `$<pool>_next` scoreboard slot holding next free index |
| handle | An integer vreg value that identifies an allocation in a pool |
| nil | `-1` handle, sentinel for empty list |
| region | A lexical `region (fun () -> ...)` block; snapshot + restore |
| copy-on-escape | Deep-copy of a region's return value into the parent arena |
| arena reset | Truncating a pool back to a saved bump-counter position |
| static path | The existing `TArr` / `arr_env` / per-aid helper pipeline |
| dynamic path | The new `TArrDyn` / shared-helper pipeline |
| entry point | A top-level function that can be called externally; gets end-of-invocation reset |

## 11. Out of scope for this plan

Things that have been discussed but intentionally deferred. Flag these to
the user if a task tempts you toward them.

- Tracing garbage collection (mark-and-sweep, copying collector). Possible
  future work on top of the IR added here, but not in this plan.
- Refcounting with compiler-inserted inc/dec. Rejected because it breaks
  purity of assignment.
- Explicit user-facing `free`. Rejected for the same reason.
- Full Tofte-Talpin region polymorphism in the type system. The v1 region
  check is "you can return anything; we copy on escape." Region inference
  is a later refinement.
- Unifying the static and dynamic array runtimes. Rejected because it
  regresses SROA/LICM on matmul workloads.
- String types. A separate decision — see the design discussion around
  MineTorch and vocab tables. For now strings are out of scope.
- MineTorch itself (the ONNX-importing ML DSL). Entirely separate project,
  interfaces with MCaml through a small set of NBT-storage builtins.
- `region` blocks in non-public-entry functions. v1 requires that any
  function containing a `region` block is a public entry point (see §C3
  commit message for the concrete failure mode). The lift path is
  saving/restoring `$region_save_<k>_*` scoreboard slots across non-
  leaf calls via `mcaml:stk frames`; not worth the per-call overhead
  for v1.
- Tick-guard-style slicing inside `region_truncate_<k>_*.mcfunction`
  helpers. §5.6 originally specified this but the synchronous-caller
  contract makes it incorrect: yielding mid-helper via `schedule ...
  1t ; return 0` returns partial work to the caller, which then
  continues past `IRegionExit` with a dangling pool. v1's helpers run
  synchronously to completion, capping region size at ~20k cells per
  pool (Minecraft's `maxCommandChainLength`). A proper async exit
  requires the caller to also yield and resume via a continuation
  mechanism — future work.

## 12. Post-memory roadmap — load-bearing decisions

Phases A–C made MCaml a functional language with dynamic memory. The work
below takes it toward a general-purpose ML-ish language and toward
MineTorch-usable numerics. Each decision here has the same status as the
§3 decisions: settled by design discussion, do not relitigate without a
concrete blocker.

### 13.1 Representation ABI: every value is one int

This is already true in practice and is now committed in writing:

- Scalars (`TInt`, `TBool`, `TUnit`, `TFloat`) are 32-bit signed scoreboard ints.
- Handles (`TArrDyn`, `TList`, `TADT`, closures) are 32-bit signed scoreboard ints pointing into a pool.
- No boxing. No tag bits on the scalar path. Tag bits live inside pool cells (Phase D), not on the value.

This is what makes Phase E's let-polymorphism cheap — uniform representation means **no new codegen paths are needed for polymorphism beyond what the existing monomorphize-on-template covers for `TArrStatic`/`TMat`**. The only things that ever require template specialization are types that carry compile-time shape in the type itself (array length, matrix dimensions).

### 13.2 Decimals are Q16.16 fixed-point, not IEEE float

Software-emulated IEEE float is ~30 cmds/add and ~100 cmds/multiply, so a
single matmul step blows past tick budgets before doing any work. Fixed-
point is the only viable option.

- **Format**: Q16.16 signed, stored as a 32-bit scoreboard int. Range ±32,767.999…, precision ~1.5e-5.
- **Add/sub/neg/compare**: direct scoreboard ops, same cost as int arithmetic.
- **Multiply**: dedicated helper. Two variants; pick in N6:
  - *Pre-shift variant* (~3 cmds): shift both operands right by 8, multiply, interpret result as Q16.16. Loses low 8 bits of each operand. Use for hot inner loops.
  - *Split-half variant* (~8 cmds): multiply 16-bit halves pair-wise and recombine. No precision loss. Use for general-purpose math.
- **Divide**: scale numerator up, divide, interpret as Q16.16. ~5 cmds via helper.
- **Weight loading**: `execute store result score … run data get storage <path> 65536` reads a NBT double and multiplies by the Q16.16 scale in one command. This is the one MC primitive that crosses the double/int boundary, and it's free. Host-side `tools/pack_datapack.py` quantizes weights at compile time.

Dynamic range caveats:
- Q16.16 saturates around `|x| > ~32k`. NN activations post-layer-norm rarely hit this.
- `exp(x)` overflows Q16.16 at `x ≈ 10.4`. Clamp before calling.
- Composing multiple operations amplifies precision loss. Expect divergence from numpy at the 3rd-4th decimal — document this in MineTorch validation.

If a real workload needs more range later, the upgrade path is per-tensor scale tracking (type-level annotation), not switching the scalar format. Deferred until a concrete workload demands it.

### 13.3 `Mod` operator is a prerequisite for N, not a separate design decision

Minecraft's `scoreboard players operation X %= Y` already exists. MCaml's surface just hasn't wired it through the AST / parser / codegen. Adding it is ~20 lines (see Phase M) and it simplifies any hash / index / ring-buffer code. Without it, "fractional part of a Q16.16 value" costs 3 cmds (`x - (x / 65536) * 65536`); with it, 1 cmd. Do M before N.

### 13.4 Transcendentals are library code, not compiler features

Once fixed-point lands, every transcendental compiles to user-level MCaml. The canonical technique is **range reduction + LUT**:

- **exp(x) for x ≥ 0**: split `n = x / 65536`, `f = x % 65536`, look up `int_exp[n]` (11 entries, n = 0..10) and `frac_exp[f / 256]` (256 entries covering `[1, e)`), multiply. Cost: **~21 cmds** per call as implemented in `c1acdc6` (positive-only variant, no branch overhead). Precision ~1e-2 on output; add linear interpolation between LUT entries for ~1e-5 at +8 cmds.
- **exp(x) for x < 0**: caller wraps with `fdiv(1.0, exp_fixed(neg_f(x)))`. Not inlined inside `exp_fixed` because merging the two branches into one function balloons the command count (51 cmds for both branches in a single file vs 21 for positive-only). MineTorch's softmax path always negates inputs beforehand so the split is not a usability burden for the primary client.
- **log, sigmoid, tanh, gelu**: same structure, different tables. Expect similar ~20–30 cmd costs per call.

**Budget correction (post-Math1a, 2026-04-15)**: the original "~11–16 cmds with Mod, ~13–18 cmds without" estimate quoted above underestimated the real cost by ~35–50%. The missing piece was the per-op cost of range reduction: one `to_int`-equivalent (3 cmds), one `mod` (3 cmds), one `div` (3 cmds) = 9 cmds just to compute the LUT indices, BEFORE any LUT access or multiply. Two LUT macro dispatches add 8 cmds. fmul adds 5. Total ~22, which landed at 21 after regalloc. The **corrected §12.2 budget for exp/log is ≤25 cmds/call**; escalate above that, not above 15. sigmoid/tanh/gelu should fit in the same range since they share the same range-reduction + LUT + mul pattern.

**Future optimization track** (deferred pending actual MineTorch perf signal): the 21 → ~13–15 cmd gap could be closed by (a) hoisting the `IConst 65536` / `IConst 256` constants into reserved always-live scoreboard slots (saves ~4 cmds per call by eliminating per-call loads and copies), (b) a `global_cse` pass that dedupes shared intermediates across the div+mod+div chain (saves ~2–3 cmds), or (c) a dedicated "lookup two LUTs in one dispatch" macro helper (saves ~2–3 cmds). Each is 0.5–1 session of compiler work. Not on the critical path; land only if a MineTorch workload reveals the exp/log cost is the bottleneck. Until measurement says otherwise, the 21-cmd variant is Good Enough.

Table sizes are small (~0.5 KB NBT per function). Bootstrap them via **Phase G's synthesized `__globals_init.mcfunction`** (landed in `18d22a4`), which the datapack load tag fires once per world load. The earlier plan's "separate `math_init.mcfunction`" suggestion is subsumed by Phase G — there's no need for a second dedicated init file, since any program with top-level `val` definitions automatically gets the LUTs populated at load time. Math4 therefore reduces to "nothing additional required" and is marked done by reference to Phase G.

**Crucial**: this is a pure library, not a compiler built-in. `lib/math.mcaml` is the first client of the fixed-point type and validates its usability for real workloads. MineTorch imports it; human users import it the same way.

### 13.5 Unified object pool for ADTs, cons cells, and closures

Phase D decides how ADTs are laid out in the pool. Two options:

- **Option a (unified objpool)**: one pool `mcaml:objpool cells` with tag-discriminated compound cells. Cons cells become `{tag: 1, h, t}` (tag = `Cons` constructor id). ADTs for free.
- **Option b (per-type pools)**: keep `conspool` for lists, add one pool per user-defined ADT, closures get their own pool.

**Recommendation**: Option a. Fewer reserved storage paths, one `objpool_next` counter, one arena reset path. Cons cells pay a 1-cmd cost for the extra tag write but that's cheap relative to the 5-cmd `ICons` budget. Make the decision in D4 before touching codegen — once the pool layout is committed, backing out is expensive.

**[LANDED in D4]**: Option a implemented. The predicted 1-cmd tag-write
cost turned out to be zero — the tag is a codegen-time constant and rides
inside the `append value {tag:1,h:0,t:0}` literal, so `ICons` stayed at
5 commands. See §2 D4 and §5.1.

**[D5 nullary-ctor representation]**: allocate-uniformly. A nullary ctor
mention allocates a bare `{tag: k}` cell (no `f<i>` fields) — 3 commands
per mention (append + handle copy + counter bump), exactly `IAdtAlloc`
with zero fields. The rejected alternative (immediate small-int encoding,
no cell) would break tag-read uniformity: every match would first need an
is-it-a-handle test before `ITagGet`, costing more than it saves for any
type with at least one non-nullary ctor. Revisit only if a nullary-only
enum in a hot loop shows up in profiling (that case degenerates to ints
and could skip the pool entirely — a typing-level optimization, not a
cell-layout change).

**[D6 list/ADT unification]**: keep the fast path, extend the pattern
compiler to lists (option b of the D6 kickoff). The TList runtime is
NOT retired: nil stays the free `-1` sentinel (§4.2), cons cells stay
`{tag:1,h,t}`, ICons/IHead/ITail keep their 5/3/3 budgets (§5.1–5.2),
`head`/`tail`/`is_nil` builtins stay for straight-line code, and the C5
region walkers are untouched. What changes is surface only: `[]` and
`h :: t` become valid PATTERNS on a TList scrutinee.

Full retirement (option a — Nil/Cons as ordinary ctors of a declared
list type) was rejected because it regresses committed budgets: every
`[]` mention would allocate a `{tag:0}` cell (3 cmds + pool growth per
mention, including once per iteration in list-building loops), `is_nil`
would go from a 2-cmd handle compare to a 3-cmd tag read + 2-cmd
compare, and the nil-terminated C5 walkers (which terminate on -1 with
no cell read) would need a rewrite — a §13 escalation with no
compensating win.

Decision-tree lowering for a TList column: the two-ctor signature
{[], ::} is discriminated by the existing Eq-against--1 compare on the
HANDLE — no tag read, ever. A non-nil TList handle always points at a
tag-1 cell, so the nil test alone is complete. The cons case reads its
sub-occurrences through the existing KHead/KTail (they ARE the field
getters, 3 cmds each), and only for sub-patterns that inspect or bind
(a `_ :: t` pattern emits no head read — same used-fields filter as
IFieldGet). Nil arm cost = the same 2-cmd IConst+Eq sequence is_nil
compiles to today; the 1-cmd `matches -1` form remains the same future
peephole B7 documented.

Representation choice: dedicated `PNil` / `PCons of pattern * pattern`
AST variants, NOT magic `PCtor ("[]"/"::")` names. Registering Nil/Cons
in `ctor_info` would let them leak into expression typing's ctor
fallback and allocate `{tag:0}` cells behind the sentinel ABI's back;
dedicated variants keep the builtin list type out of the nominal-ADT
namespace entirely, and OCaml's exhaustiveness warnings enumerate every
pass needing a new arm (alpha, for_lift, typing, knormal).
Exhaustiveness/redundancy go through the same Maranget matrices: TList
columns get specialize_nil / specialize_cons (arity 0 / arity 2 with
field types [TInt; TList TInt] — v1 monomorphic) and a two-ctor
complete-signature test (complete iff both a `[]` and a `::` head
appear). `match` subsumes the head/tail/is_nil idiom; the builtins
remain as the cheaper choice only when a single field is needed
without dispatch.

Scope note: ctor-in-list patterns (`Circle(r) :: t`) are untypeable in
v1 — B2's monomorphic int lists reject non-int heads at `::`, so no
such list can be constructed. List-in-ctor (a TList ctor field, D3)
works. Revisit when Phase E makes `'a list` real.

**[D7 tuples — structural, dedicated variants]**: option (b) of §8.11.
`TTuple of typ list` in typ, `Tuple of expr list` in expr, `PTuple of
pattern list` in pattern — nothing enters the ctor namespace, same
posture as D6's PNil/PCons. Option (a) (parse-time desugar to a
synthesized nominal ctor) fails for the reason §8.11 predicted: nominal
decls are keyed by ctor name and monomorphic, but tuple shapes vary per
use site and the parser cannot know field types.

- Type surface: OCaml's `int * int`, with OCaml's disambiguation
  against ctor decls. The grammar layers `typ` into
  `typ := typ_atom (TIMES typ_atom)+ → TTuple | typ_atom`, and
  `ctor_typs` keeps consuming `typ_atom TIMES` at the top level — so
  `of int * t` stays TWO fields and a tuple-typed ctor field must be
  parenthesized: `of (int * int) * t`. `typ_atom` gains
  `LPAREN typ RPAREN`. Zero new menhir conflicts.
- Expr surface `(a, b, c)`; pattern surface `(p1, p2, p3)`. Arity ≥ 2
  (a 1-tuple is just parens, unchanged).
- Runtime: a tuple value is one objpool handle to a `{tag:0, f0, ...,
  f<n-1>}` cell, allocated by the existing KAdtAlloc/IAdtAlloc with
  tag 0 (3+n cmds); fields read by the existing KFieldGet/IFieldGet
  (3 cmds). Zero new IR ops. The tag value is never read: a TTuple
  match column is an always-complete single-ctor signature, so D5's
  single-ctor rule dispatches with ZERO tag reads and the used-fields
  filter elides reads for `_` sub-patterns.
- Element representability = D3's ctor-field rules (TInt/TFloat/TBool/
  TList/TAdt/record, plus TTuple itself — a nested tuple is one
  handle); TArrDyn/TUnit/TRef/TArrStatic/TMat rejected with the same
  messages.
- Typing is exact structural equality (`=` on typ works — typ carries
  no refs), so tuples pass through fun_sigs param/return checks
  unchanged: tuple params and returns ride the scalar-handle
  convention with zero knormal/cfg_build edits.
- Exhaustiveness/redundancy: Maranget `useful` gets a TTuple column
  arm — signature complete iff any PTuple heads the column (there is
  only one "ctor"); specialize unfolds the element sub-patterns with
  element types from the scrutinee TTuple. Witnesses render as
  `(_, 5)` tuple syntax.
- Destructuring-let lands NOW as parse-time sugar:
  `let (a, b) = e in body` → `Match(e, [(PTuple [PVar a; PVar b],
  body)])`. Tuple patterns only (records destructure via match);
  nested patterns come free since the parenthesized form recurses
  through the pattern grammar.

**[D8 records — nominal decl, dedicated AST, typing-side tables]**:
records get the decl-level nominal home §8.11 sketched, but per the D6
lesson the "ctor synthesized from the type name" idea is dropped — a
synthesized `Point` (or any user-spellable name) in ctor_info could
collide with or leak into expression typing's ctor fallback. Instead:

- Decl: `type point = { x : int; y : int }` parses to a new def
  variant `RecordDecl of string * (string * typ) list`. typing.ml
  registers it in `record_decls` (type → fields in decl order) and
  `record_fields` (field → owner type, index, field type). Record
  type names share the type namespace with ADT decls (collision =
  error). Field types pass the same representability check as ctor
  fields.
- ONE GLOBAL FIELD NAMESPACE, mirroring D3's global ctor namespace: a
  field name belongs to at most one record type. This is what lets
  literals and `r.x` resolve with zero type annotations; the cost
  (can't reuse `x` across two record types) matches the ctor-name
  restriction users already live with.
- A record value types as `TAdt name` — no new typ constructor — so
  param passing, ctor-field/tuple-element representability, and the
  D5 region-return rejection all reuse the existing TAdt arms.
  `adt_decls` and `record_decls` are disjoint by construction; Match
  typing and `useful` consult both.
- Literal `{ x = 1; y = 2 }` is a dedicated `Record of (string *
  expr) list` expr node. Typing resolves the owner type from the
  first field name and requires the EXACT field set: unknown field,
  duplicate field, and missing field are all errors; permutation is
  fine. knormal (not the parser — the parser owns no field tables;
  not typing-as-rewrite — infer stays analysis-only) lowers it:
  fields evaluate in SOURCE order into temps, then one
  `KAdtAlloc(d, 0, temps-in-DECL-order)`. Same `{tag:0, f0...}` cell
  as a tuple; 3+n cmds.
- Pattern `{ x = px; y = py }` → `PRecord of (string * pattern)
  list`. Fields MAY be omitted (missing = PWild, OCaml-style), and
  are checked for dup/unknown against the owner. The Maranget column
  arm normalizes each PRecord to a full decl-order sub-pattern vector
  and then behaves exactly like TTuple: single-ctor complete
  signature, zero tag reads, used-fields filter (an omitted or `_`
  field emits NO obj_f<k> read). Witnesses render as
  `{x = _; y = 5}` with the full field set.
- Field access surface: `r.x`, via a new DOT lexer token and a
  dedicated `Field of expr * string` expr node → KFieldGet, 3 cmds.
  Lexing is safe: ocamllex longest-match keeps `0.5` a FLOAT (the
  float regex `digits '.' digits*` beats INT DOT), and selector dots
  only occur inside the bracketed selector token. Match-destructuring
  remains available; `r.x` is the cheaper single-field idiom, same
  relationship as head/tail vs list match (D6).
- LBRACE/RBRACE finally get lexer rules; the pre-existing menhir
  unused-token warning count drops from 3 to 1 (only the IN
  precedence note remains).

Both features compile to exactly the committed D4/D5 machinery — no
new IR ops, no codegen/optimizer/sim edits, no reserved slots, no pool
changes. Phase E ('a tuples / polymorphic fields), G3 (modules), and
first-class field names stay out of scope.

Closures reuse this pool in F5. Closure cells are `{tag: $CLOSURE, code, env_field_0, env_field_1, ...}`.

### 13.6 Lambdas: specialize aggressively, fall back gracefully

One language surface, one lambda form, two lowering strategies picked by the compiler:

- **Known lambdas** (never stored, never returned to an escaping context, never passed to an HOF parameter that escapes) get whole-program defunctionalization. Each HOF clones per unique closure that flows in. This is what MLton does and it gets ~95% of real HOF use at zero runtime cost.
- **Escaping lambdas** fall through to the apply-dispatch runtime: closure pool cell, macro dispatch to `mcaml:apply`, env-unpack prelude. Cost is ~4 cmds fixed + 2 cmds per captured variable, per call, plus a hidden ~2× wall-clock multiplier from macro substitution.

**Specialization budget**: `MCAML_SPECIALIZE_LIMIT=K` (default 8). Stop cloning after K specializations of a single source function and fall back to apply-dispatch beyond that. Prevents code size blowup in worst-case programs.

**Diagnostic contract**: the compiler reports `[closure] <name>: specialized (N call sites)` or `[closure] <name>: ESCAPING via <reason> — ~M cmds/call, inside hot loop <loop>` so the user can see the cost tradeoff at compile time. `MCAML_STRICT_HOT=1` promotes escaping-in-hot-loop to a compile error.

**What this loses**: closures stored in data structures (callback tables, parser combinators, visitor patterns), closures returned from factories, first-class modules. For MCaml's target workloads (ML inference, datapack event handlers) these are all absent or cold-path, so the loss is acceptable. For human-written interpreters / DSLs, users will feel it — document as a known limitation.

### 13.7 Phase ordering rationale

The order is D → E → F → G → M → N → Math, but **M → N → Math can run in parallel with D/E/F** because it touches a disjoint set of files. Recommended practical ordering:

1. **M** (tiny, prerequisite, 1 session)
2. **N** (fixed-point foundation, 2 sessions)
3. **Math** (validates N with real workload, 2 sessions) ← MineTorch unblocked after this
4. **D** (ADTs; can also be done before N if MineTorch is not the priority)
5. **E** (HM + polymorphism; most useful after D because polymorphic list functions become writable)
6. **F** (lambdas; depends on D for the pool layout and on E for the `'a -> 'b` type)
7. **G** (remaining conveniences; lands whenever)

The MineTorch path (M → N → Math → tools/pack_datapack.py extension) is only 4–5 sessions and doesn't require D/E/F to land first. Prioritize it if MineTorch has concrete deliverable pressure.

### 13.8 Out of scope for this roadmap

- IEEE-754 float emulation. Rejected as per §13.2; precision is not worth the tick cost.
- `Box<dyn Fn>`-style opt-in escaping closures as a separate surface. The compiler's escape analysis makes this automatic — users don't need to annotate.
- First-class modules, functors, object system. These are simulable with ADTs + specialized lambdas once D and F land; no separate runtime work needed.
- String values. Still out of scope per §11.
- Self-hosting MCaml. Would require escaping closures to be performant in hot loops, which the apply-dispatch cost model explicitly doesn't support.
- Training (as opposed to inference) in MineTorch. Training needs f32-level precision and gradient tracking; Q16.16 is not sufficient. Inference only.

### 13.9 Array-length polymorphism is a host-side concern, not a compiler feature

MineTorch is a general ONNX → mcfunction compiler, so across the
ecosystem it sees unbounded shape variety (different embed dims, image
sizes, vocab sizes per model). The natural reaction is to make MCaml's
`arr[int, n]` length-polymorphic so one `dot` / `vec_add` / `matmul`
helper covers every shape. We are explicitly NOT doing that for v1.

Rationale:

- MineTorch is a host-side code generator, not human-written code. The
  source-duplication pain that would motivate length-polymorphism only
  exists for humans. Emitting `dot_768` next to `dot_1024` is one extra
  f-string in MineTorch's emitter; it doesn't care.
- Per-op cost is what matters for inference throughput. `IArrGet` on
  static arrays is ~1 cmd (literal storage path); `IHeapGet` on dyn
  arrays is ~5 cmds via macro dispatch. Matmul inner loops live or die
  on this. A length-polymorphic implementation that erases length at
  the type level still has to either (a) be a runtime handle (= dyn
  array, 5× cost) or (b) monomorphize per shape anyway, in which case
  Phase L is just ergonomic sugar over what the existing monomorphizer
  already does.
- Within any single ONNX file the unique shape count is bounded by the
  model architecture, not the workload. A big transformer is maybe
  20–100 unique shapes total. The MCaml monomorphizer producing one
  clone per shape per call site is fine on code size; compile time is
  a host-side cost paid once per model build.

The MineTorch v1 strategy is therefore: emit per-shape monomorphic
helpers from the ONNX walker; hot path (matmuls inside the layer-stack
loop) uses static `arr[int, n]`; cold path (one-shot embedding lookup,
final logit projection) MAY use `darr` if shape resolution is awkward,
trading 5× per-op cost for code-size savings on ops that run once per
token.

**Bisect trigger to revisit Phase L**: if monomorphizer profiling shows
the MCaml compile of a real ONNX-emitted .mcaml file taking >1s, OR if
a workload comes in that genuinely needs runtime length (variable
sequence length served from one compiled model), revisit. Until then,
Phase L stays in the "nice for human ergonomics, not on the critical
path" backlog.

### 13.10 Phase E decisions (HM inference + let-polymorphism)

Settled before the first E1/E2 edit, per the D5/D6 protocol. The seven
decisions from the §8.12 kickoff, in order:

**1. Unification representation — MinCaml-style destructive, scan-the-env
generalization.** `TVar of typ option ref` (`None` = unbound, `Some t` =
link) added to `Ast.typ`; `resolve` follows links with path compression;
`unify` binds after an occurs check. The persistent-substitution
alternative doubles the plumbing (every `infer` return threads a subst)
for zero benefit at this scale. Generalization finds free tvars by
scanning the typing env, not Rémy levels: the env at any `let` is the
local assoc list (params + enclosing lets, a handful of entries) plus
globals that are closed by construction (`global_vals`, `fun_sigs` from
annotations, ctor/record tables) — the O(n²) scan is over n ≈ 10.
Levels would thread a mutable int through every tvar for no measurable
win. Revisit only if typing time on a real program becomes visible.

**2. Schemes live in the ENV, not in `typ` — declared deviation from the
E1 task wording.** `typ` stays scheme-free; typing.ml gains a private
`scheme` (quantified tvar-ref list + body typ) and the inference env maps
name → scheme (trivial/mono schemes for lambdas-free binders).
Rationale: every existing `typ` consumer — Maranget matrices,
check_pattern, knormal, cfg_build, monomorphize's template keys, the
Region typ ref — stays ignorant of schemes; a `TScheme` inside `typ`
would force an impossible-case arm in each. `fun_sigs` is read only
inside typing.ml (verified by grep), so generalized function sigs live in
a parallel `fun_schemes` table without touching any public interface.
Public `Typing.infer : (string * typ) list -> expr -> typ` keeps its
signature (wraps monotypes into trivial schemes internally) so
for_lift's oracle call sites don't change shape.

**3. Value restriction — generalize syntactic values only.** A `let x =
e1` RHS generalizes iff e1 is a syntactic value: literal (Int/Float/
Bool/Unit), Var, Nil, Cons of values, Tuple/Record of values, ctor App
of values. Everything else — `ref e` above all, but also any real App,
BinOp, If, Deref — stays monomorphic (free tvars remain unbound and
unify with later uses). Top-level `fun` defs are always generalized
(after their own body is inferred — see decision 7). Pinned by an E8
probe: `let r = ref [] in` used at two element types must fail with a
unify error, not generalize.

**4. Scope of polymorphic TYPES — lift 'a list THIS phase; defer
parameterized user decls.** B2's monomorphic-int-list restriction is
lifted as its own task (new E4b in §2): `Nil : 'a list` (fresh tvar per
mention), `Cons : 'a -> 'a list -> 'a list`, `head/tail/is_nil` become
list-generic, PCons/PNil and the Maranget list column carry the
element type ([elem; TList elem] instead of [TInt; TList TInt]). This
is the D6 scope note coming due ("ctor-in-list patterns are Phase E's
job") and costs no runtime change — handles are ints regardless of
element type. Guardrail carried over from C5: the region-return walker
handles `TList TInt` only; codegen_cfg already fails loudly on
`TList <nested>` region returns (verified), and that stays the
behavior — deep-copying a list whose heads are objpool handles would
dangle them. The `list` TYPE ANNOTATION keyword keeps meaning
`TList TInt` (no `int list` postfix grammar this phase), so every
annotated program types exactly as today; polymorphic lists enter via
inference only. Parameterized USER decls (`type 'a option = None |
Some of 'a`) are DEFERRED to a follow-up task (noted under Phase G in
§2): they need decl syntax, a `'` lexer token (currently an illegal
character — needs its own conflict check), and arity-checked TAdt
application — none of which E8's first-order test battery requires.

**5. Residual-tvar defaulting — default to TInt at the knormal
boundary.** After a def's body is inferred (and its sig generalized),
main.ml zonks the def: every typ reachable from params/return is
resolved; still-unbound tvars are BOUND to TInt before
compile_def_to_cfg runs. §13.1 uniform representation makes any
concrete choice runtime-sound (every value is one scoreboard int);
TInt matches the existing App-fallback culture. So `fun f(x) = 0`
compiles with `x : int`, exactly as if annotated. Same rule applies
at the two other places a tvar could otherwise escape typing:
arithmetic BinOps whose operands are both unconstrained (unify with
TInt eagerly — `fun f(x, y) = x + y` gives ints, OCaml-compatible),
and for_lift's oracle (decision under E5 below). "Cannot infer"
rejection was considered and dropped: it punishes exactly the
programs the App-fallback has always accepted.

**6. Annotation semantics — optional but CHECKED.** Parser: `param :=
ID | ID COLON typ`, return `COLON typ` optional (omitted → the parser
mints `TVar (ref None)` in place — no new AST shape, no option types).
An annotation present is a unification constraint: params seed the env
with the annotated type; the declared return unifies with the inferred
body type. NOTE this last part is a deliberate STRENGTHENING: today the
return annotation is decorative (only feeds fun_sigs for callers; the
body's type is never compared against it — see for_lift's comment).
Under E4 a wrong return annotation becomes a type error. The full
battery gates this: if any pre-existing script fails the new check,
that's a finding to surface, not to special-case (per §8.12's stop
rule). Zero new menhir conflicts is a hard gate; lexer untouched (no
tick token needed this phase, per decision 4).

**7. Recursion — monotype self-calls, source-order generalization.**
While f's body is being inferred, `fun_schemes` has no entry for f, so
self-calls fall through to `fun_sigs`' raw monotype (shared tvar refs)
— no polymorphic recursion, standard HM. Generalization happens once,
immediately after f's def is inferred. Forward calls (caller earlier in
source than callee) keep working — build_sigs registers every sig
upfront, sharing the same tvar refs — but a forward call unifies
against the callee's not-yet-generalized MONOTYPE, so a function used
polymorphically at several types must be declared before those uses
(annotated/monomorphic forward calls, the only kind that exist in
current programs, are unaffected). Mutual recursion stays out (G1).

**E5 corollary (for_lift oracle).** for_lift's `walk` runs before
build_sigs populates fun_sigs, so its `Typing.infer` oracle calls
already run in degraded mode (every App → TInt fallback) and that
stays. Under HM the oracle may now return types containing unbound
tvars (e.g. `let l = [] in for ...`); when the walk materializes a
synthesized helper's param list from the env, it zonks each fv type
and defaults residual tvars to TInt (decision 5's rule, applied
early). TArrDyn/TRef fvs are concrete in the env and keep their
existing handling (dyn_env seeding / param filtering). main.ml keeps
SKIPPING full typing for `__for` helpers; speculative walk-time
unifications cannot leak into the real pass because the walk's tvars
are minted fresh per oracle call and the AST carries no types — the
one shared mutable (the Region typ ref) is unreachable inside for
bodies because region-in-helper is already rejected at main.ml
(C3 public-entry check).

**Amendment (discovered in E2): tvars range over single-int types
only.** Uniform representation (§13.1) covers scalars and handles, but
NOT `TArrDyn` (a base+len vreg PAIR), `TArrStatic`/`TMat` (compile-time
storage and the monomorphize template trigger), `TRef` (global slot,
second-class), or `TUnit`/`TSelector`/`TPos`. If a tvar could bind to
those, a generalized `fun pair_up(x) = (x, 0)` applied to a darr would
type-check and then silently drop the length vreg at the KAdtAlloc.
`unify`'s bind case therefore rejects those types with "cannot infer a
polymorphic type for a &lt;kind&gt; value … annotate the parameter
explicitly". Consequence: darr/static-array/matrix/ref params keep
requiring explicit annotations (exactly as they do today — `darr`, `arr
[int, n]`, `ref int` keywords), and the three representability checkers
(ctor fields, record fields, tuple elements) can soundly accept an
unbound tvar, which is what keeps E8's tuple-polymorphic swap typeable
without a representability hole.

**Match analysis under tvars (D3 preservation).** check_pattern becomes
unification-based (a PInt column unifies the scrutinee type with TInt,
PCons with TList elem, etc. — same error strings). The Maranget
matrices run AFTER all of a match's patterns are checked, on the
RESOLVED scrutinee type, so column types are as concrete as the program
makes them. A still-unbound tvar column can only carry wild/var
patterns (anything stronger would have constrained it), which the
existing catch-all column arm already handles — witnesses therefore
never contain tvars, and no '_weak1' can print. Diagnostics gain a
`string_of_typ` that renders unbound tvars as 'a/'b for unify-fail
messages (E8 quality checks); every PRE-EXISTING error string is
preserved byte-for-byte by catching `Unify_fail` at each legacy call
site and re-raising the legacy message.

### 13.11 G4 decisions (parameterized user type declarations)

Settled before the first edit, per the D5/D6 protocol, from a full-file
map of typing.ml's ADT machinery (adt_decls/ctor_info/unify/occurs/
free_tvars/copy_with/zonk_default/string_of_typ/check_pattern/useful),
a lexer/parser grammar audit, and an exhaustive `TAdt`-occurrence sweep
of every other module. The six decisions from the §8.14 kickoff, in
order:

**1. AST representation — widen `TAdt of string` to `TAdt of string *
typ list`.** Confirmed by direct sweep: outside typing.ml/ast.ml,
`TAdt` appears in exactly two places — `codegen_cfg.ml:291` (the C5
region-return walker's "not supported in v1" `failwith` arm, where the
name is only interpolated into a diagnostic string) and
`parser.mly:184`/`parser.ml:2197` (the construction site, upstream of
typing.ml). Every other pass (`knormal.ml`, `tco.ml`, `cfg_build.ml`,
`cfg.ml`, `monomorphize.ml`, `inline.ml`, every optimizer pass,
`regalloc_cfg.ml`, `codegen_cfg.ml`'s other arms, `codegen_helpers.ml`,
`codegen.ml`, `alpha.ml`, `for_lift.ml`) has zero `TAdt` occurrences —
dispatch is entirely by ctor tag (from `ctor_info`) or field count,
never by inspecting the type's name or args. So the blast radius is:
one mechanical `TAdt name -> TAdt (name, _)` edit in codegen_cfg.ml,
real grammar work in parser.mly (decision 4), and the full
typing.ml rewrite (decision 6). Inside typing.ml, 22 non-comment code
sites reference `TAdt` today; every one becomes a `TAdt (n, args)` or
`TAdt (n, _)` arm. Five of them — `occurs:119`, `tvar_bindable:134`,
`zonk_default:201`, `copy_with:225`, `free_tvars:244` — currently read
`TAdt _` as a payload wildcard that *already compiles* against the
widened type without edits (OCaml's `_` swallows the new tuple field
too), which means the exhaustiveness checker will NOT force fixing
them. They must be found by grep (`grep -n "TAdt _" typing.ml`) and
edited deliberately: `occurs`/`free_tvars`/`copy_with`/`zonk_default`
need a real `TAdt (_, args) -> List.exists/fold_left/map (recurse)
args` arm (mirroring the existing `TTuple ts` arms) instead of the
no-op catch-all, or a generalized function's args silently stop
scanning for free tvars / stop getting zonked. `tvar_bindable` stays a
true wildcard (`TAdt _ -> None` — always representable, args
irrelevant, since every instantiation is one handle per §13.1).

**2. Decl-side type variables — dedicated `TParam of string`, NOT a
reused `TVar ref`.** `'a` in `Some of 'a` is a binder scoped to its
own decl, not a unification variable — destructively binding a shared
`TVar ref` across every use of `Some` would corrupt the decl for every
other call site. `TParam` is legal only where a substitution pass
(below) is guaranteed to eliminate it before the value reaches `unify`;
`unify` gets an explicit arm `TParam _, _ | _, TParam _ -> raise
(Error "internal: unsubstituted type parameter reached unification —
this is a compiler bug")` immediately before the catch-all
`Unify_fail`, so a substitution bug fails loudly with a distinct
message instead of a confusing generic mismatch. `tvar_bindable` and
the three representability checkers (`check_field_type`,
`check_record_field_type`, `check_tuple_elem`) accept `TParam _`
unconditionally where legal (single-int amendment guarantees
soundness) and reject it via the new arity/scope checker (decision 6)
everywhere it is NOT legal.

`adt_decls`' value widens from `constructor list` to `string list *
constructor list` (params in declared order, `[]` for today's
non-parameterized decls) — no new parallel table, per the kickoff's
own framing. `register_type_decl` registers the (params, ctors) pair
BEFORE the field-validation loop (unchanged D3 self-reference
ordering), so a self-referential application (`type 'a tree = Leaf |
Node of 'a * 'a tree`) resolves `tree`'s own arity while validating its
own fields.

**3. Lexer — `TYVAR of string`, zero collisions found.** Audited every
use of `'` in lexer.mll: string-literal rules key on `"` exclusively,
`cmd!` is a bare keyword match, selector's `[^ ']']` is a bracket-close
char literal not an apostrophe, and FLOAT/DOT don't reference `'` at
all. The character is simply unhandled today (falls to the `_`
catch-all raising `SyntaxError`), and ocamllex's longest-match
semantics mean a new rule wins regardless of where it's declared. New
rule: `let tyvar = '\'' ['a'-'z' 'A'-'Z' '0'-'9' '_']*` (reusing ID's
own continuation class verbatim) plus `| tyvar { TYVAR (Lexing.lexeme
lexbuf) }` beside the `id` arm; `%token <string> TYVAR` beside `ID`/
`STRING`/`SELECTOR` in parser.mly. The token payload keeps the leading
quote (`"'a"`); parser actions strip it (`String.sub tv 1 (String.length
tv - 1)`) when building `TParam`/the decl's param-name list, so stored
names are bare (`"a"`) and comparisons (`List.mem p allowed_params`)
stay consistent.

**4. Type application surface syntax — left-recursive postfix on
`typ_atom`, single param only, `list` joins it.** `typ_atom` gains two
new left-recursive arms: `t = typ_atom; name = ID { TAdt (name, [t]) }`
(user-type application) and `t = typ_atom; T_LIST { TList t }` (closes
the E4b annotation gap — decision 5, folded in here since it's the
same grammar shape), alongside the existing bare arms (`name = ID {
TAdt (name, []) }`, `T_LIST { TList TInt }` for back-compat) and a new
terminal arm `v = TYVAR { TParam (strip v) }`. Because `ctor_typs` and
`star_typ_list`/`typ` both bottom out in `typ_atom` already (confirmed
by grammar audit — `ctor_typs: typ_atom (TIMES typ_atom)*`, `typ :=
star_typ_list := typ_atom (TIMES typ_atom)*`), this single grammar
change covers ctor fields (`Some of 'a`, `Box of 'a option`), record
fields, tuple elements (`(int * int) option` via the existing `LPAREN
typ RPAREN` atom), and fun signatures for free — no separate arm
needed per position. Nesting (`int option option`) and parenthesized
compound args (`(int * int) option`) fall out of the same left
recursion with zero extra grammar. The type DECL's own AST widens:
`TypeDecl of string * constructor list` -> `TypeDecl of string *
string list * constructor list` (param names in decl order, `[]` for
non-parameterized decls); LHS grammar gains `TYPE tv = TYVAR name = ID
EQUAL opt_bar ctors = ctor_list { TypeDecl (name, [strip tv], ctors)
}` beside the existing 0-param production. v1 scope: **single param
only** — `('a, 'b) either`-style multi-param decls and multi-arg
application (`(int, bool) t`) are OUT OF SCOPE, deferred as a
mechanical follow-up (G4b). One consequence worth naming: because each
postfix step contributes at most one argument, there is no v1-legal
syntax for "supplying 2 args to a 1-ary type" (true N-ary
over-application needs the deferred multi-arg surface) — the
over-application exit-test probe is realized instead as supplying an
argument to an ARITY-0 type (e.g. `int color` where `color` has no
declared params), which the decision-6 arity checker rejects the same
way. Zero-new-menhir-conflicts is verified at implementation time (two
new left-recursive `typ_atom` arms distinguished from the existing
TIMES-recursion by trailing token — ID/T_LIST vs TIMES — should
LALR(1)-disambiguate on one token of lookahead, but this is confirmed
by actually running menhir, not assumed).

**5. `list` joins the postfix grammar now; parameterized records are
deferred.** Folded into decision 4 above: `T_LIST`'s existing hardwire
to `TList TInt` stays for the bare keyword (back-compat — every
existing `list`-annotated program keeps meaning `int list`), and the
new postfix arm makes `float list`/`bool list`/`t list` writable,
closing the E4b probe gap where `shape list` was unparseable.
Parameterized RECORD decls (`type 'a cell = { v : 'a }`) are
explicitly DEFERRED — `register_record_decl`'s field-validation loop
calls the decision-6 arity/scope checker with an EMPTY allowed-param
set, so any `'a` mentioned in a record field type is rejected with the
same "type variable not allowed here" message as any other non-decl
context. This is sufficient for the D8 nil-story target
(`type node = { v : int; next : node option }` needs `option` to be
generic, not `node` — `node` itself stays a monomorphic record, which
already works once ADT application lands).

**6. Typing mechanics.**
- **Arity + scope validation**: new recursive `check_typ_ok
  (allowed_params : string list) (t : typ) : unit`. `TAdt (name,
  args)` arm: existing unknown-name check (unchanged message), then
  arity = `match Hashtbl.find_opt adt_decls name with Some (ps, _) ->
  List.length ps | None -> 0` (covers records and the not-found case,
  which the unknown-name check already rejected), `List.length args <>
  arity` raises `"type %s expects %d type argument(s), got %d"`
  (mirrors the existing ctor-arity message at :1135-1137), then
  recurses `check_typ_ok` into each arg. `TParam p` arm: `List.mem p
  allowed_params` else raise `"unbound type variable '%s"`. Every
  other constructor (`TList`/`TArrDyn`/`TRef`/`TArrStatic`/`TMat`/
  `TTuple`) recurses into its wrapped type(s); scalars/`TVar` are a
  no-op. Call sites: `register_type_decl`'s field loop passes THIS
  decl's own param names as `allowed_params` (so self-application and
  the decl's own `'a` both validate); `register_record_decl`'s field
  loop and `build_sigs`'s per-param/return-type calls (typing.ml:938)
  both pass `[]`. This is a genuinely NEW validation axis (arity was
  structurally impossible to get wrong before TAdt carried args), so
  unlike the mechanical `TAdt` pattern-arm churn, OCaml's exhaustiveness
  checker cannot find missing call sites — audit every place a
  parser-produced `typ` enters the system (ctor fields, record fields,
  fun params/return; tuple/ctor-application-inferred types are
  excluded, since those are built FROM already-validated types and
  can't smuggle in a bad arity) and confirm via the exit-test
  rejection probes, not via compiler errors.
- **Ctor APPLICATION** (`Some(e)`, and the bare-nullary-ctor `Var`
  case): new `instantiate_ctor (owner : string) (fields : typ list) :
  typ list * typ list` — `let (params, _) = Hashtbl.find adt_decls
  owner in let fresh = List.map (fun _ -> TVar (ref None)) params in
  (List.map (subst_typarams (List.combine params fresh)) fields,
  fresh)`. Both call sites (`infer`'s ctor-`App` arm :1132-1141 and the
  nullary-ctor `Var` arm :966-972) replace the raw `fields`/bare `TAdt
  adt` with the substituted fields / `TAdt (adt, fresh)`, mirroring
  E4b's `Cons`/`Nil` fresh-tvar-then-unify shape exactly (E4b is the
  precedent: `Nil -> TList (fresh_tvar ())`, generalized here from
  TList's one hardcoded slot to N user-declared params).
- **Ctor PATTERN** (`PCtor`, check_pattern:553-579): mint-and-unify
  when the scrutinee is an unresolved `TVar` (same fresh-tvar
  instantiation as above, then `unify scrutinee (TAdt (adt, fresh))`),
  or reuse-in-place when the scrutinee already resolves to `TAdt (name,
  args)` with `name = adt` (`List.combine params args` directly, no
  minting — this is the scrutinee's ALREADY-KNOWN instantiation).
  Either way, `fields` gets substituted before the existing
  `List.map2 check_pattern fields ps` recursion, so `Some(x)` against
  an `int option` scrutinee binds `x : int`, not the generic `'a`.
- **`subst_typarams`**: new function, `(string * typ) list -> typ ->
  typ`, structurally mirroring `copy_with`'s recursion shape (scalars/
  `TVar` unchanged, `TList`/`TTuple`/etc. recurse) but keyed by string
  NAME (`List.assoc`) rather than `TVar option ref` physical identity
  — a genuinely separate function from `copy_with`, not a variant of
  it, because the two substitution axes (scheme qvars vs. decl
  params) are unrelated. `TAdt (n, args) -> TAdt (n, List.map (subst
  mapping) args)` — decl params can appear nested inside another
  applied type (`Box of 'a option`).
- **Maranget** (`useful`): the `PCtor` arm (:710-719) and the
  `PWild|PVar`/`TAdt` branch (:827-850) both currently thread
  `ctor_info`'s raw, unsubstituted `fields` straight through — same
  gap E4b closed for `TList` by binding `elem` right at the `TList
  elem ->` match arm and threading it into `specialize_nil`/
  `specialize_cons`. Here: the column's type `ty` is already resolved
  to `TAdt (name, args)`; build `List.combine (fst (Hashtbl.find
  adt_decls name)) args` and `subst_typarams` it into `fields` before
  passing to `specialize_ctor`/the recursive `useful` call, so
  witnesses stay concrete (`Some(_)` against `int option`, never
  `Some('a)`). The complete-signature test (:829-831) is UNCHANGED —
  it keys on ctor NAMES from `adt_decls`, and a type's constructor set
  doesn't change with instantiation args.
- **Records stay monomorphic** (decision 5): every record
  construction/pattern/field-access site keeps building `TAdt (owner,
  [])` — a literal empty list, never inferred — so D7/D8's existing
  zero-tag-read dispatch guarantees are untouched by construction.

Behaviors pinned unchanged: every §13.10/§13.5 decision, zero
monomorphization of user types (a generalized function using `'a
option` compiles once — no per-instantiation clones, verified by the
same zero-clones grep E8's harness already runs), tags stay
decl-order-per-type, D5's decision-tree shapes, one global ctor/field
namespace, D3's decl-before-use ordering, and every pre-existing error
message byte-for-byte (arity/unbound-tyvar errors are NEW messages,
not replacements).

### 13.12 Phase F decisions (first-class lambdas)

Settled before the first F1 edit, per the D5/D6/G4 protocol, from a
full sweep of every exhaustive-match function over `typ` in
`typing.ml`, a read of `ast.ml`'s current `typ`/`expr`/`def`, the
`fun_sigs`/`fun_schemes` population and `App` lookup path, `main.ml`'s
Inline/Monomorphize ordering, `cost.ml`'s `ICall` pricing, and a direct
check of `codegen_cfg.ml`'s region-return dispatch (line-cited below).
The five decisions from the §8.13 kickoff, in order. Baseline
verified clean before this work started: rebuild per CLAUDE.md, suite
66/66+async, Phase D 40/40, Phase E 42/42+12 rejection probes, five
canaries byte-identical (hash + `diff -rq` both confirm, matching
`canary_hashes_e8_final.txt` exactly), all nine `/tmp` harnesses green
including `test_param_types` (survived from G4, no reconstruction
needed).

**1. Arrow types — `TFun of typ list * typ`, n-ary uncurried, NO partial
application in v1 (amends the F1 task line).** Every function/closure
call in this language is already fully-applied n-ary with zero
currying precedent — `App of string * expr list` and `Fun of string *
(string * typ) list * typ * expr` (`ast.ml:48-84`) both take a fixed
arg list, never a partial one. Introducing partial application would
require an arity-tracking currying runtime (each partial application
minting a NEW closure capturing the args-so-far) with no existing
machinery to build on — a scope explosion the phase's 3–4-session
budget doesn't include. Deferred as a mechanical G-follow-up (G5?) if
ever needed, same posture as G4's deferred multi-param type decls.
`tvar_bindable` (`typing.ml:141-154`) gets a `TFun _ -> None` arm
(bindable, joining `TInt | TFloat | TBool | TList _ | TTuple _ | TAdt _
| TVar _`) — a closure handle is one scoreboard int, which is exactly
what makes `map : ('a -> 'b) -> 'a list -> 'b list` typeable and is
what the kickoff's own decision-1 wording requires.

Every one of the 12 functions the kickoff named needs a `TFun` arm,
confirmed exhaustive (no catch-all `_` arm exists in any of them
today) by direct read: `occurs`, `tvar_bindable`, `unify`,
`zonk_default`, `copy_with`, `free_tvars`, `string_of_typ`,
`check_typ_ok`, `subst_typarams` all get a RECURSING arm — `TFun (ps,
r) -> List.exists/List.map/fold (recurse) ps` folded with `recurse r`
(mirrors the existing `TTuple ts -> List.iter/exists/map ... ts`
shape at, e.g., `typing.ml:124` (`occurs`), `typing.ml:219`
(`zonk_default`), `typing.ml:241` (`copy_with`), `typing.ml:289`
(`free_tvars`)). `unify`'s arm is structural and arity-checked,
inserted before the catch-all at `typing.ml:196`:
```
| TFun (p1, r1), TFun (p2, r2) when List.length p1 = List.length p2 ->
    List.iter2 unify p1 p2; unify r1 r2
```
`check_field_type` / `check_record_field_type` / `check_tuple_elem`
(`typing.ml:404-449`, `:483-518`, `:697-728`) get a REJECTING arm
instead — ties to decision 2 below — with a message parallel to the
existing `TArrDyn`/`TRef` rejections: "closures cannot be stored as an
ADT/tuple/record field in v1 — pass as a function argument, let-bind
it, or return it instead." `string_of_typ` (`typing.ml:99-119`) renders
`TFun ([t], r)` as `t -> string_of_typ r` (no parens, arity 1) and
`TFun (ts, r)` as `"(" ^ String.concat ", " (List.map string_of_typ ts)
^ ") -> " ^ string_of_typ r` for arity ≥ 2 — mirrors the existing
`TAdt (n, [a])` vs `TAdt (n, args)` rendering split at
`typing.ml:114-117`.

**Region-return path needs ZERO new code — verified, not assumed.**
`codegen_cfg.ml:262-310`'s `IRegionExit` dispatch on `ret_typ` ends in
an untyped catch-all `| _ -> failwith (Printf.sprintf "codegen_cfg:
region return type %s has no v1 walker" (match ret_typ with ... | _ ->
"<unknown>"))` (lines 300–310) — BOTH the outer match and the inner
diagnostic-string match already have their own `_` catch-all (line
310: `| _ -> "<unknown>"`), so neither is exhaustive over `typ` and
neither is forced to grow a `TFun` arm by the compiler. A closure
escaping via region-return therefore already fails loudly today with
"region return type <unknown> has no v1 walker" the moment `TFun`
exists — functionally correct, zero new code, and satisfies the §13
escalation guardrail (no §3 decision bends). Optional cosmetic-only
follow-up: add `Ast.TFun _ -> "TFun"` to the inner match for a clearer
message — not required for correctness.

**2. v1 lambda placement scope — first-class everywhere EXCEPT stored
in a Tuple/Record/ADT-ctor field; escaping defined over call-graph +
ref/return flow only.** Lambdas are usable as a direct call argument,
let-bound, returned from a function (HOF factories), and stored in a
`ref` — the smallest scope where F5's apply-dispatch runtime isn't
dead code: if lambdas were literal-argument-only, every lambda would
be statically visible at its unique call site and F3 would classify
100% of them `Known`, making F5 (a required task) unreachable.

OUT OF SCOPE for v1: storing a lambda inside a `Tuple`/`Record` literal
or an ADT constructor application field — REJECTED at typing via
decision 1's `check_field_type`/`check_record_field_type`/
`check_tuple_elem` arms, same posture as the existing `TArrDyn`/`TRef`
rejections there. Rationale: (a) §13.6 already prices "closures stored
in data structures" as an accepted, out-of-scope loss for MCaml's
target workloads; (b) allowing it would force the C5 region deep-copy
walker — which handles only `TList TInt` today and already fails
loudly for `TAdt`/`TArrDyn`/`TTuple` region returns (verified above)
— to reason about closures nested inside arbitrarily-matched data, a
walker-extension question this phase doesn't need to open; (c) it
keeps "escaping" a pure call-graph/ref/return-flow question over
scalars, never a recursive structural-data question, which is what
keeps F3's classifier tractable in one phase.

F3's `Known`/`Escaping` boundary, concretely: a lambda is `Known` iff
every use of its value resolves, at whole-program `fn_table` time
(post-inline), to a directly-dispatchable call site — called
immediately (through zero or more let/param aliases, but NOT through a
`ref`-read or across a function-return boundary) as that one `Lambda`
literal, or passed to a HOF parameter that is itself, transitively,
only ever called (never stored/returned/`ref`'d/re-passed-past-budget)
within that HOF. `Escaping via <reason>` the instant ANY use is:
stored into a `ref`, returned as a function's result, passed to a
parameter the callee doesn't call directly, or re-passed onward past
another HOF whose `MCAML_SPECIALIZE_LIMIT` has been exceeded (decision
3's fallback). Attempting to store one in a Tuple/Record/ADT field is
caught at typing, before F3 ever runs — not an F3 concern at all.

**3. fun_sigs/fun_schemes need no new table; F4 folds into Monomorphize,
not a new re-entrant phase.** `TFun` is just another `typ`, so a HOF's
`(string * typ) list` param list carries `TFun (ps, r)` through the
EXISTING `fun_sigs`/`fun_schemes`/`generalize`/`instantiate` machinery
untouched — `fun_sigs : (string, typ list * typ) Hashtbl.t`
(`typing.ml:11`) and `build_sigs`/`type_fun_def` (`typing.ml:1067-1081`,
`:1594-1602`) already store/process arbitrary `typ`, with zero
per-shape special-casing to remove.

This amends the F3 task line's "between inline and monomorphize"
framing: F3 (escape analysis) IS the new standalone whole-`fn_table`
pass sitting between `Inline.run` and `Monomorphize.run`
(`main.ml:212-219`, confirmed strictly sequential over the same
`fn_table : (string, Cfg.cfg_func) Hashtbl.t`) — it needs the same
post-inline whole-program visibility the inliner itself needs. F4 (the
actual specialization) is NOT a separate phase; it's an EXTENSION of
Monomorphize's existing per-argument-shape clone key, extended to also
key on "closure identity of a `Known`-classified `TFun` argument" as
an additional specialization axis alongside its existing array-shape
key. Clones re-enter `fn_table`/`fn_order` through the exact mechanism
Monomorphize already uses for array clones (`main.ml:216-226`) — zero
new plumbing in `main.ml`. `MCAML_SPECIALIZE_LIMIT=K` reuses
Monomorphize's existing per-source-function clone-count bookkeeping as
the SAME counter Known-lambda clones increment; the one genuinely NEW
code path is the fallback beyond K — arrays have no apply-dispatch
escape hatch, so "give up cloning and route through F5's apply-dispatch
instead" is new logic Monomorphize doesn't need today.

**4. Closure tag value — reserve tag `-2`.** Cells are `{tag: -2, code,
env_0, env_1, ...}`. Every user-declared tag (ADT ctors, cons cells
(tag 1), tuples/records (tag 0)) is assigned via `List.iteri` over
decl order (`typing.ml:465`, confirmed by direct read) and is therefore
always `>= 0` by construction — ANY negative tag is structurally
impossible for a user-declared type, so `-2` cannot collide with any
current or future decl, by construction rather than by convention.
`-2` rather than `-1` is chosen purely so a raw NBT/cell dump during
debugging doesn't visually conflate the closure tag field with the
pre-existing, UNRELATED `-1` list-nil SENTINEL HANDLE value (§4.2) — a
different field in a different context (a bare handle meaning "no
cell" vs. a tag field inside an always-present cell) but adjacent
enough in a hex/int dump to cause confusion during a manual debugging
session. No dispatch code ever reads this tag at runtime: like every
other objpool cell, dispatch is driven entirely by STATIC type
knowledge (a value's `TFun` type is known at every call site from
typing), matching D4/D5's existing "tags are NOT globally unique... a
tag is only interpreted under the scrutinee's static type" — the tag
field exists purely for `{tag, ...fields}` cell-shape uniformity and
future dump readability, never for a runtime branch.

**5. tick_guard/tick_split interaction — new `IApply` op, priced by a
whole-program worst-case constant; `MCAML_STRICT_HOT` fires in
`optimize.ml`, not typing.** New IR op `IApply of vreg option * vreg *
vreg list` (dest, closure-handle vreg, arg vregs) in `cfg.ml`, lowered
via a fixed `mcaml:apply` macro-dispatch helper (F5) that reads the
`code` field and jumps to the resolved function. Only `Escaping`
lambdas ever lower to `IApply`; `Known` lambdas' call sites become
ordinary `ICall`s against F4's specialized clone.

`cost.ml`'s `estimate` (`cost.ml:36`, `ICall` priced at `cost.ml:45-47`)
gets an `IApply` arm priced as `4 + 2 * K_max_captured`, where
`K_max_captured` is a SINGLE whole-program constant (not per-call-site)
— computed once, after F3's whole-program escape analysis has
enumerated every `Escaping` closure shape, as the maximum
captured-variable count across all of them. This is an EXACT
worst-case bound, not a heuristic: because escape analysis is
whole-program/closed-world (the same reason `Inline.run` and
`Monomorphize.run` are whole-table passes), every closure shape that
could ever reach ANY apply-dispatch call site is statically
enumerable, even though which specific shape reaches a given site at
runtime isn't. This mirrors `cost.ml`'s own documented posture
(`cost.ml:29-32`) of pricing the worst realistic lowering rather than
modeling per-call-site specifics exactly.

`MCAML_STRICT_HOT` fires at the CFG/optimize level (`main.ml` Phase 3 /
`optimize.ml`), NOT in `typing.ml`. Grounding: `typing.ml` runs per-def
before `knormal`/`cfg_build` even exist and has zero notion of loop
structure; "hot loop" can only be evaluated once `dominators`/
`loop_detect` have run for a function (already wired per-function
inside `optimize.ml`'s M4 loop pass, confirmed by the module layout in
CLAUDE.md) AND once F3's classification is available. Concretely: F3
tags each `IApply` site (or the `ICall` it would have been) with its
escape reason; a new F6 check runs per-function during Phase 3, after
that function's `loop_detect` result is available, and raises a
compile error if `MCAML_STRICT_HOT=1` and any `IApply` sits inside a
detected natural loop OR inside a TCO'd self-tail loop body (the common
case in this codebase). Threading F3's per-call-site reason data
through to this per-function Phase 3 check (a side table keyed by
function+block+instruction-index vs. embedding the reason string
directly in `IApply`) is left as an F3/F6 implementation choice, not
decided here.

**6. Closure lowering boundary (session 3's own prerequisite decision,
not one of the original five — surfaced by the session-3 kickoff, not
assumed away).** knormal must lower `Closure` construction and closure
application UNIFORMLY, before F3 has run: F3 needs whole-`fn_table`
(post-inline) visibility to classify Known vs Escaping, but knormal
runs per-function in Phase 1, long before Inline.run or F3 exist for
that program. So knormal cannot special-case on the classification at
lowering time — it has to emit ONE shape that works for both outcomes,
and F3+F4 rewrite away the Known instances afterward.

Investigated first, per the kickoff's own instruction, whether Known
closures could avoid a real IR-level representation entirely by
mirroring the EXISTING `"#arr:<aid>"` array pseudo-arg (a compile-time-
only token riding in an `ICall`'s arg-string position, never a real
runtime value). Rejected: the array pseudo-arg works because static
arrays are NEVER first-class runtime values in this language at all —
no vreg ever holds "the array", only element reads/writes reference a
compile-time storage id — so a syntactic, per-call-site, single-
function-scope substitution at knormal time is always sufficient
(confirmed by reading knormal.ml's `bind_args`, `knormal.ml:823-829`).
Closures are different by construction (§13.12 decision 2 explicitly
requires let-binding, returning, and ref-storing a lambda to work) —
a real runtime int handle is required from the very first lowering,
because whether a given construction turns out Known or Escaping is a
WHOLE-PROGRAM, post-inline question that knormal (per-function,
pre-inline) cannot answer yet. A syntactic pseudo-arg trick therefore
cannot decide "no real value" soon enough; the uniform representation
has to be a genuine value-producing op.

Concretely: `IClosureMake of vreg * string * vreg list` (dest, lambda
helper name, captured vregs) and `IApply of vreg option * vreg * vreg
list` (dest, closure vreg, args) in `cfg.ml`, decision 5's `IApply`
finally minted. The one load-bearing follow-on choice: **is
`IClosureMake` side-effecting (never DCE'd, mirroring `IAdtAlloc`/
`ICons`'s "allocation is itself an observable event" treatment) or not
(mirroring `IBinOp`/`ICopy`)?** Marking it side-effecting would have
been the "safe by analogy" choice, but verified against `dce.ml`
directly (`is_side_effecting`) that doing so would silently defeat
§13.6's "Known lambdas cost zero at runtime" claim: if `IClosureMake`
can never be dropped even when its result becomes unread, a Known
closure's cell allocation survives to codegen regardless of how
aggressively F4 specializes away its consumer, because nothing would
ever be allowed to remove it. Chose NOT side-effecting instead —
correct because, unlike `IAdtAlloc`'s cell (whose allocation event is
part of the language's user-visible allocation semantics, coupled to
the region-truncation byte count), `IClosureMake` commits to no runtime
representation at all at this IR level: it is a pure value descriptor
until F5's codegen decides how a SURVIVING instance actually gets
lowered. A construction whose result is genuinely never read is dead
code, full stop — ordinary liveness-based DCE already gets this right
for every other non-side-effecting op, and doing the same here is what
makes F4's rewrite (`IApply` → `ICall`, dropping the last use of the
originating `IClosureMake`) turn into REAL zero-cost specialization
via the very next M3a fixed point, with no bespoke removal logic
needed in `closure_spec.ml` itself. `IApply` IS marked side-effecting
(mirrors `ICall`: calling through an unresolved value may run arbitrary
code regardless of whether its result is read).

This is the one place this session's implementation directly overrode
a first (wrong) instinct after building it and testing against
`dce.ml`'s actual mechanics rather than assuming the `IAdtAlloc`
analogy carried over unchanged — recorded here because a future session
touching `IClosureMake`'s codegen lowering (F5) needs to know this
non-side-effecting choice is why LEFTOVER-Escaping instances (that
DID survive to codegen) are exactly the ones F5 must give a real
lowering to, and why nothing upstream of codegen may ever start
treating `IClosureMake` as side-effecting without re-opening this
tradeoff.

Behaviors that MUST survive (restated from §8.13, now grounded): every
§13.10/§13.11 decision including the tvar single-int amendment; zero
clones for value-polymorphic non-lambda functions (lambda
specialization clones are new and expected); the §4.4 public-entry
contract and every §4.1 reserved slot; ICons/IHead/ITail budgets; the
D5 decision-tree shapes; the region-walker domain staying `TList TInt`
only (now doubly confirmed — `TFun` automatically falls into the same
already-existing catch-all, no new rejection arm needed); `for_lift`'s
oracle degraded mode and the two-pass `main.ml` driver (type+
generalize, then zonk+compile) — closure conversion slots between
Inline and Monomorphize (decision 3), not inside typing.

## 13. Escalation triggers

If any of these happen during a task, stop and flag to the user rather
than working around them:

- An existing test (`test_all.mcaml`, `primitives_v1.mcaml`,
  `demo_classifier.mcaml`, or any scripts/ test that predates this plan)
  changes its output or command count.
- SROA or LICM stops firing on a static array program that previously used
  them. Verify with `MCAML_DUMP_CFG=1`.
- A load-bearing design decision from §3 turns out to be wrong or
  impossible for a concrete reason.
- The task touches a file not listed in §6 and you can't explain why.
- You need to add a new reserved scoreboard slot not listed in §4.1.
- Command count for `ICons`, `IHead`, or `ITail` exceeds the §5 budget.
