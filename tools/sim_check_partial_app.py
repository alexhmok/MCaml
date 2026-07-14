#!/usr/bin/env python3
"""Partial-application check for scripts/tests/test_partial_app.mcaml.

Pins the Partial_app desugar end-to-end: local partial application
(specializes), argument position, factory return (apply-dispatch),
multiple remaining params, zero-supplied eta-expansion, and the
evaluate-once guarantee (eval_once = 2 means the supplied argument's
side effect ran once at binding time; 3 means it wrongly re-ran per
call of the resulting closure).

    ./mcaml -o build_partial_app < scripts/tests/test_partial_app.mcaml
    python3 tools/sim_check_partial_app.py build_partial_app
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_partial_app"
    sim.DIR = os.path.abspath(build_dir)

    checks = [
        ("local_pa", 15),
        ("arg_pa", 7),
        ("factory_pa", 7),
        ("multi_rest", 6),
        ("zero_supplied", 3),
        ("eval_once", 2),  # 3 = supplied arg re-evaluated per call
    ]

    ok = True
    for name, want in checks:
        w = sim.World()
        sim.run_function(w, "__globals_init")
        sim.run_function(w, name)
        got = w.scores.get("$ret", 0)
        if got != want:
            print(f"FAIL: {name} ret={got} (want {want})")
            ok = False
        else:
            print(f"OK: {name} = {got}")
    print("PARTIAL_APP " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
