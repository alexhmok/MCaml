#!/usr/bin/env python3
"""Pre-flight verifier for scripts/tests/mc_test_suite.mcaml.

Runs the compiled suite through sim/sim.py and asserts that all 64
synchronous checks pass and that the async tick_guard loop completes
with the right sum when re-driven tick by tick. Run this after any
compiler change, BEFORE re-packaging the in-game datapack:

    cat lib/math.mcaml scripts/tests/mc_test_suite.mcaml | ./mcaml -o build_suite
    python3 tools/sim_check_suite.py build_suite
"""
import sys
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402

EXPECTED_CHECKS = 66
ASYNC_EXPECT = 1_800_030_000


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_suite"
    sim.DIR = os.path.abspath(build_dir)

    # --- synchronous suite ---
    w = sim.World()
    sim.run_function(w, "__globals_init")
    sim.run_function(w, "run_all")

    ok = True
    for line in w.say:
        print(f"  [say] {line}")
    p, f = w.scores.get("$pass", 0), w.scores.get("$fail", 0)
    if p != EXPECTED_CHECKS or f != 0:
        print(f"FAIL: run_all pass={p} fail={f} (want pass={EXPECTED_CHECKS} fail=0)")
        ok = False
    else:
        print(f"OK: run_all pass={p} fail={f}")

    # --- async tick_guard loop ---
    # sim treats `schedule` as a no-op, so emulate the tick scheduler by
    # re-entering async_sum until $async_done flips. param_N and the
    # per-loop $tick_iters_* counter live in the scoreboard, so state
    # survives between re-entries exactly as it does across real ticks.
    w2 = sim.World()
    sim.run_function(w2, "__globals_init")
    sim.run_function(w2, "async_start")
    ticks = 0
    while w2.scores.get("$async_done", 0) != 1:
        ticks += 1
        if ticks > 1000:
            print("FAIL: async_sum never completed within 1000 simulated ticks")
            return 1
        sim.run_function(w2, "async_sum")
    for line in w2.say:
        print(f"  [say] {line}")
    ret = w2.scores.get("$ret", 0)
    # The exit branch is deliberately non-idempotent: before the TTail
    # `return run` fix (21bc459, 2026-07-08), every stacked frame re-ran
    # the exit commands on unwind, so the say fired once per frame and
    # $async_exit_runs counted the frame depth instead of 1.
    pass_says = sum(1 for s in w2.say if "PASS" in s)
    exit_runs = w2.scores.get("$async_exit_runs", 0)
    if ret != ASYNC_EXPECT or ticks < 1:
        print(f"FAIL: async ret={ret} (want {ASYNC_EXPECT}), resumed ticks={ticks}")
        ok = False
    elif pass_says != 1:
        print(f"FAIL: async PASS say fired {pass_says} times (want exactly 1: "
              "exit branch re-executed per stacked frame?)")
        ok = False
    elif exit_runs != 1:
        print(f"FAIL: async exit branch ran {exit_runs} times (want exactly 1)")
        ok = False
    else:
        print(f"OK: async_sum ret={ret} after {ticks} resumed ticks, "
              "exit branch ran once")

    print("SUITE " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
