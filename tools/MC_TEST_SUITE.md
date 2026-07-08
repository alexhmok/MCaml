# MCaml in-game test suite

Full-functionality acceptance test for the MCaml compiler, run inside
real Minecraft (Java Edition, 1.21.x). The suite is self-checking: every
check bumps `$pass` or `$fail` on the `vars` objective and prints a
`[FAIL] <test name>` chat line on failure. Passing checks stay silent.

Source: `scripts/mc_test_suite.mcaml` (66 synchronous checks + 1
cross-tick async check). Companion sim gate: `tools/sim_check_suite.py`.

## 1. Build and package

```sh
cd /Users/alexmok/MCaml
cat lib/math.mcaml scripts/mc_test_suite.mcaml | ./mcaml -o build_suite
python3 tools/sim_check_suite.py build_suite        # must print SUITE PASSED
python3 tools/pack_datapack.py --input build_suite \
    --name mcaml_test_suite --output dist/mcaml_test_suite.zip
```

Never skip the sim gate: if the sim run fails, the datapack will fail
in game the same way and you'll waste a world reload cycle.

## 2. Install

1. Drop `dist/mcaml_test_suite.zip` into `<world>/datapacks/`.
2. In game: `/reload`. This runs the synthesized `mcaml:init`
   (registers the `vars` objective) and `__globals_init` (seeds the
   global LUT arrays) via the `#minecraft:load` tag.
3. Sanity check: `/scoreboard objectives list` should show `vars`, and
   `/data get storage mcaml:heap __g_gvlut` should show
   `[10, 20, 30, 40, 50]`. If the storage is missing, `__globals_init`
   didn't run — re-`/reload` before testing anything else.

## 3. Run the synchronous suite

```
/function mcaml:run_all
```

Expected chat output (about one second, all within a single tick):

```
[MCaml suite] running 66 checks...
[MCaml suite] pass=66 fail=0 (expected pass=66 fail=0)
[MCaml suite] ALL 66 CHECKS PASSED
```

Any failure prints `[FAIL] <name>` between those lines, and the tally
line shows the counts. You can re-run `run_all` as often as you like;
it resets `$pass`/`$fail` on entry. Individual tests can also be run
directly, e.g. `/function mcaml:t16_fib_nontail` (then check that
`$pass` incremented via `/scoreboard players get $pass vars`).

### Coverage map

| Checks | Feature area |
|---|---|
| t01–t09 | int arithmetic: precedence, negative results, `/`, `%` (floor semantics), large `*` |
| t04/t05, t07/t08 | **parity pairs**: negative `/` and `%`, folded vs runtime (see §5) |
| t10–t11 | comparisons (`= != < > <= >=`), `&&`, `\|\|` |
| t12–t14 | nested `if`, `let` shadowing, `;` sequencing |
| t15–t18 | call chains, non-tail recursion (fib + frame stack), TCO, zero-arg calls |
| t19–t22 | `for` loops (incl. nested and zero-iteration), `ref`/`!`/`:=` |
| t23–t31 | static arrays: literals, static/dynamic get and set (macro helpers), read-modify-write, dynamic-element literals, float arrays, matrices (static + dynamic index) |
| t32–t33 | array parameters + monomorphization (two distinct clone pairs) |
| t34–t35 | dynamic arrays: `array_make`/`array_get`/`array_set`, cross-function passing |
| t36–t40 | cons lists: `::`, `[]`, `head`, `tail`, `is_nil`, TCO list sum, list returned from helper |
| t41–t43 | global `val` arrays: static index, dynamic index via macro getter, float LUT |
| t44–t53 | Q16.16 fixed point: `+ - fmul fdiv neg_f`, lossy pre-shift, conversions, comparisons, TCO float accumulation |
| t54–t59 | math library: `relu_f`, `sigmoid_fixed`, `tanh_fixed`, `gelu_fixed`, `exp_fixed`, `log_fixed` (tolerance-band checks) |
| t60 | pipe operator `\|>` |
| t61–t62 | **parity pairs**: `fmul`/`fdiv` on negative operands, folded vs runtime |
| r01–r04 | regions: primitive return, list copy-out walker, nested, sequential (inline in `run_all` — regions are public-entry-only in v1) |

