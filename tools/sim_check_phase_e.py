#!/usr/bin/env python3
"""Pre-flight verifier for scripts/tests/mc_test_suite_phase_e.mcaml.

Three layers, mirroring (and extending) tools/sim_check_phase_d.py:

1. Runs the compiled Phase E suite through sim/sim.py and asserts all
   42 synchronous checks pass, plus the §4.4 post-conditions
   ($objpool_next = 0, objpool cells empty after run_all_e returns).

2. Greps the emitted files for the Phase E zero-cost guarantees:
   polymorphic functions compile ONCE (no per-type clones of
   id/swap/pair/len/app — §13.1 uniform representation), the E7
   template path still clones per aid pair (dotp3__arr* files exist),
   and the D5/D7/D8 dispatch guarantees survive inference (tuple/
   record matches read no obj_tag; wildcard components read no obj_f1).

3. Runs the compile-time REJECTION probes that cannot live in the
   suite because it must compile: value restriction, checked-annotation
   mismatch, occurs check, both-types unify diagnostics, the tvar
   single-int restriction (§13.10 amendment), the OCaml-style int/float
   operator split (plain `+`/`-`/`*`/`/`/`%` reject float operands;
   `+.`/`-.`/`*.`/`/.` reject int operands), exhaustiveness/redundancy
   under inferred scrutinees, and the decision-7 poly-use-before-decl
   rule.

Run after any compiler change, BEFORE re-packaging the in-game pack:

    ./mcaml -o build_phase_e < scripts/tests/mc_test_suite_phase_e.mcaml
    python3 tools/sim_check_phase_e.py build_phase_e
"""
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402

EXPECTED_CHECKS = 42

# Polymorphic helpers that must compile exactly once: any file that
# starts with the name but is not the function itself or one of its
# call-frame helpers (<name>_callN) is an unexpected clone.
NO_CLONES = ["id", "swap", "pair", "fst_p", "len", "app", "last_or"]

# E7 positive check: the template path must still specialize.
TEMPLATE_CLONE_PREFIX = "dotp3__arr"

# file -> substrings that must NOT appear (zero-tag single-ctor
# dispatch + used-fields filter, now under INFERRED types)
GREP_FORBIDDEN = {
    "sum2.mcfunction": ["obj_tag"],          # tuple destructure
    "norm1.mcfunction": ["obj_tag"],         # record pattern
    "fst_p.mcfunction": ["obj_tag", "obj_f1"],  # wildcard component
}

