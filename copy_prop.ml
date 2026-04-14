(* copy_prop.ml — local copy propagation.

   Per-block forward walk. For each block, maintain a map
   [vreg -> vreg] where [m[x] = y] means "the current value of [x]
   equals the current value of [y]", so any read of [x] can be
   replaced by a read of [y].

   Rules (see mcaml-m3a-local-opts.md §2):
   - Rewrite every USE through the map before processing the def.
   - For ICopy(d, v) with both non-reserved and d <> v: kill old d
     entries, record map[d] = v (where v is post-rewrite).
   - For ICopy(d, d) (self-copy, possibly after rewrite): kill d as
     key; leave instruction for DCE.
   - Any other def d (non-reserved): kill d both as key and as value.
   - Reserved vregs: never enter the map as key or value.
   - Terminator uses are also rewritten (TBranch cond, TTail args).
   - Guard chains are NOT rewritten (intentionally, cross-block).
   - Do NOT delete instructions in this pass. *)

open Cfg

module M = Map.Make(String)

(* Same predicate as regalloc_cfg.ml's is_reserved. *)
let is_reserved (n : vreg) : bool =
  n = "$ret" || n = "$arr_result" || n = "$tick_iters" ||
  (String.length n >= 5 && String.sub n 0 5 = "$ref_") ||
  (String.length n > 6
   && String.sub n 0 6 = "param_"
   && let suf = String.sub n 6 (String.length n - 6) in
      suf <> "" && String.for_all (function '0'..'9' -> true | _ -> false) suf)

(* Remove every entry that mentions [d] as either key or value. *)
let kill_def (m : vreg M.t) (d : vreg) : vreg M.t =
  let m = M.remove d m in
  M.filter (fun _ v -> v <> d) m

(* Look up [v] in the map; return the substituted vreg or [v] itself. *)
let rewrite (m : vreg M.t) (v : vreg) : vreg =
  match M.find_opt v m with
  | Some v' -> v'
  | None -> v

(* Rewrite a use, tracking whether a substitution happened. *)
let rw (m : vreg M.t) (changed : bool ref) (v : vreg) : vreg =
  let v' = rewrite m v in
  if v' <> v then changed := true;
  v'

(* Process one instruction. Mutates [m] to reflect the def's effect on
   the copy map. Returns the (possibly rewritten) instruction and
   whether any operand was rewritten. *)
let rewrite_instr (m : vreg M.t ref) (i : instr) : instr * bool =
  let c = ref false in
  let i' =
    match i with
    | IConst (_, _) -> i
    | ICopy (d, v) ->
        let v' = rw !m c v in
        if v' = v then i else ICopy (d, v')
    | ICommand _ -> i
    | IBinOp (d, op, a, b) ->
        let a' = rw !m c a in
        let b' = rw !m c b in
        if a' = a && b' = b then i else IBinOp (d, op, a', b')
    | ICall (d_opt, f, args) ->
        let args' = List.map (rw !m c) args in
        if List.for_all2 (=) args args' then i else ICall (d_opt, f, args')
    | IArrLitConst (_, _) -> i
    | IArrLitDyn (id, temps) ->
        let temps' = List.map (rw !m c) temps in
        if List.for_all2 (=) temps temps' then i
        else IArrLitDyn (id, temps')
    | IArrGetStatic (_, _, _) -> i
    | IArrGet (d, id, idx) ->
        let idx' = rw !m c idx in
        if idx' = idx then i else IArrGet (d, id, idx')
    | IArrSetStatic (id, k, v) ->
        let v' = rw !m c v in
        if v' = v then i else IArrSetStatic (id, k, v')
    | IArrSet (id, idx, v) ->
        let idx' = rw !m c idx in
        let v' = rw !m c v in
        if idx' = idx && v' = v then i else IArrSet (id, idx', v')
    | IHeapAlloc (d, p, n) ->
        let n' = rw !m c n in
        if n' = n then i else IHeapAlloc (d, p, n')
    | IHeapGet (d, p, b, idx) ->
        let b' = rw !m c b in
        let idx' = rw !m c idx in
        if b' = b && idx' = idx then i else IHeapGet (d, p, b', idx')
    | IHeapSet (p, b, idx, v) ->
        let b' = rw !m c b in
        let idx' = rw !m c idx in
        let v' = rw !m c v in
        if b' = b && idx' = idx && v' = v then i
        else IHeapSet (p, b', idx', v')
  in
  (* Now update the map based on the def of the (rewritten) instruction. *)
  (match i' with
   | IConst (d, _) ->
       if not (is_reserved d) then m := kill_def !m d
   | ICopy (d, v) ->
       if is_reserved d then
         (* Reserved dest: don't touch the map at all. *)
         ()
       else if d = v then
         (* Self-copy: kill d as key; don't add a self-entry. Still
            kill d as value too, since d is being "reassigned" (to
            itself, but the conservative invariant holds either way). *)
         m := kill_def !m d
       else if is_reserved v then
         (* Reserved source (e.g. $ret, param_N): kill d normally,
            don't record a mapping — reserved sources can have their
            values change implicitly (e.g. $ret clobbered by ICall). *)
         m := kill_def !m d
       else begin
         m := kill_def !m d;
         m := M.add d v !m
       end
   | ICommand _ -> ()
   | IBinOp (d, _, _, _) ->
       if not (is_reserved d) then m := kill_def !m d
   | ICall (None, _, _) -> ()
   | ICall (Some d, _, _) ->
       if not (is_reserved d) then m := kill_def !m d
   | IArrLitConst _ -> ()
   | IArrLitDyn _ -> ()
   | IArrGetStatic (d, _, _) ->
       if not (is_reserved d) then m := kill_def !m d
   | IArrGet (d, _, _) ->
       if not (is_reserved d) then m := kill_def !m d
   | IArrSetStatic _ | IArrSet _ -> ()
   | IHeapAlloc (d, _, _) ->
       if not (is_reserved d) then m := kill_def !m d
   | IHeapGet (d, _, _, _) ->
       if not (is_reserved d) then m := kill_def !m d
   | IHeapSet _ -> ());
  (i', !c)

(* Rewrite uses within a terminator. *)
let rewrite_term (m : vreg M.t) (t : terminator) : terminator * bool =
  let c = ref false in
  let t' =
    match t with
    | TRet | TJump _ | TUnreachable -> t
    | TBranch (cond, lt, le, lj) ->
        let cond' = rw m c cond in
        if cond' = cond then t else TBranch (cond', lt, le, lj)
    | TTail (f, args) ->
        let args' = List.map (rw m c) args in
        if List.for_all2 (=) args args' then t else TTail (f, args')
  in
  (t', !c)

let run (cfg : cfg_func) : bool =
  let changed = ref false in
  Array.iter (fun (b : block) ->
    let m = ref M.empty in
    let new_instrs =
      List.map (fun i ->
        let (i', c) = rewrite_instr m i in
        if c then changed := true;
        i'
      ) b.instrs
    in
    b.instrs <- new_instrs;
    let (t', tc) = rewrite_term !m b.term in
    if tc then changed := true;
    b.term <- t'
  ) cfg.blocks;
  !changed
