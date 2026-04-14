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
| Cons cells | `storage mcaml:conspool pairs` | `$conspool_next` | compound `{h, t}` |

Cons cells use a compound layout (not flat ints) so `head`/`tail` are
field-addressed and cost 3 commands instead of 5. Dynamic arrays use flat
ints so contiguous `base + idx` addressing works. The two pools never share
storage.

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

- `$conspool_next` — bump counter for cons pool
- `$scratch_next` — bump counter for scratch pool
- `$permheap_next` — bump counter for permheap pool
- `$arr_idx` — carrier for pre-computed `base + idx` on dynamic array access
- `$region_save_0`, `$region_save_1`, ... — snapshot slots for region
  entries (one triple per nesting level; 4 levels of nesting is almost
  certainly enough for v1)

### 4.2 Nil sentinel

`nil : TList t` = the integer `-1` in any `TList`-typed vreg. A freshly
allocated cell's handle is always `>= 0`, so the sentinel is unambiguous.
`is_nil(l)` compiles to `scoreboard players get <l> vars` followed by
`execute if score … matches -1`.

### 4.3 Init sequence

`init.mcfunction` grows six new lines, added by `tools/pack_datapack.py`:

```
data modify storage mcaml:conspool pairs set value []
data modify storage mcaml:scratch cells set value []
data modify storage mcaml:permheap cells set value []
scoreboard players set $conspool_next vars 0
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
data modify storage mcaml:conspool pairs set value []
scoreboard players set $conspool_next vars 0
```

`permheap` is **not** reset — it persists across invocations by design.

**Public-entry primitive-return contract.** The reset block zeros the
scratch and conspool pools unconditionally. Any `TList` / `TArrDyn`
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
data modify storage mcaml:region_tmp conspool set value []
data modify storage mcaml:region_tmp scratch set value []
```

These are **storage paths**, not scoreboard slots — §12's escalation
trigger on "new reserved scoreboard slot not listed in §4.1" does not
apply. Permheap has no region_tmp counterpart because permheap is
never truncated.

The conspool region_tmp path is consumed by
`region_walker_list_stash.mcfunction` (appends) and
`region_walker_list_rebuild.mcfunction` (drains from the tail). The
scratch region_tmp path is reserved for the TArrDyn walker (not
implemented in v1; TArrDyn region returns fail loudly at codegen time
until a future session extends the walker set).

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
data modify storage mcaml:conspool pairs append value {h:0,t:0}
execute store result storage mcaml:conspool pairs[-1].h int 1 run scoreboard players get <h> vars
execute store result storage mcaml:conspool pairs[-1].t int 1 run scoreboard players get <t> vars
scoreboard players operation <d> vars = $conspool_next vars
scoreboard players add $conspool_next vars 1
```

### 5.2 `IHead(d, c)` — 3 commands

```
execute store result storage mcaml:tmp args.idx int 1 run scoreboard players get <c> vars
function mcaml:cons_head with storage mcaml:tmp args
scoreboard players operation <d> vars = $arr_result vars
```

Where `cons_head.mcfunction` is a single line:

```
$execute store result score $arr_result vars run data get storage mcaml:conspool pairs[$(idx)].h 1
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
scoreboard players operation $region_save_<k>_conspool vars = $conspool_next vars
```

Exit (small-return case, primitive return type):

```
(* scratch: restore counter and truncate list via data remove loop *)
(* repeated (old_next - saved_next) times: *)
data remove storage mcaml:scratch cells[-1]
scoreboard players operation $scratch_next vars = $region_save_<k>_scratch vars
(* same for conspool *)
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

## 9. Rollback and A/B flags

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
| pool | One of the three NBT lists: `scratch`, `permheap`, `conspool` |
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

## 12. Escalation triggers

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
