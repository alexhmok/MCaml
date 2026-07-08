(* optimize.ml — M3a fixed-point optimization driver.

   Runs the four local optimization passes (const_fold, copy_prop, local_cse,
   dce) to fixed point. Each pass mutates the cfg in place and returns true
   iff it made any change. We loop until a whole pass cycle reports no
   change, with a hard cap as a defense against pass bugs.

   Pass order rationale:
     1. const_fold  — creates IConst and ICopy opportunities
     2. copy_prop   — collapses ICopy chains via per-block forward walk
     3. local_cse   — replaces duplicate computations with ICopy
     4. dce         — removes now-dead instructions (and self-copies)
   After dce, the code is smaller — which may expose more opportunities for
   const_fold on the next iteration, so we loop. *)

let max_iterations = 10

(* MCAML_NO_M3A=1 (or MCAML_O0=1) skips the scalar-cleanup fixed point
   entirely — both sweeps. The four passes are semantics-preserving
   cleanups, so skipping them yields correct but unoptimized output;
   note SROA loses the unroll→const_fold static-index bridge when
   they're off, so it may fire less even if left enabled. *)
let no_m3a = Cfg.pass_disabled "MCAML_NO_M3A"

(* M3a fixed point: const_fold/copy_prop/local_cse/dce. *)
let m3a_fixedpoint (cfg : Cfg.cfg_func) : unit =
  let i = ref 0 in
  let continue = ref true in
  while not no_m3a && !continue && !i < max_iterations do
    incr i;
    let c1 = Const_fold.run cfg in
    let c2 = Copy_prop.run cfg in
    let c3 = Local_cse.run cfg in
    let c4 = Dce.run cfg in
    continue := c1 || c2 || c3 || c4
  done

(* M4 loop pass.
   Order: LICM → strength_reduce → unroll → SROA. LICM hoists
   invariants out of the loop body first so the strength reducer can
   see stride/base values that came from the body. Strength
   reduction runs *before* the unroller so loops the unroller cannot
   touch (hand-written tail-recursive ones like matmul2_loop) still
   get their per-iteration multiplies replaced with carrier
   increments; for_lift loops the unroller can fully unroll have no
   derived IVs in this codebase, so strength reduction is a no-op on
   them and unroll fires unaffected. Disable individually with
   [MCAML_NO_LICM=1] / [MCAML_NO_SR=1] / [MCAML_NO_UNROLL=1] /
   [MCAML_NO_SROA=1] for A/B measurement. The function table is
   threaded in for the unroller, which needs to inspect callers to
   resolve constant lo/hi at the call site. *)
let no_licm = Cfg.pass_disabled "MCAML_NO_LICM"

let loop_pass ?fn_table (cfg : Cfg.cfg_func) : unit =
  if not no_licm then ignore (Licm.run cfg);
  ignore (Strength_reduce.run cfg);
  (match fn_table with
   | None -> ()
   | Some t -> ignore (Unroll.run t cfg));
  ignore (Sroa.run ?fn_table cfg)

let run ?fn_table (cfg : Cfg.cfg_func) : unit =
  m3a_fixedpoint cfg;
  loop_pass ?fn_table cfg;
  m3a_fixedpoint cfg