The harness itself exercises `cmd!`, string escapes, `execute`
composition, and the `$ret` synchronous-call convention on every check.

## 4. Run the async tick_guard test

```
/function mcaml:async_start
```

This starts `sum(1..60000)` in a TCO'd loop that the tick guard slices
across game ticks (roughly 2,700 iterations per tick under the default
60,000-command budget — about 22 ticks / 1 second total). Expected:

```
[MCaml async] starting sum(1..60000); yields across ticks...
[MCaml async] PASS: sum(1..60000) = 1800030000 across ticks
```

To prove it really spans ticks, run
`/scoreboard players get $async_done vars` immediately after starting —
you should catch it at `0`, flipping to `1` when the PASS line appears.
The final result also stays readable in `$ret`
(`/scoreboard players get $ret vars` → `1800030000`) because nothing
runs after the loop's natural exit.

For a slower, more visible demonstration, rebuild with a uniform
per-tick iteration cap: `MCAML_LOOP_ITER_LIMIT=500 ./mcaml -o …`
(~6 seconds).

## 5. Division semantics and the parity pairs

MCaml's integer `/` and `%` (and the divisions inside the Q16.16
`fmul`/`fdiv` lowerings) are **floor** semantics: floorDiv rounds
toward negative infinity and floorMod takes the divisor's sign, so
`-7 / 2 = -4` and `-7 % 3 = 2`. This matches vanilla `scoreboard
players operation /=` and `%=`, measured in-game 2026-07-07 on 1.21.x
(an earlier trunc assumption failed exactly these checks).
`const_fold.ml` and `sim.py` implement the same floor semantics.

Four pairs guard this by construction:

- `t04_div_neg_folded` / `t07_mod_neg_folded` are constant-folded at
  compile time — they pin the **folder's** answers, baked into the
  mcfunction.
- `t05_div_neg_runtime` / `t08_mod_neg_runtime` route the same
  operands through a dynamic array so the scoreboard operator
  actually executes at runtime.
- `t61_fmul_neg_parity` / `t62_fdiv_neg_parity` do the same for the
  fixed-point multiply/divide lowerings, whose internal pre-shift and
  scale-up divisions also floor.

If any member of a pair fails, the folded and runtime code paths have
diverged (or vanilla changed semantics) — record which check failed
and the observed value; it's a real compiler bug.

Note this differs from OCaml's truncating `/` and `mod`: MCaml source
follows the runtime it targets, not its host language.

## 6. Troubleshooting

- **Every global test fails (t41–t43, math t54–t59)** — `__globals_init`
  didn't run. `/reload`, verify with
  `/data get storage mcaml:heap __g_gvlut`.
- **`Expected whitespace to end one argument` on `/function`** — a
  function file failed to load; check the server log for the file name.
  Compile-time name validation should prevent this for user names.
- **Nothing happens at all** — check `/datapack list` shows the pack
  enabled, and that no other datapack claims the `mcaml` namespace
  (only one MCaml-compiled pack can be loaded at a time).
- **`run_all` tally shows fewer than 66 checks ran** — the suite died
  mid-run (a command chain aborted). Check the server log; run the
  individual `tNN_*` functions to bisect.
- **PASS line prints many times for the async test** — should not
  happen (the say is gated on `$async_done`); if it does, the gate
  ordering in `async_sum.mcfunction` was disturbed. See the
  exit-branch re-execution note in `scripts/mc_test_suite.mcaml`.

## 7. What this suite cannot cover in game

- `sel` / `pos` typed literals — they type-check but no operation
  consumes them yet, so there is nothing observable to assert.
- `tick_split` (Phase 4) — requires a >50k-command straight-line
  function; not practical to hand-author. Covered by sim tests only.
- Type-error rejection (`scripts/test_fail.mcaml`) — compile-time only;
  verify on the host with `./mcaml < scripts/test_fail.mcaml`, which
  prints `Type Error: …` and emits no files. Note the process still
  exits 0 (see TODO.md), so check the output, not the exit code.
- Optimization A/B parity (`MCAML_NO_INLINE/LICM/SR/UNROLL/SROA`) —
  host-side: rebuild with each toggle, re-run `tools/sim_check_suite.py`
  (all 64 checks must still pass with any pass disabled).
