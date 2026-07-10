(* tick_split.ml — straight-line split-point insertion (plan §1.4).

   Post-pass over the flat [(filename, commands) list] that
   [Codegen_cfg.emit] produces. Walks each main-body file and, when its
   command count exceeds [MCAML_TICK_BUDGET] (default 50000), cuts the
   file into a chain of continuation files linked by
   [schedule function mcaml:<name>__cont<N> 1t]. Helper files
   ([<fname>_call<N>], [<aid>_get]) are left strictly alone: the §1.5
   safety argument says their bodies must execute as one atomic unit
   because a split inside a save/restore helper would unbalance
   [storage mcaml:stk frames].

   Continuation files are *not* wrapped in save/restore — they are
   resumptions of the original function's execution, not fresh calls,
   so scoreboards and [storage mcaml:heap]/[storage mcaml:stk] all
   carry state across the split automatically.

   Loop-aware splitting (per-iteration budget guarding for TCO'd
   self-loops; plan §1.6) is a follow-up session; this file handles
   only straight-line overflow. *)

let default_budget = 50000

let budget () : int =
  try
    let s = Sys.getenv "MCAML_TICK_BUDGET" in
    let n = int_of_string s in
    if n < 2 then 2 else n
  with Not_found | Failure _ -> default_budget

(* Name-based helper detection. Mirrors the naming convention of every
   atomic helper file [Codegen_cfg]/[Codegen_helpers] generate. A user
   function whose name happens to collide with one of these shapes
   will also be skipped; that is an accepted false-positive — the cost
   is only that it won't be split.

   This list must stay in sync with every helper-file name minted
   below main.ml's Phase 3/[codegen_cfg.ml]:
     - [<fname>_call<N>]                    non-tail-call save/restore
     - [<aid>_get] / [<aid>_set]             array/pool macro getter/setter
                                              (also covers [scratch_get],
                                              [permheap_get], etc. — any
                                              pool name, not just per-aid)
     - [cons_head] / [cons_tail]             cons-cell macro getters
     - [obj_tag] / [obj_f<k>]                ADT/tuple/record macro getters
     - [apply] / [apply_dispatch_<code>]     F5 closure apply-dispatch chain
     - [region_truncate_<k>_scratch]
       / [region_truncate_<k>_objpool]       region-exit bump-counter restore
     - [region_walker_list_stash]
       / [region_walker_list_rebuild]        region-exit list deep-copy walker

   Every one of these self-recurses or dispatches via a plain
   synchronous [function mcaml:...] call and its caller depends on the
   WHOLE body completing before reading a result or proceeding past a
   region exit — splitting mid-body would silently desynchronize the
   caller from a still-in-flight dispatch/walk (confirmed: under a
   tuned-down MCAML_TICK_BUDGET, [apply.mcfunction] and the region
   walker helpers used to get split exactly this way, since only the
   [_call<N>]/[_get] shapes were excluded here). *)
let has_suffix (s : string) (suf : string) : bool =
  String.ends_with ~suffix:suf s

let has_prefix (s : string) (pre : string) : bool =
  String.starts_with ~prefix:pre s

let is_call_helper (name : string) : bool =
  let n = String.length name in
  let j = ref n in
  while !j > 0 &&
        (let c = name.[!j - 1] in c >= '0' && c <= '9')
  do decr j done;
  !j < n && !j >= 5 && String.sub name (!j - 5) 5 = "_call"

(* [obj_f<k>] / [apply_dispatch_<code>]: fixed prefix, all-digit tail. *)
let is_prefix_then_digits (name : string) (pre : string) : bool =
  has_prefix name pre &&
  (let n = String.length name and p = String.length pre in
   n > p &&
   let rec all_digits i = i >= n || (name.[i] >= '0' && name.[i] <= '9' && all_digits (i + 1)) in
   all_digits p)

let is_helper_file (name : string) : bool =
  has_suffix name "_get" || has_suffix name "_set"
  || is_call_helper name
  || is_prefix_then_digits name "obj_f"
  || is_prefix_then_digits name "apply_dispatch_"
  || has_prefix name "region_truncate_"
  || (match name with
      | "apply" | "cons_head" | "cons_tail" | "obj_tag"
      | "region_walker_list_stash" | "region_walker_list_rebuild" -> true
      | _ -> false)

(* Take the first [n] elements of [xs], returning ([head], [tail]). *)
let split_at (n : int) (xs : 'a list) : 'a list * 'a list =
  let rec go i acc = function
    | xs when i <= 0 -> (List.rev acc, xs)
    | [] -> (List.rev acc, [])
    | x :: rest -> go (i - 1) (x :: acc) rest
  in
  go n [] xs

(* Split one main-body file's command list into a chain. [orig] is the
   user-visible function name (the name the original file carried); the
   first chunk keeps that name so external callers continue to hit it,
   and subsequent chunks are named [<orig>__cont<N>].

   The cut point is one command before the budget so the trailing
   [schedule function] line keeps the emitted-chunk size at (head+1)
   commands, still within budget. *)
let split_one ~(budget : int) (orig : string) (cmds : string list)
    : (string * string list) list =
  let rec go cont_index cmds =
    let name =
      if cont_index = 0 then orig
      else Printf.sprintf "%s__cont%d" orig cont_index
    in
    (* Count without scanning twice: we already need to know whether
       [List.length cmds > budget], so do it once with a bounded scan. *)
    let rec exceeds n = function
      | _ :: rest when n > 0 -> exceeds (n - 1) rest
      | [] -> false
      | _ -> true
    in
    if not (exceeds budget cmds) then [(name, cmds)]
    else begin
      let head_count = budget - 1 in
      let head, tail = split_at head_count cmds in
      let next_name = Printf.sprintf "%s__cont%d" orig (cont_index + 1) in
      let sched =
        Printf.sprintf "schedule function mcaml:%s 1t" next_name
      in
      (name, head @ [sched]) :: go (cont_index + 1) tail
    end
  in
  go 0 cmds

let run (files : (string * string list) list)
    : (string * string list) list =
  let budget = budget () in
  List.concat_map
    (fun (name, cmds) ->
      if is_helper_file name then [(name, cmds)]
      else split_one ~budget name cmds)
    files
