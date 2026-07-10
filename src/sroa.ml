(* sroa.ml — Scalar Replacement of Aggregates (M4 §4).

   Promote small non-escaping arrays whose every read is a static
   constant-index [IArrGetStatic] into N independent scoreboard slots.
   After promotion the array no longer exists in storage: the
   initializer becomes N [IConst]/[ICopy] instructions and each get
   becomes a single [ICopy]. The post-SROA M3a fixed point then
   collapses the copy chains and DCEs unused element slots.

   Promotability rules (per aid in a non-template function):
     1. Bounded length: the initializer's length is in [0, limit]
        where limit = MCAML_SROA_LIMIT (default 16).
     2. All accesses are [IArrGetStatic d aid k] with constant k
        in range. Any [IArrGet] (runtime index) disqualifies the aid.
     3. Doesn't escape: no [#arr:<aid>] pseudo-vreg references the
        aid (those would be call args to a still-template clone, but
        we run after monomorphization so this is mostly defensive),
        and no [#paramN] sentinel form appears (templates are skipped
        anyway).
     4. Single initializer: exactly one [IArrLitConst]/[IArrLitDyn]
        for the aid in the function.
     5. Defensive: if the function contains any [ICommand] we still
        promote — raw commands in MCaml today don't reference the
        [storage mcaml:heap] path, and the inliner / monomorphizer
        haven't introduced any either. Tighten if that changes.

   Disable with [MCAML_NO_SROA=1] for A/B measurement. *)

open Cfg

let limit =
  try int_of_string (Sys.getenv "MCAML_SROA_LIMIT") with _ -> 16

let no_sroa = Cfg.pass_disabled "MCAML_NO_SROA"

(* True if [v] is a pseudo-array vreg shape "#arr:<aid>" — used by
   monomorphize.ml to thread arrays through call args. After Phase 2b
   none of these should reference a real aid in a non-template function,
   but we check defensively. *)
let pseudo_arr_aid (v : vreg) : aid option =
  let p = "#arr:" in
  let lp = String.length p in
  if String.length v >= lp && String.sub v 0 lp = p
  then Some (String.sub v lp (String.length v - lp))
  else None

let is_sentinel_aid (a : aid) : bool =
  String.length a >= 6 && String.sub a 0 6 = "#param"

