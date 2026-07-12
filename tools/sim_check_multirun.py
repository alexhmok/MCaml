#!/usr/bin/env python3
"""Multi-invocation tick_guard check for scripts/multirun_guard.mcaml.

Reproduces (and, once fixed, pins) the stale-$tick_iters bug: the
per-loop budget counter is reset on the yield path but was historically
NOT reset when the loop exited naturally, so a second invocation of the
same guarded loop in one session started with a stale count and could
yield mid-run — even though the run fits comfortably inside the budget
— leaving a synchronous caller (or a player reading $ret) with a
partial result. sim.py models `schedule` as a no-op, so a premature
yield shows up here as run 2 returning run 1's stale $ret.

    ./mcaml -o build_multirun < scripts/multirun_guard.mcaml
    python3 tools/sim_check_multirun.py build_multirun
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402


def guard_limit(build_dir: str) -> int:
    """Parse the per-loop iteration limit out of msum's guard line."""
    with open(os.path.join(build_dir, "msum.mcfunction")) as f:
        for line in f:
            m = re.match(
                r'execute if score \$tick_iters_msum vars matches (\d+)\.\.', line)
            if m:
                return int(m.group(1))
    raise SystemExit("FAIL: no tick_guard limit line found in msum.mcfunction")


def run_msum(w: "sim.World", lo: int, n: int, acc0: int) -> int:
    w.scores["param_0"] = lo
    w.scores["param_1"] = n
    w.scores["param_2"] = acc0
    sim.run_function(w, "msum")
    return w.scores.get("$ret", 0)


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_multirun"
    sim.DIR = os.path.abspath(build_dir)

    limit = guard_limit(build_dir)
    # Each run makes n+1 guarded entries. Pick n so one run fits well
    # under the limit but two consecutive runs cross it: with a stale
    # counter, run 2 yields mid-loop; with a per-run reset, it cannot.
    n = (3 * limit) // 4
    if n < 2:
        raise SystemExit(f"FAIL: guard limit {limit} too small to exercise")
    expect1 = n * (n + 1) // 2
    offset = 10_000_000
    expect2 = offset + expect1

    w = sim.World()
    ret1 = run_msum(w, 1, n, 0)
    ret2 = run_msum(w, 1, n, offset)

    ok = True
    if ret1 != expect1:
        print(f"FAIL: run 1 ret={ret1} (want {expect1})")
        ok = False
    if ret2 != expect2:
        print(f"FAIL: run 2 ret={ret2} (want {expect2}) — stale "
              f"$tick_iters_msum carried over from run 1 caused a "
              f"premature mid-run yield (limit={limit}, n={n})")
        ok = False
    if ok:
        print(f"OK: two back-to-back runs of a guarded loop both completed "
              f"(limit={limit}, n={n} entries per run)")
    print("MULTIRUN " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
