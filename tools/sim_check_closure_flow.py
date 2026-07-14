#!/usr/bin/env python3
"""Decision-8 follow-up check for scripts/tests/test_closure_flow.mcaml.

Pins the closure-flow shapes knormal rejected before the §13.12
decision-8 follow-up (factory-return-then-call, ref-then-call, aliases)
plus the soundness case: a ref overwritten from a for-lifted helper
must NOT be specialized to its initializer lambda — overwrite_in_loop
returning 11 instead of 20 means closure_spec resolved through a
$ref_ slot it cannot see all writers of.

    ./mcaml -o build_closure_flow < scripts/tests/test_closure_flow.mcaml
    python3 tools/sim_check_closure_flow.py build_closure_flow
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_closure_flow"
    sim.DIR = os.path.abspath(build_dir)

    checks = [
        ("factory_leaf", 15),
        ("factory_dispatch", 21),
        ("ref_call", 5),
        ("overwrite_in_loop", 20),  # 11 = unsound ref specialization
        ("alias_call", 16),
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
    print("CLOSURE_FLOW " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
