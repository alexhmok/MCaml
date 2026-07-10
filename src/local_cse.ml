(* local_cse.ml — local (per-block) common subexpression elimination.

   Per-block forward walk. Maintains two maps:
     - const_map : int  -> vreg   (last def of IConst(d, k))
     - bin_map   : (op, a, b) -> vreg (last def of IBinOp(d, op, a, b))

   On match, rewrites the current instr to ICopy(d, src); copy_prop will
   collapse the chain on a later iteration. Never records or rewrites
   reserved vregs. Per-block reset — global CSE is M4.

   Kill rule:
     - When a vreg d is redefined, invalidate every entry whose VALUE is d
       (the old def no longer holds) AND every binop entry whose KEY
       references d as an operand (the expression (op, d, _) no longer
       evaluates to the same thing once d changes).
     - const_map keys are integer literals, so only the value side matters
       there.
*)

open Cfg
open Ast

module IntMap = Map.Make (Int)

module BKey = struct
  type t = Ast.binop * vreg * vreg
  (* Polymorphic compare on (binop, string, string) is total and stable:
     binop is a plain sum type with no embedded functions, strings use
     lexicographic order. Hand-rolling the ordering buys nothing. *)
  let compare = compare
end
module BMap = Map.Make (BKey)

let is_commutative : Ast.binop -> bool = function
  | Add | Mult | FAdd | FMult | Eq | Neq | And | Or -> true
  | Sub | Div | Mod | FSub | FDiv | Lt | Leq | Gt | Geq   -> false

let normalize_operands (op : Ast.binop) (a : vreg) (b : vreg) : vreg * vreg =
  if is_commutative op && compare a b > 0 then (b, a) else (a, b)

(* Remove every const_map entry whose VALUE is d. *)
let kill_const (m : vreg IntMap.t) (d : vreg) : vreg IntMap.t =
  IntMap.filter (fun _ v -> v <> d) m

(* Remove every bin_map entry whose VALUE is d OR whose key references d
   as an operand. *)
let kill_bin (m : vreg BMap.t) (d : vreg) : vreg BMap.t =
  BMap.filter (fun (_, a, b) v -> v <> d && a <> d && b <> d) m

let run (cfg : cfg_func) : bool =
  let changed = ref false in
  Array.iter (fun (b : block) ->
    let const_map = ref IntMap.empty in
    let bin_map   = ref BMap.empty in
    let new_instrs =
      List.map (fun i ->
        (match i with
        | IConst (d, k) when not (is_reserved d) ->
            (match IntMap.find_opt k !const_map with
             | Some src when not (is_reserved src) ->
                 changed := true;
                 (* Kill stale entries for d now that it's being redefined
                    (to an equivalent value via copy, but still a redef). *)
                 const_map := kill_const !const_map d;
                 bin_map   := kill_bin   !bin_map   d;
                 ICopy (d, src)
             | _ ->
                 (* Redef d first (kill stale entries), then record the
                    new const_map binding. *)
                 const_map := kill_const !const_map d;
                 bin_map   := kill_bin   !bin_map   d;
                 const_map := IntMap.add k d !const_map;
                 i)
        | IBinOp (d, op, a, b) when not (is_reserved d) ->
            let (na, nb) = normalize_operands op a b in
            (match BMap.find_opt (op, na, nb) !bin_map with
             | Some src when not (is_reserved src) ->
                 changed := true;
                 const_map := kill_const !const_map d;
                 bin_map   := kill_bin   !bin_map   d;
                 ICopy (d, src)
             | _ ->
                 const_map := kill_const !const_map d;
                 bin_map   := kill_bin   !bin_map   d;
                 bin_map   := BMap.add (op, na, nb) d !bin_map;
                 i)
        | _ ->
            (* Every remaining instruction (ICopy, ICall, the array/heap/
               cons/ADT/region/closure reads, IApply, ...): if it defines
               a non-reserved dest, kill that dest from both maps. Do not
               attempt CSE. Dest-less forms (ICommand, IArrLit*, stores)
               fall through the instr_def match and leave the maps alone. *)
            (match Cfg.instr_def i with
             | Some d when not (is_reserved d) ->
                 const_map := kill_const !const_map d;
                 bin_map   := kill_bin   !bin_map   d
             | _ -> ());
            i)
        )
        b.instrs
    in
    b.instrs <- new_instrs
  ) cfg.blocks;
  !changed
