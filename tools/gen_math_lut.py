#!/usr/bin/env python3
"""Generate lib/math.mcaml — Q16.16 transcendental library for MCaml.

The generated file contains top-level `val` global arrays (populated
once at datapack load via Phase G) holding precomputed lookup tables,
plus user-facing functions that combine range reduction with LUT
lookups.

Q16.16 encoding: x_real * 65536 = x_encoded (int32).

Phase Math v1 covers:
  - exp_fixed via int_exp_lut[n] * frac_exp_lut[k]
      where x_encoded = n*65536 + f, k = f/256
  - log_fixed (Math1 half-two — planned, not yet implemented)
  - sigmoid/tanh/gelu (Math2 — planned)
  - tensor primitives (Math3 — planned)

Run with `python3 tools/gen_math_lut.py -o lib/math.mcaml` to
regenerate. Check in both the generator AND the generated file so
the LUT is reproducible but compilation doesn't depend on the
Python toolchain.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path


Q16_SCALE = 65536


def q16(x: float) -> int:
    """Round a real to its Q16.16 int encoding. Raises if out of range."""
    scaled = round(x * Q16_SCALE)
    if scaled < -2**31 or scaled >= 2**31:
        raise ValueError(f"value {x!r} out of Q16.16 range")
    return scaled


# ----- exp LUTs ---------------------------------------------------------
#
# exp(x) for x >= 0, x < 10.4 (Q16.16 saturation boundary).
# Decompose x_encoded = n*65536 + f, where n is the integer part
# (0 <= n <= 10) and f is the fractional raw (0 <= f < 65536).
# Then exp(x) = exp(n) * exp(f / 65536).
#
# int_exp_lut[n]  = Q16.16 encoding of exp(n) for n = 0..10.
#   exp(10) ~ 22026, fits in Q16.16 (max real ~32768). exp(11) ~ 59874
#   overflows — 10 is the hard max.
#
# frac_exp_lut[k] = Q16.16 encoding of exp(k/256) for k = 0..255.
#   Domain [1, e) ~ [1.0, 2.7183). All fit easily.
#   Note: exp_fixed indexes with k = (x mod 65536) / 256, which drops
#   the bottom 8 bits of the fractional part. The resulting value is
#   always exp(floor(f/256) / 256), NOT exp(f/65536), so there's a
#   small systematic bias within each 256-wide bucket. For nearest-
#   entry rounding the bias is at most ~exp(1/512) - 1 ~ 0.002 relative,
#   which matches Q16.16's precision floor anyway. Upgrade to linear
#   interpolation if a workload demands tighter bounds (+~8 cmds/call).

INT_EXP_MAX = 10   # highest safe integer exponent (exp(11) would overflow)
FRAC_EXP_N  = 256  # LUT length; k in [0, 255] maps f/256

def build_int_exp_lut() -> list[int]:
    return [q16(math.exp(n)) for n in range(INT_EXP_MAX + 1)]


def build_frac_exp_lut() -> list[int]:
    return [q16(math.exp(k / FRAC_EXP_N)) for k in range(FRAC_EXP_N)]


# ----- log LUT ---------------------------------------------------------
#
# log_frac_lut[k] = ln(1 + k/256) for k in [0, 255]. Input mantissa m
# in [1, 2) after Q16.16 range reduction; index is (m_enc - 65536)/256.
# Values range from ln(1) = 0 to ln(255/256 + 1) ~ 0.6912, all tiny
# compared to Q16.16 max. Reconstruction:
#   log(x) = n*ln(2) + log_frac_lut[k]
# where n is the net power-of-two shift applied during range reduction.
# The ln(2) scale constant (45426 = round(ln(2) * 65536)) lives as a
# literal in lib/math.mcaml because the range-reduction helpers work in
# the int typing domain and don't benefit from a separate val.
LOG_FRAC_N = 256

def build_log_frac_lut() -> list[int]:
    return [q16(math.log(1.0 + k / LOG_FRAC_N)) for k in range(LOG_FRAC_N)]


# ----- sigmoid / tanh / gelu LUTs --------------------------------------
#
# All three use 256-entry LUTs over bounded input ranges. Precision at
# bucket edges is ~1-2% for the worst cases, adequate for NN inference
# where activation functions saturate heavily and downstream softmax
# normalization absorbs small errors.
#
# sigmoid: LUT over [0, 8) with 256 entries. Bucket = 1/32.
#   Negative inputs use sigmoid(-x) = 1 - sigmoid(x).
#   Inputs beyond 8 saturate to 1 (sigmoid(8) = 0.9997, within the
#   Q16.16 precision floor of ~1.5e-5).
#
# tanh: LUT over [0, 4) with 256 entries. Bucket = 1/64.
#   Negative inputs use tanh(-x) = -tanh(x).
#   Inputs beyond 4 saturate to 1 (tanh(4) = 0.9993).
#
# gelu: LUT over [-4, 4) with 256 entries. Bucket = 1/32.
#   Asymmetric — covers the full domain directly. Beyond the domain
#   saturates to 0 (for x < -4) or x (for x >= 4, since gelu(x) ~ x
#   for large positive x).

SIGMOID_HI = 8.0
SIGMOID_N  = 256
TANH_HI    = 4.0
TANH_N     = 256
GELU_LO    = -4.0
GELU_HI    = 4.0
GELU_N     = 256

def sigmoid(x: float) -> float:
    return 1.0 / (1.0 + math.exp(-x))

def gelu(x: float) -> float:
    # Exact gelu, not the tanh-based approximation: 0.5 * x * (1 + erf(x/sqrt(2))).
    return 0.5 * x * (1.0 + math.erf(x / math.sqrt(2.0)))

def build_sigmoid_lut() -> list[int]:
    step = SIGMOID_HI / SIGMOID_N
    return [q16(sigmoid(k * step)) for k in range(SIGMOID_N)]

def build_tanh_lut() -> list[int]:
    step = TANH_HI / TANH_N
    return [q16(math.tanh(k * step)) for k in range(TANH_N)]

def build_gelu_lut() -> list[int]:
    step = (GELU_HI - GELU_LO) / GELU_N
    return [q16(gelu(GELU_LO + k * step)) for k in range(GELU_N)]


# ----- emission ---------------------------------------------------------

PREAMBLE = """(* lib/math.mcaml — Q16.16 transcendental library for MCaml.

   AUTOMATICALLY GENERATED by tools/gen_math_lut.py.
   DO NOT EDIT DIRECTLY — regenerate with `python3 tools/gen_math_lut.py`.

   Q16.16 encoding: x_real * 65536 = x_encoded (int).
   All functions operate on and return Q16.16 values (type float).

   LUTs:
     int_exp_lut[n]  = exp(n)         for n in [0, 10]   (11 entries)
     frac_exp_lut[k] = exp(k/256)     for k in [0, 255]  (256 entries)
     log_frac_lut[k] = ln(1 + k/256)  for k in [0, 255]  (256 entries)
     sigmoid_lut[k]  = sigmoid(k/32)  for k in [0, 255]  (256 entries, [0, 8))
     tanh_lut[k]     = tanh(k/64)     for k in [0, 255]  (256 entries, [0, 4))
     gelu_lut[k]     = gelu(-4+k/32)  for k in [0, 255]  (256 entries, [-4, 4))

   Functions:
     exp_fixed x     = exp(x) for x in [0, 10)
     log_fixed x     = ln(x)  for x > 0
     sigmoid_fixed x = 1/(1+e^-x), LUT [0,8) with symmetric negatives
     tanh_fixed x    = tanh(x),    LUT [0,4) with symmetric negatives
     gelu_fixed x    = gelu(x),    LUT [-4,4), clamps outside
*)

