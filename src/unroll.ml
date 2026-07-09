(* unroll.ml — full unrolling of constant-trip for-lift helpers (M4 §3 v1).

   v1 scope. Only synthesized [for_lift] helpers (name matches the
   "__for" pattern) are considered. These have the canonical shape

     fun <name>__forN(i, hi_p, ...fvs): unit =
       if i < hi_p then (body; <name>__forN(i+1, hi_p, ...fvs))
       else ()

   which lowers to a CFG with:
     - L0 (entry, also the loop header for the TCO'd self-tail-call):
         i := param_0
         hi := param_1
         (free var copies from param_2..N)
         c  := i < hi
         branch c ? L_body : L_exit (join L_join)
     - L_body (then-arm, single block, guards [c=1]):
         body instructions...
         tail self(i+1, hi, ...fvs)
     - L_exit (else-arm, guards [c=0]):
         $ret := 0
         jump L_join
     - L_join: ret

   The unroller looks up [cfg.fname]'s callers in the function table and
   asks "are arg 0 (lo) and arg 1 (hi) constants at every call site?"
   via [const_def_in_block]. If yes and trip count [hi - lo] is in
   [0, MCAML_UNROLL_LIMIT] (default 16), it generates [n] cloned body
   blocks chained linearly and rewires the entry block's terminator
   to jump to the first clone. The original L_body becomes unreachable
   (preds cleared) and is skipped by liveness/regalloc/codegen.

   Vreg renaming. Each cloned iteration k uses a per-iteration prefix
   [$un<k>_] for non-reserved vregs. Reserved vregs ($ret, $arr_result,
   param_N, $ref_NAME) are not renamed because they name globally
   stable slots. The loop variable iteration value is materialized by
   prepending [IConst($un<k>_<loop_var>, lo + k)] before each cloned
   body. The body old [IBinOp(_, Add, loop_var, 1)] computing the
   next iter value is left intact (renamed) but is dead post-unroll;
   the second M3a fixed point DCE collapses it.

   Exit guard cleanup. The original [L_exit] block's guard chain
   [(c, Neg)] referenced the now-defunct loop check. After unrolling
   the exit is reached unconditionally from the last iter clone, so
   we clear its guards.

   Disable with [MCAML_NO_UNROLL=1] for A/B measurement. *)

open Cfg

let limit =
  try int_of_string (Sys.getenv "MCAML_UNROLL_LIMIT") with _ -> 16

let no_unroll = Cfg.pass_disabled "MCAML_NO_UNROLL"

(* Walk a block forward and return the most recent IConst value bound
   to [v], if [v]'s most recent definition in the block is an IConst
   (i.e., not overwritten by a non-IConst later in the same block). *)
let const_def_in_block (b : block) (v : vreg) : int option =
  let result = ref None in
  List.iter (fun i ->
    match i with
    | IConst (d, k) when d = v -> result := Some k
    | _ ->
        (match instr_def i with
         | Some d when d = v -> result := None
         | _ -> ())
  ) b.instrs;
  !result

(* Collect every (caller_block, args) pair where caller_block contains
   an [ICall(_, target, args)]. Templates are skipped. *)
let collect_call_sites
    (fn_table : (string, cfg_func) Hashtbl.t)
    (target : string)
  : (block * vreg list) list =
  let acc = ref [] in
  Hashtbl.iter (fun _ cfg ->
    if not cfg.is_template then
      Array.iter (fun (b : block) ->
        List.iter (fun i ->
          match i with
          | ICall (_, f, args) when f = target ->
              acc := (b, args) :: !acc
          | _ -> ()
        ) b.instrs
      ) cfg.blocks
  ) fn_table;
  !acc

(* For [target], verify every caller's call site provides constant
   arg 0 (lo) and arg 1 (hi), all agreeing. *)
let resolve_lo_hi
    (fn_table : (string, cfg_func) Hashtbl.t)
    (target : string)
  : (int * int) option =
  let sites = collect_call_sites fn_table target in
  match sites with
  | [] -> None
  | _ ->
      let rec loop acc = function
        | [] -> acc
        | (b, args) :: rest ->
            (match args with
             | a0 :: a1 :: _ ->
                 (match const_def_in_block b a0,
                        const_def_in_block b a1 with
                  | Some lo, Some hi ->
                      (match acc with
                       | None -> loop (Some (lo, hi)) rest
                       | Some (l, h) when l = lo && h = hi -> loop acc rest
                       | _ -> None)
                  | _ -> None)
             | _ -> None)
      in
      loop None sites

(* Reserved vreg names that are NOT renamed during clone prefixing.
   Deliberately broader than [Cfg.is_reserved]: no digit-suffix check on
   "param_", so ANY name that even looks like a parameter carrier is
   left alone in the per-iteration clones. Do not "fix" this to the
   shared predicate. *)
let is_reserved (v : vreg) : bool =
  v = "$ret"
  || v = "$arr_result"
  || v = "$tick_iters"
  || (String.length v >= 6 && String.sub v 0 6 = "param_")
  || (String.length v >= 5 && String.sub v 0 5 = "$ref_")

(* Rename only body-defined vregs; everything else (reserved, or
   loop-invariant vregs defined in the header/preheader) is left
   alone so per-iteration clones still see the same loop-invariant
   value. Without this, scalar free variables carried through for_lift
   (e.g. the `k` in vec_scale_into) would be renamed to an undefined
   [$unN_k] slot in each iteration. *)
let rename (body_defs : (vreg, unit) Hashtbl.t) (prefix : string) (v : vreg) : vreg =
  if is_reserved v then v
  else if Hashtbl.mem body_defs v then prefix ^ v
  else v

(* Detect a v1 unrollable shape. Returns
   [Some (header, body, exit, loop_var)] on success. The loop_var is the
   vreg defined as [ICopy(d, "param_0")] in the entry block — i.e., the
   user-named loop variable that the body reads. *)
let detect_shape (cfg : cfg_func)
  : (label * label * label * vreg) option =
  let h = cfg.entry in
  let hb = cfg.blocks.(h) in
  match hb.term with
  | TBranch (_, lt, le, _) ->
      let body_blk = cfg.blocks.(lt) in
      (match body_blk.term with
       | TTail (f, _) when f = cfg.fname ->
           let lv = ref None in
           List.iter (fun i ->
             match i with
             | ICopy (d, s) when s = "param_0" -> lv := Some d
             | _ -> ()
           ) hb.instrs;
           (match !lv with
            | Some v -> Some (h, lt, le, v)
            | None -> None)
       | _ -> None)
  | _ -> None

let run_on_cfg
    (fn_table : (string, cfg_func) Hashtbl.t)
    (cfg : cfg_func)
  : bool =
  if no_unroll then false
  else if cfg.is_template then false
  else if not (For_lift.is_synthetic_name cfg.fname) then false
  else
    match detect_shape cfg with
    | None -> false
    | Some (h, body_lbl, exit_lbl, loop_var) ->
        (match resolve_lo_hi fn_table cfg.fname with
         | None -> false
         | Some (lo, hi) ->
             let n = hi - lo in
             if n < 0 || n > limit then false
             else begin
               let body_blk = cfg.blocks.(body_lbl) in
               let body_instrs = body_blk.instrs in
               (* Vregs defined inside the body — the only ones that
                  need per-iteration renaming. Anything referenced by
                  the body but defined outside it (in the header or
                  the function's ambient entry prelude) is
                  loop-invariant and shared across iterations. *)
               let body_defs : (vreg, unit) Hashtbl.t = Hashtbl.create 16 in
               List.iter (fun instr ->
                 match instr_def instr with
                 | Some d -> Hashtbl.replace body_defs d ()
                 | None -> ()
               ) body_instrs;
               Hashtbl.replace body_defs loop_var ();
               let n_existing = Array.length cfg.blocks in
               let iter_labels = Array.init n (fun k -> n_existing + k) in
               let new_blocks =
                 Array.make (n_existing + n) (make_block 0)
               in
               Array.blit cfg.blocks 0 new_blocks 0 n_existing;
               for k = 0 to n - 1 do
                 let lbl = iter_labels.(k) in
                 let prefix = Printf.sprintf "$un%d_" k in
                 let cloned =
                   List.map (map_instr_vregs (rename body_defs prefix))
                     body_instrs
                 in
                 let renamed_lv = rename body_defs prefix loop_var in
                 let init = IConst (renamed_lv, lo + k) in
                 let next_lbl =
                   if k = n - 1 then exit_lbl else iter_labels.(k + 1)
                 in
                 let nb = make_block lbl in
                 nb.instrs <- init :: cloned;
                 nb.term <- TJump next_lbl;
                 nb.guards <- [];
                 nb.preds <-
                   [if k = 0 then h else iter_labels.(k - 1)];
                 new_blocks.(lbl) <- nb
               done;
               cfg.blocks <- new_blocks;
               let hb = cfg.blocks.(h) in
               let first =
                 if n = 0 then exit_lbl else iter_labels.(0)
               in
               hb.term <- TJump first;
               let exit_blk = cfg.blocks.(exit_lbl) in
               exit_blk.preds <-
                 (List.filter (fun p -> p <> h) exit_blk.preds)
                 @ [if n = 0 then h else iter_labels.(n - 1)];
               exit_blk.guards <- [];
               let body_blk = cfg.blocks.(body_lbl) in
               body_blk.preds <- [];
               true
             end)

let run
    (fn_table : (string, cfg_func) Hashtbl.t)
    (cfg : cfg_func)
  : bool =
  run_on_cfg fn_table cfg
