(* tick_guard.ml — per-iteration tick budget guard for TCO'd self-loops
   (plan §1.6).

   The straight-line tick splitter ([tick_split.ml]) only handles a single
   .mcfunction file overflowing the per-tick command budget. It cannot
   handle a tail-recursive loop where each iteration is itself a fresh
   [function mcaml:<self>] dispatch: the static splitter sees the file as
   small but the runtime executes the body N times in a single tick under
   the same [maxCommandChainLength] counter.

   The fix is a per-iteration tick guard inserted at the entry of every
   TCO'd self-recursive function. The recursive function increments
   [$tick_iters] on entry; when it crosses [MCAML_LOOP_ITER_LIMIT], the
   counter is reset, the function self-schedules for the next tick via
   [schedule function mcaml:<self> 1t], and returns early. State
   ([param_N] slots, [storage mcaml:heap], [storage mcaml:stk]) survives
   the tick boundary automatically, so the next tick resumes the loop
   from exactly where it left off.

   This pass operates at the FILE level (post-codegen, post-tick_split)
   so the guard's commands are not double-counted by the splitter. The
   four prepended commands:

       scoreboard players add $tick_iters vars 1
       execute if score $tick_iters vars matches <N>.. run scoreboard players set $tick_iters vars 0
       execute if score $tick_iters vars matches 0 run schedule function mcaml:<self> 1t
       execute if score $tick_iters vars matches 0 run return 0

   Note the `matches 0` guard on lines 3 and 4 — line 2 resets the counter
   to 0 only when the budget was reached, so subsequent commands keying
   off `matches 0` fire iff a reset just happened. This avoids needing a
   separate "did we reset?" flag slot.

   On the next tick the scheduler dispatches the same function. Its first
   action is the increment, taking the counter from 0 → 1, well below the
   budget, so the loop body runs.

   Where to inject. For functions with no LICM-hoisted preheader the entry
   file is [<fname>.mcfunction] and external [function mcaml:<fname>] calls
   plus self-[TTail] back-edges both land there. For LICM-split functions
   the wrapper is [<fname>] (runs preheader once) and the body is
   [<fname>__body] (which every self-[TTail] re-enters). The guard must
   live in [<fname>__body] so it fires on every iteration; otherwise the
   counter would only ever reach 1 and the loop would never split.

   Disable via [MCAML_NO_TICK_GUARD=1] for A/B measurement. *)

let default_iter_limit = 1024

let iter_limit () : int =
  try
    let s = Sys.getenv "MCAML_LOOP_ITER_LIMIT" in
    let n = int_of_string s in
    if n < 1 then 1 else n
  with Not_found | Failure _ -> default_iter_limit

let disabled () : bool =
  try Sys.getenv "MCAML_NO_TICK_GUARD" = "1" with Not_found -> false

(* The four guard commands prepended at the entry of [target_fname]. The
   `target_fname` is the function name used in [function mcaml:<...>]
   dispatch from the back-edge — that's the function the schedule must
   re-invoke a tick later, so its name parameterizes the [schedule]
   command. *)
let guard_cmds ~(target_fname : string) ~(limit : int) : string list =
  [
    "scoreboard players add $tick_iters vars 1";
    Printf.sprintf
      "execute if score $tick_iters vars matches %d.. run scoreboard players set $tick_iters vars 0"
      limit;
    Printf.sprintf
      "execute if score $tick_iters vars matches 0 run schedule function mcaml:%s 1t"
      target_fname;
    "execute if score $tick_iters vars matches 0 run return 0";
  ]

(* Pick the file name to inject the guard into for a guarded function
   [fname]. If [<fname>__body] exists in the file list, that's the
   LICM-split body that self-[TTail] back-edges target; otherwise the
   guard goes in the plain [<fname>] file. Returns the chosen name so
   the [schedule] command can be parameterized correctly. *)
let entry_file_name (files : (string * 'a) list) (fname : string) : string =
  let body = fname ^ "__body" in
  if List.exists (fun (n, _) -> n = body) files then body else fname

(* Prepend [extra] to the command list of the file named [target] in
   [files]. Leaves every other file untouched. *)
let prepend_to (files : (string * string list) list) (target : string)
    (extra : string list) : (string * string list) list =
  List.map
    (fun (n, cmds) -> if n = target then (n, extra @ cmds) else (n, cmds))
    files

let run ~(guarded : string list) (files : (string * string list) list)
    : (string * string list) list =
  if disabled () || guarded = [] then files
  else begin
    let limit = iter_limit () in
    List.fold_left
      (fun acc fname ->
        let target = entry_file_name acc fname in
        let cmds = guard_cmds ~target_fname:target ~limit in
        prepend_to acc target cmds)
      files guarded
  end
