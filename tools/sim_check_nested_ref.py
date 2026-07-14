#!/usr/bin/env python3
"""Nested-ref regression check for scripts/tests/test_nested_ref.mcaml.

Pins the for_lift nested-ref ordering fix (Knormal.seed_ref_env): a ref
bound inside an outer for body is dereferenced/assigned from a nested
inner for. Before the fix this SHAPE failed to compile ("not a
ref-bound variable"), so reaching the sim at all is most of the test;
the $ret checks pin the lowering end-to-end.

    ./mcaml -o build_nestedref < scripts/tests/test_nested_ref.mcaml
    python3 tools/sim_check_nested_ref.py build_nestedref
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402


def run(w: "sim.World", name: str) -> int:
    sim.run_function(w, name)
    return w.scores.get("$ret", 0)


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_nestedref"
    sim.DIR = os.path.abspath(build_dir)

    # (entry, expected): nested_sum = 3 outer iters x (0+1+2) = 9;
    # deep_sum = 2 outer iters x (1 + 2*2 increments) = 10.
    checks = [("nested_sum", 9), ("deep_sum", 10)]

    ok = True
    for name, want in checks:
        w = sim.World()
        got = run(w, name)
        if got != want:
            print(f"FAIL: {name} ret={got} (want {want})")
            ok = False
        else:
            print(f"OK: {name} = {got}")
    print("NESTED_REF " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
