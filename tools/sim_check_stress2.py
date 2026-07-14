#!/usr/bin/env python3
"""Pre-flight verifier for scripts/tests/stress_test_2.mcaml.

Runs the compiled suite's `run_stress2` through sim/sim.py and asserts
all 6 checks pass. Every expected constant is recomputed independently
in Python below (not just copy-pasted from the .mcaml source) so a
hardcoded value that is wrong in BOTH places can't silently agree with
itself — same discipline as tools/sim_check_stress.py.

Run after any compiler change, BEFORE re-packaging the in-game pack:

    cat lib/math.mcaml scripts/tests/stress_test_2.mcaml | ./mcaml -o build_stress2
    python3 tools/sim_check_stress2.py build_stress2
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
import sim  # noqa: E402

EXPECTED_CHECKS = 6


def expected_u1():
    def make_adder(k):
        return lambda x: x + k

    def make_scaler(k):
        return lambda x: x * k

    def apply1(f, x):
        return f(x)

    add5, mul3 = make_adder(5), make_scaler(3)
    a = apply1(add5, 10)
    seven = apply1(add5, 2)
    b = apply1(mul3, seven)

    def apply_via_ref(f, g, cond, x):
        r = g if cond == 1 else f
        return apply1(r, x)

    c = apply_via_ref(add5, mul3, 0, 100)
    d = apply_via_ref(add5, mul3, 1, 100)
    return a + b + c + d


def expected_u2():
    inc, dbl = (lambda x: x + 1), (lambda x: x * 2)

    def compose(f, g):
        return lambda x: f(g(x))

    def twice(f):
        return lambda x: f(f(x))

    def apply1(f, x):
        return f(x)

    h = compose(dbl, inc)
    a = apply1(h, 3)
    b = apply1(twice(h), 3)
    c = apply1(compose(compose(dbl, inc), dbl), 5)
    return a + b + c


def expected_u3():
    def is_even_nt(n):
        return 1 if n == 0 else is_odd_nt(n - 1)

    def is_odd_nt(n):
        return 0 if n == 0 else is_even_nt(n - 1)

    def zig(n):
        return [] if n == 0 else [n] + zag(n - 1)

    def zag(n):
        return [] if n == 0 else [-n] + zig(n - 1)

    d1, d2 = is_even_nt(1500), is_odd_nt(1501)
    return d1 * 1000 + d2 * 7 + sum(zig(400))


def expected_u4():
    def build_seq_u(i, n):
        return [] if i == n else [(i * 13 + 3) % 50 - 20] + build_seq_u(i + 1, n)

    l = build_seq_u(0, 60)
    s = sum(x * x for x in l)
    m = max(x * 2 - 1 for x in l)
    return (s % 1000000) + m


def expected_u5():
    def build_seq_u(i, n):
        return [] if i == n else [(i * 13 + 3) % 50 - 20] + build_seq_u(i + 1, n)

    lvl2 = build_seq_u(0, 8)
    lvl1 = [99] + lvl2
    return sum(lvl1)


def expected_u6():
    def mixer(k):
        return lambda x: x * 2 - k

    def deep_mixed(n, f):
        return [] if n == 0 else [f(n)] + deep_mixed(n - 1, f)

    bumper = mixer(3)
    return sum(deep_mixed(2400, bumper))


def main() -> int:
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build_stress2"
    sim.DIR = os.path.abspath(build_dir)
    sys.setrecursionlimit(200000)

    ok = True
    checks = [
        ("U1", expected_u1, 441),
        ("U2", expected_u2, 48),
        ("U3", expected_u3, 1207),
        ("U4", expected_u4, 13447),
        ("U5", expected_u5, 127),
        ("U6", expected_u6, 5755200),
    ]
    for name, fn, hardcoded in checks:
        got = fn()
        if got != hardcoded:
            print(f"FAIL: expected_{name.lower()}() = {got}, "
                  f"stress_test_2.mcaml hardcodes {hardcoded}")
            ok = False

    w = sim.World()
    sim.run_function(w, "__globals_init")
    sim.run_function(w, "run_stress2")
    for line in w.say:
        print(f"  [say] {line}")
    p, f = w.scores.get("$pass2", 0), w.scores.get("$fail2", 0)
    if p != EXPECTED_CHECKS or f != 0:
        print(f"FAIL: run_stress2 pass={p} fail={f} (want pass={EXPECTED_CHECKS} fail=0)")
        ok = False
    else:
        print(f"OK: run_stress2 pass={p} fail={f}")

    print("STRESS SUITE 2 " + ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
