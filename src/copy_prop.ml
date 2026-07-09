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
  (* Rewrite every USE through the map. Defs are deliberately identity-
     mapped: the dest may still be a key in the pre-update copy map
     (e.g. ICopy(a,b) followed by IConst(a,5) — rewriting IConst's def
     through {a→b} would misdirect the store). The changed flag fires
     inside [rw] per substituted use, exactly as before. *)
  let i' = map_instr_operands ~def:(fun d -> d) ~use:(rw !m c) i in
  (* Now update the map based on the def of the (rewritten) instruction.
     ICopy is the one instruction that can RECORD a fact; everything
     else just kills its dest (if any, and non-reserved) as both key
     and value. No-def instructions (commands, stores, region brackets)
     leave the map untouched. *)
  (match i' with
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
   | _ ->
       (match instr_def i' with
        | Some d when not (is_reserved d) -> m := kill_def !m d
        | _ -> ()));
  (i', !c)

(* Rewrite uses within a terminator. *)
let rewrite_term (m : vreg M.t) (t : terminator) : terminator * bool =
  let c = ref false in
  let t' = map_term_vregs (rw m c) t in
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
