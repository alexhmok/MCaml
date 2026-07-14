#!/usr/bin/env python3
"""Refactor gate: compile the 10 MCaml test programs, run their sim
checkers, and print a canary hash per build (sha256 over the sorted-by-name
concatenation of the emitted .mcfunction files).

Usage:  python3 tools/verify_canary.py
Exit 0 iff all ten suites compile and pass. Compare hashes across
commits to prove a refactor is byte-identical.
"""
import hashlib
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITES = [
    (["lib/math.mcaml", "scripts/tests/mc_test_suite.mcaml"], "/tmp/build_suite", "tools/sim_check_suite.py"),
    (["lib/math.mcaml", "scripts/tests/mc_test_suite_phase_d.mcaml"], "/tmp/build_d", "tools/sim_check_phase_d.py"),
    (["lib/math.mcaml", "scripts/tests/mc_test_suite_phase_e.mcaml"], "/tmp/build_e", "tools/sim_check_phase_e.py"),
    (["lib/math.mcaml", "scripts/tests/stress_test.mcaml"], "/tmp/build_s1", "tools/sim_check_stress.py"),
    (["lib/math.mcaml", "scripts/tests/stress_test_2.mcaml"], "/tmp/build_s2", "tools/sim_check_stress2.py"),
    (["scripts/demos/graph_world.mcaml", "scripts/demos/graph_algos.mcaml"], "/tmp/build_graph", "tools/sim_check_graph.py"),
    (["scripts/tests/multirun_guard.mcaml"], "/tmp/build_multirun", "tools/sim_check_multirun.py"),
    (["scripts/tests/test_nested_ref.mcaml"], "/tmp/build_nestedref", "tools/sim_check_nested_ref.py"),
    (["scripts/tests/test_closure_flow.mcaml"], "/tmp/build_closure_flow", "tools/sim_check_closure_flow.py"),
    (["scripts/tests/test_partial_app.mcaml"], "/tmp/build_partial_app", "tools/sim_check_partial_app.py"),
]


def canary_hash(outdir: str) -> str:
    h = hashlib.sha256()
    for name in sorted(os.listdir(outdir)):
        if name.endswith(".mcfunction"):
            with open(os.path.join(outdir, name), "rb") as f:
                h.update(f.read())
    return h.hexdigest()


# Deliberately broken programs, one per error class main.ml reports.
# Each must exit nonzero AND emit zero .mcfunction files, so scripted
# builds (MineTorch, CI, `&&` chains) can trust the exit status.
BROKEN = [
    ("type error", b"fun f (x: int) : int = x + true\n"),
    ("parse error", b"fun f (x: int : int = x\n"),
    ("reserved name", b"fun init () : int = 1\n"),
    ("bad val RHS", b"val g = 3\n"),
]


def check_error_exits() -> bool:
    outdir = "/tmp/build_err"
    ok = True
    for label, src in BROKEN:
        if os.path.isdir(outdir):
            for name in os.listdir(outdir):
                if name.endswith(".mcfunction"):
                    os.unlink(os.path.join(outdir, name))
        r = subprocess.run(["./mcaml", "-o", outdir], input=src,
                           capture_output=True)
        emitted = [n for n in os.listdir(outdir)
                   if n.endswith(".mcfunction")] if os.path.isdir(outdir) else []
        if r.returncode == 0 or emitted:
            print(f"FAIL error-exit ({label}): rc={r.returncode} "
                  f"files={emitted}")
            ok = False
    if ok:
        print(f"PASS error-exit checks ({len(BROKEN)} broken programs: "
              "nonzero exit, no files)")
    return ok


def main() -> int:
    os.chdir(REPO)
    ok = check_error_exits()
    for sources, outdir, checker in SUITES:
        # Wipe stale output so files removed by a compiler change can't
        # linger from a previous run and mask a hash difference.
        if os.path.isdir(outdir):
            for name in os.listdir(outdir):
                if name.endswith(".mcfunction"):
                    os.unlink(os.path.join(outdir, name))
        src = b"".join(open(s, "rb").read() for s in sources)
        r = subprocess.run(["./mcaml", "-o", outdir], input=src,
                           capture_output=True)
        if r.returncode != 0:
            print(f"COMPILE FAIL {outdir}:\n{r.stderr.decode()}")
            ok = False
            continue
        c = subprocess.run(["python3", checker, outdir], capture_output=True)
        if c.returncode != 0:
            ok = False
            print(c.stdout.decode()[-2000:])
            print(c.stderr.decode()[-2000:])
        tail = c.stdout.decode().strip().splitlines()[-1:] or ["<no output>"]
        status = "PASS" if c.returncode == 0 else "FAIL"
        print(f"{status} {outdir}  ({tail[0]})")
        print(f"  hash {canary_hash(outdir)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
