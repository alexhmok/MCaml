#!/usr/bin/env python3
"""Regression check for scripts/tests/regression_optimizer_closures.mcaml.

Pins the four 2026-07-14 bug-hunt fixes end-to-end: unroll trip-count
resolution from the per-call-site prefix, strength-reduce multi-def
poisoning (plus a still-fires pin via $ref_sr presence), lambda-
captured refs, and lambda-captured factory/partial-app closures.

    ./mcaml -o build_regr < scripts/tests/regression_optimizer_closures.mcaml
    python3 tools/sim_check_regression.py build_regr
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_regr"
    sim.DIR = os.path.abspath(build_dir)

    checks = [
        ("unroll_stale", 50613),      # 16-iteration over-unroll gave 1583482597
        ("sr_ifmerge_mul", -297),     # carrier rewrite of if-merge gave -17
        ("sr_ifmerge_add", -5),       # gave -11
        ("sr_legit", 38),
        ("lambda_ref_loop", 10),      # was: Undefined variable r_N
        ("lambda_ref_shared", 17),
        ("factory_capture", 17),      # was: closure capture type mismatch
        ("pa_capture", 16),
    ]

    ok = True
    for name, want in checks:
        w = sim.World()
        sim.run_function(w, name)
        got = w.scores.get("$ret", 0)
        if got != want:
            print(f"FAIL: {name} ret={got} (want {want})")
            ok = False
        else:
            print(f"OK: {name} = {got}")

    # sr_legit must still be strength-reduced, not just correct: the
    # carrier lives in a $ref_sr_* slot in the emitted commands.
    fired = False
    for fn in os.listdir(build_dir):
        if fn.startswith("sr_legit_inner") and fn.endswith(".mcfunction"):
            with open(os.path.join(build_dir, fn)) as f:
                if "$ref_sr_" in f.read():
                    fired = True
    if fired:
        print("OK: sr_legit carrier present ($ref_sr_*)")
    else:
        print("FAIL: no $ref_sr_* slot in sr_legit_inner files — "
              "strength reduction no longer fires")
        ok = False

    # unroll_stale must actually unroll (3 multiplies, no self-tail),
    # pinning the decline-to-fire flip as well as the trip count.
    body = ""
    for fn in os.listdir(build_dir):
        if fn.startswith("unroll_stale__for") and fn.endswith(".mcfunction"):
            with open(os.path.join(build_dir, fn)) as f:
                body += f.read()
    mults = body.count("*=")
    if mults == 3:
        print("OK: unroll_stale unrolled to 3 multiplies")
    else:
        print(f"FAIL: unroll_stale has {mults} '*=' (want exactly 3)")
        ok = False

    print("REGRESSION " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