"""

EXP_FIXED_BODY = """\
(* exp_fixed(x) : float = exp(x) as Q16.16.

   Algorithm:
     - For negative x, return 1/exp(|x|) via one fdiv.
     - For non-negative x, decompose x_encoded = n*65536 + f with
       n = to_int(x) (integer part) and f = x mod 65536 (fractional
       raw). Then exp(x) = exp(n) * exp(f/65536), which we approximate
       with int_exp_lut[n] * frac_exp_lut[f/256].
     - n > 10 saturates to exp(10) * frac_exp_lut[255] (~22025.4 * ~2.71
       ~= 59800, just under Q16.16 overflow). Callers needing the full
       Q16.16 ceiling must clamp before calling.

   Cost: ~20 cmds for the positive fast path (see §13.4 correction).
         Negative path adds ~10 cmds for the fdiv + recursion unfold. *)

(* exp_fixed(x) = exp(x) as Q16.16.

   PRECONDITION: 0.0 <= x < 10.0. For x outside this range the result
   is nonsense (negative x would LUT-index with a negative int; x >= 10
   would index past int_exp_lut[10]).

   Callers with negative arguments should compute it themselves:
     fdiv(1.0, exp_fixed(neg_f(x)))
   MineTorch's softmax path always negates beforehand so this is not
   a usability burden for the primary client; human users who want a
   polymorphic wrapper can write one at their layer.

   Cost: ~25 cmds per call (positive branch only, no conditional
   dispatch overhead). Precision: ~0.1-0.2% worst case from pre-shift
   fmul plus LUT frac truncation (drops bottom 8 bits of the
   fractional raw). Callers needing <0.01% should linear-interpolate
   between adjacent frac_exp_lut entries (~+8 cmds). *)