(* Per-aid info we collect in a single pass. *)
type info = {
  mutable inits      : int;          (* count of IArrLit* writes *)
  mutable length     : int;
  mutable dynamic_get: bool;         (* saw an IArrGet on this aid *)
  mutable dynamic_put: bool;         (* saw an IArrSet on this aid *)
  mutable static_max : int;          (* max k seen in IArrGetStatic/IArrSetStatic *)
  mutable escapes    : bool;         (* saw #arr: ref or sentinel form *)
}

let fresh_info () = {
  inits = 0; length = 0;
  dynamic_get = false; dynamic_put = false;
  static_max = -1; escapes = false;
}

let collect (cfg : cfg_func) : (aid, info) Hashtbl.t =
  let tbl : (aid, info) Hashtbl.t = Hashtbl.create 8 in
  let info_for id =
    match Hashtbl.find_opt tbl id with
    | Some i -> i
    | None ->
        let i = fresh_info () in
        Hashtbl.add tbl id i; i
  in
  let note_use_vreg v =
    match pseudo_arr_aid v with
    | Some a -> (info_for a).escapes <- true
    | None -> ()
  in
  Array.iter (fun (b : block) ->
    List.iter (fun i ->
      (* Aid bookkeeping on the six static-array ops. *)
      (match i with
       | IArrLitConst (id, ks) ->
           let info = info_for id in
           info.inits <- info.inits + 1;
           info.length <- List.length ks;
           if is_sentinel_aid id then info.escapes <- true
       | IArrLitDyn (id, ts) ->
           let info = info_for id in
           info.inits <- info.inits + 1;
           info.length <- List.length ts;
           if is_sentinel_aid id then info.escapes <- true
       | IArrGetStatic (_, id, k) ->
           let info = info_for id in
           if k > info.static_max then info.static_max <- k;
           if is_sentinel_aid id then info.escapes <- true
       | IArrGet (_, id, _) ->
           let info = info_for id in
           info.dynamic_get <- true;
           if is_sentinel_aid id then info.escapes <- true
       | IArrSetStatic (id, k, _) ->
           let info = info_for id in
           if k > info.static_max then info.static_max <- k;
           if is_sentinel_aid id then info.escapes <- true
       | IArrSet (id, _, _) ->
           let info = info_for id in
           info.dynamic_put <- true;
           if is_sentinel_aid id then info.escapes <- true
       | _ -> ());
      (* Escape check: every read operand flows through the pseudo-array
         handle test so the analyzer never mistakes a handle-valued vreg
         for an escaping pseudo-aid carrier. [instr_uses] covers exactly
         the operands the old exhaustive match noted (verified arm by
         arm): heap/cons/ADT/region/closure operands are handles (ints),
         never aid sentinels, so noting them stays a no-op. *)
      List.iter note_use_vreg (instr_uses i)
    ) b.instrs
  ) cfg.blocks;
  tbl

(* [static_max >= 0] gates promotion on at least one in-function static
   read. Without this we'd happily SROA-away an [IArrLitConst] in a
   caller whose only consumer is a separately-compiled monomorphized
   clone reading the same [storage mcaml:heap <aid>] path — leaving the
   clone dangling. The shared-aid case shows up in test_full_chain
   where main_test inits arr1/arr2 and dot__arr1_arr2 reads them. *)
let promotable (info : info) : bool =
  info.inits = 1
  && not info.dynamic_get
  && not info.dynamic_put
  && not info.escapes
  && info.length >= 0
  && info.length <= limit
  && info.static_max >= 0
  && info.static_max < info.length

let slot_name (id : aid) (k : int) : vreg =
  Printf.sprintf "%s_%d" id k

(* Build the replacement instruction list for one original [instr],
   given the promoted-aid table. Most instructions pass through. *)
let rewrite_instr
    (promoted : (aid, info) Hashtbl.t)
    (i : instr) : instr list =
  match i with
  | IArrLitConst (id, ks) when Hashtbl.mem promoted id ->
      List.mapi (fun k v -> IConst (slot_name id k, v)) ks
  | IArrLitDyn (id, ts) when Hashtbl.mem promoted id ->
      List.mapi (fun k t -> ICopy (slot_name id k, t)) ts
  | IArrGetStatic (d, id, k) when Hashtbl.mem promoted id ->
      [ICopy (d, slot_name id k)]
  | IArrSetStatic (id, k, v) when Hashtbl.mem promoted id ->
      [ICopy (slot_name id k, v)]
  | _ -> [i]

(* Aids referenced by any instruction in [other_cfg]. Conservative: any
   IArrLit*/IArrGet*/IArrSet* that names [aid] counts as a reference, as
   does any pseudo [#arr:<aid>] token surviving in an instruction. Used
   by [run] to disqualify promotion of an aid that a sibling function
   (typically a monomorphized for-loop helper) also touches via the
   shared [storage mcaml:heap <aid>] path — otherwise SROA would SROA-
   away the caller's init while leaving the helper reading/writing
   stale storage. *)
let aids_touched_by (other_cfg : cfg_func) : (aid, unit) Hashtbl.t =
  let tbl : (aid, unit) Hashtbl.t = Hashtbl.create 4 in
  let note_pseudo v =
    match pseudo_arr_aid v with
    | Some a -> Hashtbl.replace tbl a ()
    | None -> ()
  in
  Array.iter (fun (b : block) ->
    List.iter (fun i ->
      (match i with
       | IArrLitConst (id, _)
       | IArrLitDyn (id, _)
       | IArrGetStatic (_, id, _)
       | IArrGet (_, id, _)
       | IArrSetStatic (id, _, _)
       | IArrSet (id, _, _) ->
           Hashtbl.replace tbl id ()
       | _ -> ());
      (* Pseudo-aid tokens can only ride in read-operand positions
         ([instr_uses]); non-array operands (heap/cons/ADT/region/
         closure handles) never match the "#arr:" shape, so noting
         them is a no-op. *)
      List.iter note_pseudo (instr_uses i)
    ) b.instrs
  ) other_cfg.blocks;
  tbl

let run ?fn_table (cfg : cfg_func) : bool =
  if no_sroa then false
  else if cfg.is_template then false
  else begin
    let tbl = collect cfg in
    (* Aids that are also touched by some other non-template function in
       the program. Those aids have off-function consumers via shared
       storage paths; promoting them in this function would silently
       break those consumers. *)
    let external_aids : (aid, unit) Hashtbl.t =
      match fn_table with
      | None -> Hashtbl.create 0
      | Some t ->
          let acc = Hashtbl.create 8 in
          Hashtbl.iter (fun name other ->
            if name <> cfg.fname && not other.is_template then begin
              let touched = aids_touched_by other in
              Hashtbl.iter (fun a () -> Hashtbl.replace acc a ()) touched
            end
          ) t;
          acc
    in
    let promoted : (aid, info) Hashtbl.t = Hashtbl.create 4 in
    Hashtbl.iter (fun id info ->
      if promotable info && not (Hashtbl.mem external_aids id)
      then Hashtbl.add promoted id info
    ) tbl;
    if Hashtbl.length promoted = 0 then false
    else begin
      Array.iter (fun (b : block) ->
        b.instrs <-
          List.concat_map (rewrite_instr promoted) b.instrs
      ) cfg.blocks;
      true
    end
  end
