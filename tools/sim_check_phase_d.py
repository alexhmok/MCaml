#!/usr/bin/env python3
"""Pre-flight verifier for scripts/mc_test_suite_phase_d.mcaml.

Runs the compiled Phase D suite through sim/sim.py and asserts that
all 40 synchronous checks pass, plus the §4.4 post-conditions: run_all_d
is a public entry, so the compiler-inserted arena reset must leave
$objpool_next at 0 and the objpool cells list empty after it returns.
Run after any compiler change, BEFORE re-packaging the in-game pack:

    ./mcaml -o build_phase_d < scripts/mc_test_suite_phase_d.mcaml
    python3 tools/sim_check_phase_d.py build_phase_d

Also greps the emitted files for the Phase D zero-cost dispatch
guarantees (single-ctor matches read no tag; wildcard fields read no
obj_f slot) so an optimizer regression that silently reintroduces
reads fails here, not in-game.
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402

EXPECTED_CHECKS = 40

# file -> substrings that must NOT appear (zero-tag single-ctor
# dispatch + used-fields filter)
GREP_FORBIDDEN = {
    "d19_tuple_roundtrip.mcfunction": ["obj_tag"],
    "d21_destructuring_let.mcfunction": ["obj_tag"],
    "d25_tuple_wildcard.mcfunction": ["obj_tag", "obj_f0"],
    "d30_record_pattern.mcfunction": ["obj_tag"],
    "d31_record_omit_fields.mcfunction": ["obj_tag", "obj_f0"],
    "d03_single_ctor.mcfunction": ["obj_tag"],
}


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_phase_d"
    sim.DIR = os.path.abspath(build_dir)

    w = sim.World()
    w.storage["mcaml:objpool"] = {"cells": []}
    w.storage["mcaml:scratch"] = {"cells": []}
    w.storage["mcaml:permheap"] = {"cells": []}
    w.storage["mcaml:region_tmp"] = {"objpool": [], "scratch": []}
    for s in ("$objpool_next", "$scratch_next", "$permheap_next"):
        w.scores[s] = 0

    sim.run_function(w, "run_all_d")

    ok = True
    for line in w.say:
        print(f"  [say] {line}")
    p, f = w.scores.get("$pass", 0), w.scores.get("$fail", 0)
    if p != EXPECTED_CHECKS or f != 0:
        print(f"FAIL: run_all_d pass={p} fail={f} "
              f"(want pass={EXPECTED_CHECKS} fail=0)")
        ok = False
    else:
        print(f"OK: run_all_d pass={p} fail={f}")

    pool_next = w.scores.get("$objpool_next")
    cells = w.storage["mcaml:objpool"]["cells"]
    if pool_next != 0 or cells != []:
        print(f"FAIL: §4.4 arena reset did not fire — "
              f"$objpool_next={pool_next}, cells={len(cells)}")
        ok = False
    else:
        print("OK: §4.4 arena reset ($objpool_next=0, cells empty)")

    for fname, needles in GREP_FORBIDDEN.items():
        with open(os.path.join(sim.DIR, fname)) as fh:
            body = fh.read()
        bad = [n for n in needles if n in body]
        if bad:
            print(f"FAIL: grep {fname}: forbidden {bad} present")
            ok = False
        else:
            print(f"OK: grep {fname}: none of {needles}")

    print("PHASE D SUITE PASSED" if ok else "PHASE D SUITE FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
