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
   its PER-LOOP counter on entry; when the counter crosses the per-loop
   limit, the counter is reset, the function self-schedules for the
   next tick via [schedule function mcaml:<self> 1t], and returns
   early. State ([param_N] slots, [storage mcaml:heap], [storage
   mcaml:stk]) survives the tick boundary automatically, so the next
   tick resumes the loop from exactly where it left off.

   Per-loop counters (not one shared [$tick_iters]) are important for
   correctness when loops nest: if an inner TCO'd loop and its
   enclosing outer TCO'd loop share a counter, the inner loop's yield
   fires on the outer's iterations too, and a mid-inner-iteration yield
   leaves the outer's accumulator with a partial sum. Stage 9 of
   MineTorch surfaced this: the MNIST matmul's inner k-loop yielded
   spuriously under the outer j-loop, corrupting every [h1_pre[j]]
   cell by a few LSBs. Per-loop counters (one [$tick_iters_<fname>]
   per guarded function) isolate the yield budget to the loop that
   actually overflowed.

   The per-loop LIMIT is also computed per-function: each guarded loop
   has its own per-iteration body cost (from [Cost.estimate_block]),
   and the limit is [MCAML_TICK_COMMANDS / body_cost] so that executing
   [limit] iterations of that particular body fits within a single
   [maxCommandChainLength] worth of commands. A cheap loop (~5 cmd/iter)
   gets a much higher iteration budget than an expensive one (~100
   cmd/iter).

   Env vars:
     MCAML_TICK_COMMANDS=N    per-tick command budget (default 60000,
                              safely under vanilla 65536 and tunable up
                              to the gamerule-bumped ceiling of 100M
                              for nano-GPT-scale targets)
     MCAML_LOOP_ITER_LIMIT=N  legacy global override — if set, applies
                              uniformly to every guarded loop regardless
                              of its per-iter cost (backwards compatible
                              with older test scripts)
     MCAML_NO_TICK_GUARD=1    disable tick_guard entirely (A/B testing)

   This pass operates at the FILE level (post-codegen, post-tick_split)
   so the guard's commands are not double-counted by the splitter. The
   four prepended commands:

       scoreboard players add $tick_iters_<fname> vars 1
       execute if score $tick_iters_<fname> vars matches <N>.. run scoreboard players set $tick_iters_<fname> vars 0
       execute if score $tick_iters_<fname> vars matches 0 run schedule function mcaml:<self> 1t
       execute if score $tick_iters_<fname> vars matches 0 run return 0

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
   counter would only ever reach 1 and the loop would never split. *)

let default_tick_commands = 60000
let default_iter_limit_fallback = 1024

let tick_commands () : int =
  try
    let s = Sys.getenv "MCAML_TICK_COMMANDS" in
    let n = int_of_string s in
    if n < 1 then 1 else n
  with Not_found | Failure _ -> default_tick_commands

let legacy_iter_limit_override () : int option =
  try
    let s = Sys.getenv "MCAML_LOOP_ITER_LIMIT" in
    let n = int_of_string s in
    Some (if n < 1 then 1 else n)
  with Not_found | Failure _ -> None

(* Per-loop iter limit. If the legacy MCAML_LOOP_ITER_LIMIT is set, it
   wins uniformly. Otherwise compute budget/body_cost, charging a
   small fixed overhead for the guard itself so the total chain stays
   under the per-tick budget. Clamped to ≥1 (can't yield before the
   first iteration runs at all) and to a reasonable ceiling so runaway
   cost estimates (body_cost=0 edge cases) don't yield an absurdly
   high limit that wraps or burns the budget. *)
let guard_overhead = 4  (* the 4 guard commands themselves *)
let max_limit = 1_000_000_000  (* ~1B, well under int32 *)

let compute_limit ~(body_cost : int) : int =
  match legacy_iter_limit_override () with
  | Some n -> n
  | None ->
      let budget = tick_commands () in
      let per_iter = max 1 (body_cost + guard_overhead) in
      let n = budget / per_iter in
      max 1 (min max_limit n)

let disabled () : bool =
  try Sys.getenv "MCAML_NO_TICK_GUARD" = "1" with Not_found -> false

let counter_for (fname : string) : string = "$tick_iters_" ^ fname

(* The four guard commands prepended at the entry of [target_fname]. *)
let guard_cmds ~(target_fname : string) ~(limit : int) : string list =
  let ctr = counter_for target_fname in
  [
    Printf.sprintf "scoreboard players add %s vars 1" ctr;
    Printf.sprintf
      "execute if score %s vars matches %d.. run scoreboard players set %s vars 0"
      ctr limit ctr;
    Printf.sprintf
      "execute if score %s vars matches 0 run schedule function mcaml:%s 1t"
      ctr target_fname;
    Printf.sprintf "execute if score %s vars matches 0 run return 0" ctr;
  ]

(* Counter reset for the natural-exit path. The guard's own reset
   (line 2 above) only fires on the yield path; when the loop instead
   exits normally, the counter used to keep its accumulated value, so
   the NEXT invocation of the same loop in the same session — a second
   run of the entry point, or an inner guarded loop re-entered by an
   enclosing loop — started with a stale budget and could yield
   mid-run even though the run itself fits comfortably under the
   limit, leaving any synchronous reader of $ret with a partial
   result. The fix is one command appended at the very end of the
   guarded entry file: every self-[TTail] iteration leaves the file
   early via `return run`, and a yield leaves via `return 0`, so the
   trailing reset runs exactly once, in the single frame that takes
   the natural exit branch. main.ml appends it BEFORE tick_split runs
   (same pattern as the §4.4 heap reset) so it rides into the
   terminal __cont slice if the file ever gets split. Deliberate
   trade-off: per-tick accounting no longer accumulates across
   consecutive invocations of the same loop within one tick — the
   guard's budget is per-invocation, which is what its per-loop
   design already promised. *)
let reset_cmd ~(target_fname : string) : string =
  Printf.sprintf "scoreboard players set %s vars 0" (counter_for target_fname)

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

(* [guarded] is now a list of (function_name, per_iter_body_cost). The
   per-iter cost comes from [Cost.estimate_block] over the reachable
   blocks of the CFG; main.ml computes it just before emitting the
   CFG to files, where it still has the CFG in scope. *)
let run ~(guarded : (string * int) list) (files : (string * string list) list)
    : (string * string list) list =
  if disabled () || guarded = [] then files
  else
    List.fold_left
      (fun acc (fname, body_cost) ->
        let target = entry_file_name acc fname in
        let limit = compute_limit ~body_cost in
        let cmds = guard_cmds ~target_fname:target ~limit in
        prepend_to acc target cmds)
      files guarded
