#!/usr/bin/env python3
"""Pre-flight verifier for scripts/stress_test.mcaml.

Two layers:

1. Runs the compiled stress suite's `run_stress` through sim/sim.py
   and asserts all 7 synchronous integration checks pass.

2. Drives S8 (`stress_loop`) across simulated ticks the same way
   tools/sim_check_suite.py drives async_sum: seed param_0/param_1,
   invoke once, then re-invoke `stress_loop` (there is no separate
   wrapper/body split for this function — see the S8 comment in
   stress_test.mcaml for why that matters) until $stress_done flips,
   emulating `schedule ... 1t` re-entry. param_N and the darr handle
   this function threads through its own self-tail back-edge live in
   the scoreboard/storage, so state survives between re-entries
   exactly as it does across real ticks.

Every expected constant below is recomputed independently in Python
(not just copy-pasted from the .mcaml source) so a hardcoded value
that is wrong in BOTH places can't silently agree with itself.

Run after any compiler change, BEFORE re-packaging the in-game pack:

    cat lib/math.mcaml scripts/stress_test.mcaml | ./mcaml -o build_stress
    python3 tools/sim_check_stress.py build_stress
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402

EXPECTED_CHECKS = 7


def expected_s7():
    def fib(n):
        return n if n < 2 else fib(n - 1) + fib(n - 2)

    def deep_sum(n):
        return 0 if n == 0 else n + deep_sum(n - 1)

    def sum_to_tco(n):
        return n * (n + 1) // 2

    return fib(18) + deep_sum(3000) + sum_to_tco(800)


def expected_s8(n=5000):
    arr = [0] * 20
    total = 0
    h = 0
    arrbonus = 0
    callbonus = 0
    for i in range(1, n + 1):
        if i % 7 == 0:
            arr[i % 20] = i
        total += i
        h = (h * 31 + i) % 1000003
        if i % 11 == 0:
            arrbonus += arr[i % 20]
        if i % 13 == 0:
            callbonus += i * 2
    return total + h + arrbonus + callbonus


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_stress"
    sim.DIR = os.path.abspath(build_dir)
    # deep_sum(3000) alone burns several sim.py stack frames per mcaml
    # call depth, so the effective Python recursion depth is a large
    # multiple of 3000.
    sys.setrecursionlimit(200000)

    ok = True

    # --- oracle sanity: hardcoded constants in stress_test.mcaml must
    # match an independent Python recomputation before we even ask sim
    # what the compiler produced. ---
    s7 = expected_s7()
    s8 = expected_s8()
    if s7 != 4824484:
        print(f"FAIL: expected_s7() = {s7}, stress_test.mcaml hardcodes 4824484")
        ok = False
    if s8 != 16392449:
        print(f"FAIL: expected_s8() = {s8}, stress_test.mcaml hardcodes 16392449")
        ok = False

    # --- synchronous suite ---
    w = sim.World()
    sim.run_function(w, "__globals_init")
    sim.run_function(w, "run_stress")
    for line in w.say:
        print(f"  [say] {line}")
    p, f = w.scores.get("$pass", 0), w.scores.get("$fail", 0)
    if p != EXPECTED_CHECKS or f != 0:
        print(f"FAIL: run_stress pass={p} fail={f} (want pass={EXPECTED_CHECKS} fail=0)")
        ok = False
    else:
        print(f"OK: run_stress pass={p} fail={f}")

    # --- S8: cross-tick darr-through-TCO loop ---
    w2 = sim.World()
    sim.run_function(w2, "__globals_init")
    w2.scores["param_0"] = 1
    w2.scores["param_1"] = 5000
    w2.scores["param_2"] = 0
    w2.scores["param_3"] = 0
    w2.scores["param_4"] = 0
    w2.scores["param_5"] = 0
    w2.scores["param_6"] = 0
    ticks = 0
    while w2.scores.get("$stress_done", 0) != 1:
        ticks += 1
        if ticks > 1000:
            print("FAIL: stress_loop never completed within 1000 simulated ticks")
            return 1
        sim.run_function(w2, "stress_loop")
    for line in w2.say:
        print(f"  [say] {line}")
    ret = w2.scores.get("$ret", 0)
    if ret != s8 or ticks < 2:
        print(f"FAIL: S8 ret={ret} (want {s8}), resumed ticks={ticks}")
        ok = False
    elif not any("PASS" in s for s in w2.say):
        print("FAIL: S8 finished but did not self-report PASS")
        ok = False
    else:
        print(f"OK: S8 ret={ret} after {ticks} simulated ticks")

    print("STRESS SUITE " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