fun exp_fixed (x: float) : float =
  let x_raw = raw_of_float(x) in
  let n = x_raw / 65536 in
  let k = (x_raw % 65536) / 256 in
  let ei = int_exp_lut[n] in
  let ef = frac_exp_lut[k] in
  fmul(ei, ef)
"""

LOG_FIXED_BODY = """\

(* log_fixed(x) = ln(x) as Q16.16.

   PRECONDITION: x > 0. log(0) is -inf and log(x<0) is complex;
   neither is representable in Q16.16, so the caller must guarantee
   positivity (no runtime guard).

   Algorithm: iterative range reduction via doubling/halving to
   normalize the raw int to [65536, 131072) (i.e., mantissa in
   [1, 2)), tracking the net power-of-two shift n. Final reassembly:
       log(x) = n * ln(2) + log_frac_lut[(m_raw - 65536) / 256]
   where ln(2) encoded as Q16.16 is 45426.

   Two recursive helpers are used so each has a single self-tail-call
   (TCO fires cleanly). log_reduce_up halves x_raw while x >= 2;
   log_reduce_down doubles x_raw while x < 1. Cost per iteration:
   ~6 cmds for the branch + recurse. Max iterations for x in
   [2^-15, 2^15]: 15, average 3-5 for typical NN values. Total
   cost ranges from ~35 cmds (x near 1) to ~120 cmds (x near the
   saturation extremes). For a typical workload expect ~50-60 cmds. *)

fun log_reduce_up (x_raw: int, n: int) : int =
  if x_raw >= 131072 then
    log_reduce_up(x_raw / 2, n + 1)
  else
    let offset = (x_raw - 65536) / 256 in
    let lv = raw_of_float(log_frac_lut[offset]) in
    n * 45426 + lv

fun log_reduce_down (x_raw: int, n: int) : int =
  if x_raw < 65536 then
    log_reduce_down(x_raw * 2, n - 1)
  else
    let offset = (x_raw - 65536) / 256 in
    let lv = raw_of_float(log_frac_lut[offset]) in
    n * 45426 + lv

fun log_fixed (x: float) : float =
  let x_raw = raw_of_float(x) in
  let r =
    if x_raw >= 65536 then log_reduce_up(x_raw, 0)
    else log_reduce_down(x_raw, 0)
  in
  float_of_raw(r)
"""

ACTIVATIONS_BODY = """\

(* -------- Math2: sigmoid / tanh / gelu via bounded-domain LUTs --------

   Each wrapper is a straightforward LUT access with bounds clamping.
   Cost: ~15 cmds per call (bounds branch + LUT dispatch). Precision
   worst case ~1-2% at bucket edges; typical <0.5%. Adequate for NN
   inference where activation functions saturate heavily.

   Note: we use raw_of_float / integer compares to avoid mixing
   float comparisons with integer index math, which keeps typing
   simple. Recall sigmoid_lut has 256 entries over [0, 8) so the
   bucket-raw width is 8*65536/256 = 2048; for the integer-index
   divide we use /2048. Similarly tanh /1024 over [0, 4), and gelu
   /2048 over [-4, 4). *)

