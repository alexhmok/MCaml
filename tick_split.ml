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

(* Name-based helper detection. Mirrors the naming convention in
   [codegen_cfg.fresh_helper_name] ([<fname>_call<N>]) and
   [codegen_cfg.ensure_macro_helper] ([<aid>_get]). A user function
   whose name happens to end in one of these suffixes will also be
   skipped; that is an accepted false-positive — the cost is only that
   it won't be split. *)
let has_suffix (s : string) (suf : string) : bool =
  let ns = String.length s and nu = String.length suf in
  ns >= nu && String.sub s (ns - nu) nu = suf

let is_call_helper (name : string) : bool =
  let n = String.length name in
  let j = ref n in
  while !j > 0 &&
        (let c = name.[!j - 1] in c >= '0' && c <= '9')
  do decr j done;
  !j < n && !j >= 5 && String.sub name (!j - 5) 5 = "_call"

let is_helper_file (name : string) : bool =
  has_suffix name "_get" || is_call_helper name

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
