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

let no_sroa =
  try Sys.getenv "MCAML_NO_SROA" = "1" with Not_found -> false

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
  mutable values     : int list;     (* IArrLitConst payload *)
  mutable temps      : vreg list;    (* IArrLitDyn payload *)
  mutable is_const   : bool;         (* true iff initializer is IArrLitConst *)
  mutable dynamic_get: bool;         (* saw an IArrGet on this aid *)
  mutable dynamic_put: bool;         (* saw an IArrSet on this aid *)
  mutable static_max : int;          (* max k seen in IArrGetStatic/IArrSetStatic *)
  mutable escapes    : bool;         (* saw #arr: ref or sentinel form *)
}

let fresh_info () = {
  inits = 0; length = 0; values = []; temps = [];
  is_const = false; dynamic_get = false; dynamic_put = false;
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
      (match i with
       | IArrLitConst (id, ks) ->
           let info = info_for id in
           info.inits <- info.inits + 1;
           info.is_const <- true;
           info.length <- List.length ks;
           info.values <- ks;
           if is_sentinel_aid id then info.escapes <- true
       | IArrLitDyn (id, ts) ->
           let info = info_for id in
           info.inits <- info.inits + 1;
           info.is_const <- false;
           info.length <- List.length ts;
           info.temps <- ts;
           if is_sentinel_aid id then info.escapes <- true;
           List.iter note_use_vreg ts
       | IArrGetStatic (_, id, k) ->
           let info = info_for id in
           if k > info.static_max then info.static_max <- k;
           if is_sentinel_aid id then info.escapes <- true
       | IArrGet (_, id, idx) ->
           let info = info_for id in
           info.dynamic_get <- true;
           if is_sentinel_aid id then info.escapes <- true;
           note_use_vreg idx
       | IArrSetStatic (id, k, v) ->
           let info = info_for id in
           if k > info.static_max then info.static_max <- k;
           if is_sentinel_aid id then info.escapes <- true;
           note_use_vreg v
       | IArrSet (id, idx, v) ->
           let info = info_for id in
           info.dynamic_put <- true;
           if is_sentinel_aid id then info.escapes <- true;
           note_use_vreg idx;
           note_use_vreg v
       | ICopy (_, s) -> note_use_vreg s
       | IBinOp (_, _, a, b') -> note_use_vreg a; note_use_vreg b'
       | ICall (_, _, args) -> List.iter note_use_vreg args
       (* Dynamic-heap ops: operand vregs flow through the SROA
          "pseudo-array handle" escape check. They never reference an aid,
          so no info_for bookkeeping — only note_use_vreg to stop the
          analyzer from mistaking a handle-valued vreg for an escaping
          pseudo-aid carrier. *)
       | IHeapAllocConst _ -> ()
       | IHeapAlloc (_, _, n) -> note_use_vreg n
       | IHeapGet (_, _, b_vr, idx) -> note_use_vreg b_vr; note_use_vreg idx
       | IHeapSet (_, b_vr, idx, v) ->
           note_use_vreg b_vr; note_use_vreg idx; note_use_vreg v
       | IConst _ | ICommand _ -> ());
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
       | ICopy (_, s) -> note_pseudo s
       | IBinOp (_, _, a, b') -> note_pseudo a; note_pseudo b'
       | ICall (_, _, args) -> List.iter note_pseudo args
       (* Dynamic-heap ops never carry a pseudo aid or an aid operand;
          they're untracked by the escape analysis. *)
       | IHeapAllocConst _ | IHeapAlloc _ | IHeapGet _ | IHeapSet _ -> ()
       | IConst _ | ICommand _ -> ())
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