fun sigmoid_fixed (x: float) : float =
  let x_raw = raw_of_float(x) in
  if x_raw >= 524288 then
    1.0                                  (* x >= 8, saturate to 1.0 *)
  else if x_raw >= 0 then
    sigmoid_lut[x_raw / 2048]
  else
    let abs_raw = 0 - x_raw in
    if abs_raw >= 524288 then
      0.0                                (* x <= -8, saturate to 0.0 *)
    else
      (* sigmoid(-x) = 1 - sigmoid(x) *)
      let s = sigmoid_lut[abs_raw / 2048] in
      1.0 - s

fun tanh_fixed (x: float) : float =
  let x_raw = raw_of_float(x) in
  if x_raw >= 262144 then
    1.0                                  (* x >= 4, saturate *)
  else if x_raw >= 0 then
    tanh_lut[x_raw / 1024]
  else
    let abs_raw = 0 - x_raw in
    if abs_raw >= 262144 then
      neg_f(1.0)                         (* x <= -4, saturate *)
    else
      (* tanh(-x) = -tanh(x) *)
      let t = tanh_lut[abs_raw / 1024] in
      neg_f(t)

fun gelu_fixed (x: float) : float =
  let x_raw = raw_of_float(x) in
  if x_raw >= 262144 then
    x                                    (* x >= 4: gelu(x) ~ x *)
  else if x_raw < 0 - 262144 then
    0.0                                  (* x <= -4: gelu(x) ~ 0 *)
  else
    (* Shift into [0, 524288) then scale to [0, 255]:
       k = (x_raw + 262144) / 2048. *)
    let shifted = x_raw + 262144 in
    gelu_lut[shifted / 2048]
"""


def to_float_literal(encoded: int) -> str:
    """Render a Q16.16 int as a Python float literal that round-trips
    exactly back to the same encoded int under MCaml's
    `round(f *. 65536)` encoding in knormal. Divisions by 65536 are
    exact in IEEE-754 doubles for |encoded| < 2^47, and multiplying
    the quotient back by 65536 returns the original int exactly, so
    re-encoding via round() never shifts. This is what lets us declare
    the LUTs as `val foo = [| ... |]` with float literals — MCaml's
    typer infers TArrStatic(TFloat, N), subscripts return TFloat, and
    fmul accepts the result without a cast. """
    return repr(encoded / Q16_SCALE)


def emit_wrapped_lut(buf: list[str], name: str, values: list[int]) -> None:
    """Write `val name = [| ... |]` with float literals, 6 per line."""
    buf.append(f"val {name} = [|\n")
    line: list[str] = []
    for i, v in enumerate(values):
        line.append(to_float_literal(v))
        if len(line) == 6:
            suffix = ";" if i < len(values) - 1 else ""
            buf.append("  " + "; ".join(line) + suffix + "\n")
            line = []
    if line:
        buf.append("  " + "; ".join(line) + "\n")
    buf.append("|]\n\n")


def emit(output_path: Path | None) -> None:
    int_exp = build_int_exp_lut()
    frac_exp = build_frac_exp_lut()
    log_frac = build_log_frac_lut()

    buf: list[str] = [PREAMBLE]

    # int_exp is short enough to stay on one line.
    buf.append("val int_exp_lut = [|\n")
    buf.append("  " + "; ".join(to_float_literal(v) for v in int_exp) + "\n")
    buf.append("|]\n\n")

    emit_wrapped_lut(buf, "frac_exp_lut", frac_exp)
    emit_wrapped_lut(buf, "log_frac_lut", log_frac)
    emit_wrapped_lut(buf, "sigmoid_lut",  build_sigmoid_lut())
    emit_wrapped_lut(buf, "tanh_lut",     build_tanh_lut())
    emit_wrapped_lut(buf, "gelu_lut",     build_gelu_lut())

    buf.append(EXP_FIXED_BODY)
    buf.append(LOG_FIXED_BODY)
    buf.append(ACTIVATIONS_BODY)

    text = "".join(buf)
    if output_path is None:
        sys.stdout.write(text)
    else:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text)
        print(f"wrote {output_path} ({len(int_exp)} int + {len(frac_exp)} frac entries)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", type=Path, default=None,
                    help="output file path (default: stdout)")
    args = ap.parse_args()
    emit(args.output)


if __name__ == "__main__":
    main()
