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

## RESOLVED 2026-07-11: compiler exits nonzero on all error classes

The Lexer/Typing/Parser handler arms had already gained `exit 2` in
commit 9e40441 (2026-07-08) — this entry was stale. Remaining gap
closed 2026-07-11: `failwith`-raised pipeline errors (reserved names,
v1-unsupported shapes, codegen invariant violations) exited 2 only via
OCaml's uncaught-exception path, printing a `Fatal error: exception
Failure(...)` backtrace line; a `| Failure m` arm now prints the bare
message and exits 2 like the others. `tools/verify_canary.py` now
pins the contract permanently: four deliberately broken programs (one
per error class) must each yield nonzero exit AND zero emitted
`.mcfunction` files.

## RESOLVED 2026-07-07: `/` and `%` are floor semantics (vanilla-measured)

In-game runs of `mc_test_suite.mcaml` t05/t08 on 1.21.x measured
vanilla `/=` as floorDiv (`-7 / 2 = -4`) and `%=` as floorMod
(`-7 % 3 = 2`), refuting the earlier trunc assumption (which had been
back-inferred from sim.py, not from vanilla). Floor was adopted as
MCaml's defined semantics: `const_fold.ml` now folds Div/Mod — and
the divisions inside the FMult pre-shift and FDiv scale-up — with
`floor_div`/`floor_mod`, and sim.py's `/=`/`%=` handlers floor. Suite
checks t04/t05, t07/t08, t61/t62 pin fold/runtime parity permanently.

RESOLVED 2026-07-11 (int32 overflow divergence): `const_fold.ml` now
wraps every arithmetic fold result to int32 via `wrap32`
(`Add`/`Sub`/`Mult`/`FAdd`/`FSub`, the `FMult`/`FDiv` internal multiply
steps, and `Div`'s single `MIN_INT / -1` floorDiv overflow case).
**Semantics decision: fold WITH the int32 wrap, not refuse-to-fold** —
scoreboard values are Java 32-bit ints and `+= -= *=` wrap two's-
complement (and `Math.floorDiv(MIN_INT, -1)` returns `MIN_INT`), so
wrapping is exactly what vanilla computes; it is deterministic, keeps
the fold profitable, and the old FMult/FDiv decline-on-overflow guards
were replaced by the same wrap. Inferred from Java int semantics of
the vanilla scoreboard implementation; flagged for in-game spot-check
alongside the next MANUAL_TEST run. `sim.py` wraps identically in its
`+= -= *= /=` / `add`/`remove` handlers so it stays a faithful oracle.
Pinned by `test/test_const_fold.ml` wrap suites (fold path) and an
opt-vs-O0 sim parity check (2000000000+2000000000 → -294967296 both
ways). No canary hash moved (no suite folds overflowing constants).

Still open from this investigation:
- **MineTorch re-audit needed:** `int8_ref.py` was aligned to the old
  trunc sim (`_trunc_div`, Stage 11 LayerNorm). Now that sim.py
  floors, host validation will surface the divergence — switch the
  call sites that model MCaml ops to floor and re-run the stage
  suites.

---

(Add new entries above this line.)
