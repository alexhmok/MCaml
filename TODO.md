# MCaml TODO

Cross-cutting issues that don't belong in a single module's docstring.
Things that are urgent or in-flight live in a plan doc instead
(`DYNMEM_PLAN.md` is the current example).

## PARTIALLY RESOLVED 2026-07-11: dead `val` elimination at the global-init level

Landed (`src/deadval.ml`, wired between Phase 2 and Phase 3 in
main.ml, `MCAML_NO_DEADVAL=1` / `MCAML_O0` to disable):
- a `val` referenced by NO non-template function is dropped from the
  `__globals_init` synthesis (post-monomorphize walk, so clones'
  concrete aids count as references);
- a referenced `val` with no surviving dynamic-index read loses its
  `__g_<name>_get` macro file, which `ensure_macro_helper` over-emits
  for static reads and literals (static gets read storage directly).
Unit-covered in `test/test_deadval.ml`; canary diff was exactly three
dropped static-only `_get` files across the suites, zero
`__globals_init` changes, all checkers pass.

**Still open — the MineTorch LUT case.** The original pain
(`lib/math.mcaml` concatenated for one or two helpers bakes ~1024 LUT
entries into `__globals_init`) is NOT fixed by this pass, and cannot
be by any val-only pass: MCaml has no dead-function elimination and no
entry-point declaration, so every compiled function — including the
never-called LUT helpers — is chat-invocable and its val references
must stay initialized (dropping them would make `/function
mcaml:sigmoid_f` silently read empty storage). The TODO sketch's "walk
from the program's entry points" presupposed an entry-point set that
doesn't exist; `compute_entry_info`'s "public = called by no one"
definition makes every uncalled library helper a root, so
entry-rooted reachability degenerates to "referenced by anyone".
Follow-up that would close it: an explicit entry list (e.g.
`MCAML_ENTRIES=f,g` or a `pub fun` marker) rooting a dead-FUNCTION
pass, with dead-val elimination then running on the surviving table.

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

## RESOLVED 2026-07-11: stale `$tick_iters` carried across invocations of a guarded loop

Latent multi-run bug noted during the graph-viz session. tick_guard's
counter reset only fired on the yield path; a natural loop exit left
the counter holding its accumulated value, so the NEXT invocation of
the same guarded loop in the same session — a re-run of the entry
point, or an inner guarded loop re-entered by an enclosing loop —
started with a stale budget and could yield mid-run even though the
run itself fits comfortably under the limit, leaving any synchronous
reader of `$ret` with a partial result.

Reproduced in sim before fixing (`scripts/multirun_guard.mcaml` +
`tools/sim_check_multirun.py`, now the 7th verify_canary suite): two
back-to-back runs each using ~75% of the budget; run 2 returned run
1's stale `$ret`. Fix: `Tick_guard.reset_cmd` — one
`scoreboard players set $tick_iters_<target> vars 0` appended by
main.ml at the tail of the guarded entry file, pre-tick_split (same
pattern as the §4.4 heap reset). Iterations leave the file early via
`return run` and yields via `return 0`, so the trailing reset runs
exactly once, in the frame that takes the natural exit. Deliberate
trade-off: the budget is per-invocation — consecutive invocations in
one tick no longer share accounting, which is what the per-loop
counter design promised anyway. Canary: every guarded entry file
gained exactly this one trailing line (74 lines across the 6 suites,
zero other changes); all sim checkers pass.

---

(Add new entries above this line.)
