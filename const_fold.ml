(* const_fold.ml — constant propagation + algebraic simplification.

   Per-block forward walk. Tracks a vreg -> int map of values known to be
   compile-time constants at the current program point. Rewrites each
   instruction in place to a simpler form whenever enough operands resolve
   to constants.

   Scope:
   - Does NOT delete instructions (DCE's job).
   - Does NOT touch terminators (branch-elim's job).
   - Does NOT rewrite reserved vregs ($ret, $arr_result, param_N).
   - Per-block only: the map is reset at every block boundary. *)

open Cfg

module M = Map.Make(String)

(* Copy of regalloc_cfg.is_reserved — reserved vregs cross CFG boundaries
   invisibly and must never be rewritten or tracked as constants. *)
let is_reserved (n : vreg) : bool =
  n = "$ret" || n = "$arr_result" || n = "$tick_iters" ||
  (String.length n >= 5 && String.sub n 0 5 = "$ref_") ||
  (String.length n > 6
   && String.sub n 0 6 = "param_"
   && let suf = String.sub n 6 (String.length n - 6) in
      suf <> "" && String.for_all (function '0'..'9' -> true | _ -> false) suf)

(* Look up [v] in the constant map. Reserved vregs are never known. *)
let get (m : int M.t) (v : vreg) : int option =
  if is_reserved v then None else M.find_opt v m

(* Remove [d] from the map (its old constant status, if any, is lost). *)
let kill (m : int M.t) (d : vreg) : int M.t = M.remove d m

(* Set [d] to a known constant [k] in the map. Reserved vregs are never
   recorded — we must never learn that (say) $ret is a constant since its
   reads cross CFG boundaries invisibly. *)
let set_const (m : int M.t) (d : vreg) (k : int) : int M.t =
  if is_reserved d then M.remove d m else M.add d k m

(* Rewrite a single instruction using the current constant map.
   Returns (new_instr, updated_map, changed_flag). *)
let rewrite_instr (m : int M.t) (i : instr) : instr * int M.t * bool =
  let open Ast in
  match i with
  | IConst (d, k) ->
      (i, set_const m d k, false)

  | ICopy (d, v) ->
      if is_reserved d then
        (* Never rewrite a reserved dest; just make sure it's not tracked. *)
        (i, kill m d, false)
      else begin
        match get m v with
        | Some k ->
            (IConst (d, k), set_const m d k, true)
        | None ->
            (i, kill m d, false)
      end

  | IBinOp (d, op, a, b) ->
      if is_reserved d then
        (* Leave reserved-dest binops strictly alone. *)
        (i, kill m d, false)
      else begin
        let ka = get m a in
        let kb = get m b in
        match ka, kb with
        | Some ka, Some kb ->
            let fold k = (IConst (d, k), set_const m d k, true) in
            let bool_int x = if x then 1 else 0 in
            (match op with
             | Add  -> fold (ka + kb)
             | Sub  -> fold (ka - kb)
             | Mult -> fold (ka * kb)
             | Div  ->
                 if kb = 0 then
                   (* Do not fold div-by-zero; let runtime handle it. *)
                   (i, kill m d, false)
                 else
                   fold (ka / kb)
             | Mod  ->
                 if kb = 0 then
                   (i, kill m d, false)
                 else
                   fold (ka mod kb)
             (* Phase N / N5: Q16.16 fold arms for FMult/FDiv are
                deferred to N9, where the shift-right-16 and scale-
                before-divide semantics land together. For now, pass
                through without folding. *)
             | FMult | FDiv ->
                 (i, kill m d, false)
             | Eq   -> fold (bool_int (ka = kb))
             | Neq  -> fold (bool_int (ka <> kb))
             | Lt   -> fold (bool_int (ka < kb))
             | Gt   -> fold (bool_int (ka > kb))
             | Leq  -> fold (bool_int (ka <= kb))
             | Geq  -> fold (bool_int (ka >= kb))
             | And  -> fold (min ka kb)
             | Or   -> fold (max ka kb))

        | Some ka, None ->
            (* Only [a] is known. Algebraic simp on the left operand.
               We only rewrite to ICopy when the source vreg [b] is not
               reserved — ICopy with a reserved source would create a new
               use of a reserved vreg, which is fine in principle, but
               we're conservative and leave those alone. *)
            (match op with
             | Add when ka = 0 && not (is_reserved b) ->
                 (ICopy (d, b), kill m d, true)
             | Mult when ka = 0 ->
                 (IConst (d, 0), set_const m d 0, true)
             | Mult when ka = 1 && not (is_reserved b) ->
                 (ICopy (d, b), kill m d, true)
             | _ ->
                 (i, kill m d, false))

        | None, Some kb ->
            (match op with
             | Add when kb = 0 && not (is_reserved a) ->
                 (ICopy (d, a), kill m d, true)
             | Sub when kb = 0 && not (is_reserved a) ->
                 (ICopy (d, a), kill m d, true)
             | Mult when kb = 0 ->
                 (IConst (d, 0), set_const m d 0, true)
             | Mult when kb = 1 && not (is_reserved a) ->
                 (ICopy (d, a), kill m d, true)
             | Div when kb = 1 && not (is_reserved a) ->
                 (ICopy (d, a), kill m d, true)
             | Div when kb = 0 ->
                 (i, kill m d, false)
             | _ ->
                 (i, kill m d, false))

        | None, None ->
            (* Neither operand is a known constant. Only the a=b→0
               pattern for Sub applies. Guard against reserved [a]
               per the plan's Gotcha #4. *)
            (match op with
             | Sub when a = b && not (is_reserved a) ->
                 (IConst (d, 0), set_const m d 0, true)
             | _ ->
                 (i, kill m d, false))
      end

  | ICommand _ ->
      (i, m, false)

  | ICall (None, _, _) ->
      (i, m, false)
  | ICall (Some d, _, _) ->
      (i, kill m d, false)

  | IArrLitConst _ | IArrLitDyn _ ->
      (i, m, false)

  | IArrGetStatic (d, _, _) ->
      (i, kill m d, false)
  | IArrGet (d, id, idx) ->
      (* When the index resolves to a constant, rewrite to a static get
         so SROA can promote the array. This is the bridge from unrolling
         (which substitutes loop var with IConst) to SROA. *)
      (match get m idx with
       | Some k -> (IArrGetStatic (d, id, k), kill m d, true)
       | None -> (i, kill m d, false))

  | IArrSetStatic _ ->
      (* Side-effecting store, no dest to track. Leave as-is. *)
      (i, m, false)
  | IArrSet (id, idx, v) ->
      (* Same bridge as IArrGet: if the runtime index is a known constant,
         rewrite to IArrSetStatic so SROA can promote static-only arrays. *)
      (match get m idx with
       | Some k -> (IArrSetStatic (id, k, v), m, true)
       | None -> (i, m, false))

  (* Dynamic-heap ops: kill the dest in the const map (the value is read
     from NBT at runtime, not knowable here). No static-variant rewrite
     in A3 — the plan lists this as optional in §6. *)
  | IHeapAllocConst (d, _, _) -> (i, kill m d, false)
  | IHeapAlloc (d, _, _) -> (i, kill m d, false)
  | IHeapGet (d, _, _, _) -> (i, kill m d, false)
  | IHeapSet _ -> (i, m, false)
  (* Phase B cons ops: result is a runtime pool index / NBT read, so the
     dest never holds a statically-knowable int. Kill the dest. *)
  | ICons (d, _, _) -> (i, kill m d, false)
  | IHead (d, _) -> (i, kill m d, false)
  | ITail (d, _) -> (i, kill m d, false)
  (* Phase C region brackets: no vreg def (both pass map unchanged). *)
  | IRegionEnter _ -> (i, m, false)
  | IRegionExit _ -> (i, m, false)

let run (cfg : cfg_func) : bool =
  let changed = ref false in
  Array.iter (fun (b : block) ->
    let m = ref M.empty in
    let new_instrs =
      List.map (fun i ->
        let (i', m', c) = rewrite_instr !m i in
        if c then changed := true;
        m := m';
        i'
      ) b.instrs
    in
    b.instrs <- new_instrs
  ) cfg.blocks;
  !changed
