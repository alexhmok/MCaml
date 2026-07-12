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

## RESOLVED 2026-07-11: TCO'd loop exit branches re-executed once per stacked frame

Fixed by 21bc459 (2026-07-08): every `TTail` dispatch is emitted as
`return run function mcaml:<self>`, which terminates the caller frame
atomically at the dispatch line — stacked frames can never fall
through into the guard-wrapped exit commands on unwind, regardless of
where those commands sit in the file. The old fix sketch here (reorder
block emission so the self-`TTail` block is last) is moot: with
`return run`, emission order is irrelevant to the unwind path.

Proven 2026-07-11: `async_sum`'s gated-`say` workaround was removed
and its exit branch made deliberately non-idempotent (ungated `say`s
plus a `$async_exit_runs` counter); `sim_check_suite.py` asserts the
exit branch runs exactly once. Teeth check: reverting the dispatch to
a bare `function` line makes the checker fail with the PASS say fired
40× (once per stacked frame), reproducing the original report.
Unit-level pin: `test/test_codegen_cfg.ml` asserts a self-`TTail`
lowers to a `return run function mcaml:<self>` line.

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