# (name, inline source, must-appear error substring)
REJECTS = [
    ("value_restriction",
     "fun main() = let r = ref [] in "
     "(r := (1 :: [])); (r := (true :: [])); 0\n",
     "ref := value type mismatch"),
    ("return_annotation_mismatch",
     "fun f(x: int) : bool = x + 1\n",
     "declared return type bool does not match body type int"),
    ("arg_annotation_mismatch",
     "fun g(y: bool) = y\nfun main() = g(1)\n",
     "cannot unify int with bool"),
    ("occurs_check_actionable",
     "fun f(x) = if true then x else (x, 1)\n",
     "occurs check failed"),
    ("tvar_uniform_restriction_darr",
     "fun f(x) = array_get(x, 0)\n"
     "fun main() = f(array_make(3, 0))\n",
     "array_get: first arg must be a dynamic array"),
    ("float_star_rejected",
     "fun f(x: float) = x * 2.0\n",
     "int-only; use `+.`/`-.`/`*.`/`/.` for float arithmetic"),
    ("int_star_dot_rejected",
     "fun f(x: int) = x *. 2\n",
     "float-only; use `+`/`-`/`*`/`/` for int arithmetic"),
    ("inexhaustive_inferred_scrutinee",
     "fun f(l) = match l with [] -> 0\nfun main() = f(1 :: [])\n",
     "match is not exhaustive"),
    ("inexhaustive_witness_cons",
     "fun f(l) = match l with [] -> 0\nfun main() = f(1 :: [])\n",
     "(_ :: _)"),
    ("redundant_arm_inferred",
     "fun f(l) = match l with [] -> 0 | _ :: _ -> 1 | _ -> 2\n"
     "fun main() = f([])\n",
     "unreachable"),
    ("poly_use_before_decl",
     "fun c1() = if pid(true) then 1 else 0\n"
     "fun c2() = pid(3)\n"
     "fun pid(x) = x\n"
     "fun main() = c1() + c2()\n",
     "App pid: arg type mismatch"),
    ("bool_comparison_rejected",
     "fun main() = if true < false then 1 else 0\n",
     "Type mismatch in binary operation"),
    ("cons_elem_mismatch_names_types",
     "fun main() = len(1 :: (true :: []))\n"
     "fun len(l) = match l with [] -> 0 | _ :: t -> 1 + len(t)\n",
     "head type int does not match the list element type bool"),
]


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_phase_e"
    sim.DIR = os.path.abspath(build_dir)
    ok = True

    # --- layer 1: run the suite under sim -----------------------------
    w = sim.World()
    w.storage["mcaml:objpool"] = {"cells": []}
    w.storage["mcaml:scratch"] = {"cells": []}
    w.storage["mcaml:permheap"] = {"cells": []}
    w.storage["mcaml:region_tmp"] = {"objpool": [], "scratch": []}
    for s in ("$objpool_next", "$scratch_next", "$permheap_next"):
        w.scores[s] = 0

    sim.run_function(w, "run_all_e")

    for line in w.say:
        print(f"  [say] {line}")
    p, f = w.scores.get("$pass", 0), w.scores.get("$fail", 0)
    if p != EXPECTED_CHECKS or f != 0:
        print(f"FAIL: run_all_e pass={p} fail={f} "
              f"(want pass={EXPECTED_CHECKS} fail=0)")
        ok = False
    else:
        print(f"OK: run_all_e pass={p} fail={f}")

    pool_next = w.scores.get("$objpool_next")
    cells = w.storage["mcaml:objpool"]["cells"]
    scratch_next = w.scores.get("$scratch_next")
    if pool_next != 0 or cells != [] or scratch_next != 0:
        print(f"FAIL: §4.4 arena reset did not fire — "
              f"$objpool_next={pool_next}, cells={len(cells)}, "
              f"$scratch_next={scratch_next}")
        ok = False
    else:
        print("OK: §4.4 arena reset ($objpool_next=0, cells empty, "
              "$scratch_next=0)")

    # --- layer 2: grep pins -------------------------------------------
    emitted = os.listdir(sim.DIR)
    for fn in NO_CLONES:
        clones = [f for f in emitted
                  if f.startswith(fn) and f.endswith(".mcfunction")
                  and f != fn + ".mcfunction"
                  and not f.startswith(fn + "_call")
                  and not f.startswith(fn + "__for")]
        if clones:
            print(f"FAIL: polymorphic {fn} has unexpected clones: {clones}")
            ok = False
        else:
            print(f"OK: zero clones for polymorphic {fn}")

    template_clones = [f for f in emitted
                       if f.startswith(TEMPLATE_CLONE_PREFIX)]
    if len(template_clones) >= 2:
        print(f"OK: E7 template path cloned per aid pair "
              f"({sorted(template_clones)})")
    else:
        print(f"FAIL: expected >=2 {TEMPLATE_CLONE_PREFIX}* clones, "
              f"found {template_clones}")
        ok = False

    for fname, needles in GREP_FORBIDDEN.items():
        with open(os.path.join(sim.DIR, fname)) as fh:
            body = fh.read()
        bad = [n for n in needles if n in body]
        if bad:
            print(f"FAIL: grep {fname}: forbidden {bad} present")
            ok = False
        else:
            print(f"OK: grep {fname}: none of {needles}")

    # --- layer 3: compile-time rejection probes ------------------------
    mcaml = os.path.join(REPO, "mcaml")
    for name, src, needle in REJECTS:
        r = subprocess.run([mcaml, "-o", "/tmp/phase_e_reject_out"],
                           input=src.encode(), capture_output=True)
        msg = (r.stdout + r.stderr).decode()
        rejected = r.returncode != 0 or "Error" in msg
        found = needle in msg
        if rejected and found:
            print(f"OK: reject {name}")
        else:
            print(f"FAIL: reject {name}: rejected={rejected}, "
                  f"message match={found}\n       got: {msg.strip()[:120]}")
            ok = False

    print("PHASE E SUITE PASSED" if ok else "PHASE E SUITE FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
