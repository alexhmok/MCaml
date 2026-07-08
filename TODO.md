# MCaml TODO

Cross-cutting issues that don't belong in a single module's docstring.
Things that are urgent or in-flight live in a plan doc instead
(`DYNMEM_PLAN.md` is the current example).

## Dead `val` elimination at the global-init level

**Severity:** wart, not a bug. Costs disk, not runtime correctness.

`main.ml` emits one `data modify storage mcaml:heap __g_<name> set value [...]`
command per top-level `val` declaration into `__globals_init.mcfunction`,
and one `<name>_get.mcfunction` macro getter per `val` if it's read with
a dynamic index anywhere. There is no dead-val elimination: every `val`
in the source survives to load-time, even if no compiled function reads
it.

This becomes painful when downstream consumers (notably MineTorch)
concatenate `lib/math.mcaml` in front of generated code to pick up one
or two helper functions like `relu_f` — the whole library's LUT vals
(`int_exp_lut`, `frac_exp_lut`, `log_frac_lut`, `sigmoid_lut`,
`tanh_lut`, `gelu_lut`, ~1024 entries combined) get baked into
`__globals_init` even when none of the LUT-using helpers are called.
Surfaced by `MineTorch/validation/test_matmul_stage2.py`: 35 KB of
generated source for 16 four-term dot products, the bulk of it
unreferenced LUTs.

**Fix sketch:** between Phase 2 (inline) and Phase 3 (per-fn optimize),
walk the live function table from the program's entry points and
collect the set of `val` names actually referenced. Drop unreferenced
`val` declarations from `main.ml`'s `globals` list before
`__globals_init` synthesis. Same pass can also drop the `__g_<name>_get`
macro file when no dynamic-index read survives. Cheap dataflow — just
a `Hashtbl.t` of names mentioned.

**Why it can wait:** load-time only, no runtime cost. The disk bloat
is annoying for hand inspection of generated code but doesn't impede
correctness or in-game performance.

---

## TCO'd loop exit branches re-execute once per stacked frame

**Severity:** correctness for non-idempotent exit effects; found while
building `scripts/mc_test_suite.mcaml`.

A self-recursive tail call lowers to a `function mcaml:<self>` line in
the middle of the file, with the loop's exit-branch commands emitted
AFTER it (guard-wrapped on the branch cond vreg). When the innermost
frame takes the exit branch, the cond slot flips globally, and every
enclosing frame — thousands, up to the tick_guard iteration limit —
re-executes the now-true exit commands as the call stack unwinds. Pure
scoreboard writes are idempotent (they recompute the same values from
the same global slots), so `$ret`-style exits are unaffected; but a
`cmd!` (chat spam observed: one `say` per frame), a cons allocation, a
`array_make`, or any `add`-style command in exit position runs once
per frame. Reproduces in sim.py; see the gated `say` workaround in
`mc_test_suite.mcaml`'s `async_sum`.

**Fix sketch:** in `codegen_cfg.ml`, order block emission so the block
containing the self-`TTail` is the last commands in the file (the exit
branch runs before the recurse line; whichever branch is not taken is
a guard-skipped no-op, and nothing remains to re-run after unwind).

## Compiler exits 0 on type errors

`main.ml`'s top-level handler prints `Type Error: …` to stderr and
emits no files, but never calls `exit 1`. Scripted builds (MineTorch,
CI, `&&` chains) cannot detect the failure from the exit status. Same
applies to the other `| Exception -> eprintf` arms. One-line fix per
arm.

## RESOLVED 2026-07-07: `/` and `%` are floor semantics (vanilla-measured)

In-game runs of `mc_test_suite.mcaml` t05/t08 on 1.21.x measured
vanilla `/=` as floorDiv (`-7 / 2 = -4`) and `%=` as floorMod
(`-7 % 3 = 2`), refuting the earlier trunc assumption (which had been
back-inferred from sim.py, not from vanilla). Floor was adopted as
MCaml's defined semantics: `const_fold.ml` now folds Div/Mod — and
the divisions inside the FMult pre-shift and FDiv scale-up — with
`floor_div`/`floor_mod`, and sim.py's `/=`/`%=` handlers floor. Suite
checks t04/t05, t07/t08, t61/t62 pin fold/runtime parity permanently.

Still open from this investigation:
- `const_fold.ml` folds `Mult`/`Add`/`Sub` with OCaml 63-bit ints and
  no int32 overflow guard (`FMult`/`FDiv` have one), so overflowing
  constant arithmetic diverges from the runtime's 32-bit wrap.
- **MineTorch re-audit needed:** `int8_ref.py` was aligned to the old
  trunc sim (`_trunc_div`, Stage 11 LayerNorm). Now that sim.py
  floors, host validation will surface the divergence — switch the
  call sites that model MCaml ops to floor and re-run the stage
  suites.

---

(Add new entries above this line.)
