(* closure_spec.ml — Phase F, F3 (escape analysis) + F4 (specialization).

   Runs once, between Inline.run and Monomorphize.run (main.ml), over the
   whole post-inline [fn_table]. Per §13.12 decision 3, F4 is conceptually
   "an extension of Monomorphize's existing per-argument-shape clone key,
   extended to also key on closure identity" rather than a separate
   re-entrant phase; it is implemented here as its own module (not folded
   directly into monomorphize.ml) to avoid entangling new closure logic
   with the well-tested array-clone machinery, while sitting at the exact
   same point in the pipeline and reusing the same "clone once, rewrite
   every caller" shape.

   v1 scope (deliberately narrower than full whole-program points-to
   analysis — see DYNMEM_PLAN.md §13.12 decision 6 for the write-up):

   - A closure's "origin" is resolved by requiring its holding vreg to be
     defined EXACTLY ONCE in the owning function (cfg_func is non-SSA;
     branch-merged defs of the same vreg are conservatively treated as
     unresolvable) and chasing ICopy chains back to a single
     [IClosureMake]. This sidesteps a full reaching-definitions analysis:
     write-once vregs need no dominance reasoning at all.
   - Same-function case: an [IApply] whose closure operand resolves to a
     single [IClosureMake] in the SAME cfg_func is rewritten in place to
     an ordinary [ICall] — no cloning needed. The abandoned
     [IClosureMake] is left for M3a's DCE to remove (it is not
     side-effecting), which is what makes this genuinely zero-cost.
   - Cross-function single-hop case: when an [ICall] argument at a
     TFun-typed parameter position resolves to a single [IClosureMake] in
     the CALLER, and the CALLEE uses that parameter, throughout its own
     body, ONLY as the closure-operand of its own [IApply] instructions
     (no ref-store, no return, no forwarding through another call or a
     self-tail-recursive back-edge — all conservatively disqualifying),
     the callee is cloned once per (callee, resolved lam_fnames) key,
     capped by MCAML_SPECIALIZE_LIMIT (default 8) clones per source
     callee. The clone's internal IApply(s) for that parameter are
     rewritten to ICall against the resolved lambda helper, with the
     captures threaded in as new trailing scalar params; the call site is
     rewritten to append the actual capture vregs. The original
     parameter slot is left in place (still passed, now unread) rather
     than dropped-and-renumbered — a deliberate simplification: one
     harmless dead argument-pass per specialized call, not a correctness
     issue.
   - Anything not resolved by either case (multi-hop forwarding past one
     callee, ref-stored, returned, ambiguous merge, forwarded through a
     self-tail loop, or budget-exceeded) is left as a surviving
     [IClosureMake]/[IApply] pair — Escaping, in decision 2's terms — and
     reaches codegen_cfg's loud F5-deferred stub if actually emitted. *)

open Cfg

(* ---- per-function def bookkeeping (shared by both cases) ---- *)

type def_info = {
  def_count : (vreg, int) Hashtbl.t;
  def_instr : (vreg, instr) Hashtbl.t;  (* only meaningful when count = 1 *)
  all_defs  : (vreg, instr list) Hashtbl.t;
    (* every def instr seen for a vreg, in no particular order — used
       only for F6a's best-effort ambiguous-merge attribution (§13.12,
       new decision): when a def-count > 1, this lets the diagnostic
       name every distinct IClosureMake origin reaching the merge. *)
}

let collect_defs (cfg : cfg_func) : def_info =
  let def_count = Hashtbl.create 16 in
  let def_instr = Hashtbl.create 16 in
  let all_defs = Hashtbl.create 16 in
  let note d i =
    Hashtbl.replace def_count d (1 + (try Hashtbl.find def_count d with Not_found -> 0));
    if not (Hashtbl.mem def_instr d) then Hashtbl.replace def_instr d i;
    Hashtbl.replace all_defs d (i :: (try Hashtbl.find all_defs d with Not_found -> []))
  in
  Array.iter (fun (b : block) ->
    List.iter (fun i -> match instr_def i with
      | Some d -> note d i
      | None -> ()) b.instrs
  ) cfg.blocks;
  { def_count; def_instr; all_defs }

(* Resolve [v]'s origin within one function: [Some (lam_fname, captures)]
   iff [v] is defined exactly once and that definition is (transitively,
   through single-def ICopy chains) an IClosureMake. Cycle-safe via a
   visited set (pathological input only; well-formed programs never
   cycle here). *)
let resolve_origin (info : def_info) (v : vreg) : (string * vreg list) option =
  let visited = Hashtbl.create 8 in
  let rec go v =
    if Hashtbl.mem visited v then None
    else begin
      Hashtbl.replace visited v ();
      match Hashtbl.find_opt info.def_count v with
      | Some 1 ->
          (match Hashtbl.find_opt info.def_instr v with
           | Some (IClosureMake (_, fname, caps)) -> Some (fname, caps)
           | Some (ICopy (_, s)) -> go s
           | _ -> None)
      | _ -> None
    end
  in
  go v

(* ---- F6a: per-lambda specialize/escape diagnostic report ----

   §13.6's contract: "[closure] <name>: specialized (N call sites)" or
   "[closure] <name>: ESCAPING via <reason> — ~M cmds/call[, inside hot
   loop <loop>]", keyed by lambda-HELPER name (e.g. "main__lam1"), not
   by call site. Threading decision (§13.12, new): populated in two
   passes touching this same module — [run] (Phase 2, below) fills in
   [resolved_sites] / [escape_reason] / [site_functions] as it already
   walks every IApply/ICall site for the specialization rewrite itself,
   so no separate whole-table re-walk is needed; [check_hot_loop]
   (called from codegen.ml's [compile_cfg_to_files], Phase 3, once per
   function right after that function's own [Optimize.run] has
   returned — loop_detect is only meaningful post-LICM/unroll/SROA, and
   this is the exact point the F6 kickoff named, "before regalloc")
   fills in the hot-loop annotation once loop structure exists.
   [print_report] is called once by main.ml after every function has
   been through Phase 3. Always-on, no MCAML_* gate: a program with
   zero lambdas populates zero [report] entries, so it emits zero bytes
   of new stderr output — this is what the F6a exit test asserts (grep
   over the ten /tmp harnesses' captured stderr, all lambda-free). *)

type report_entry = {
  mutable resolved_sites : int;
  mutable escape_reason  : string option;
  mutable hot_loop       : string option;
}

let report : (string, report_entry) Hashtbl.t = Hashtbl.create 16
(* lam_fname -> #captures, gathered once at the end of [run] from any
   surviving IClosureMake — feeds the ESCAPING line's "~M cmds/call"
   using cost.ml's own IApply formula (4 + 2*captures). *)
let caps_count : (string, int) Hashtbl.t = Hashtbl.create 16
(* lam_fname -> set of function names whose body holds an unresolved
   use attributable to it. Best-effort (an ambiguous-merge IApply's
   runtime identity is not statically knowable — every candidate origin
   reaching the merge is tagged); used only to steer
   [check_hot_loop]'s hot-loop annotation and MCAML_STRICT_HOT's error
   message toward the right lambda name(s), never for correctness of
   the specialization rewrite itself. *)
let site_functions : (string, (string, unit) Hashtbl.t) Hashtbl.t = Hashtbl.create 16

let get_entry (lam_fname : string) : report_entry =
  match Hashtbl.find_opt report lam_fname with
  | Some e -> e
  | None ->
      let e = { resolved_sites = 0; escape_reason = None; hot_loop = None } in
      Hashtbl.replace report lam_fname e; e

let note_resolved (lam_fname : string) : unit =
  let e = get_entry lam_fname in
  e.resolved_sites <- e.resolved_sites + 1

let note_site (lam_fname : string) (fname : string) : unit =
  let s = match Hashtbl.find_opt site_functions lam_fname with
    | Some s -> s
    | None ->
        let s = Hashtbl.create 4 in
        Hashtbl.replace site_functions lam_fname s; s
  in
  Hashtbl.replace s fname ()

let note_escape (lam_fname : string) (fname : string) (reason : string) : unit =
  let e = get_entry lam_fname in
  if e.escape_reason = None then e.escape_reason <- Some reason;
  note_site lam_fname fname

(* Best-effort attribution for a closure operand that failed to resolve
   to a single origin. Chases the SAME single-def ICopy chain
   [resolve_origin] does (a plain operand can be one hop away from the
   actual ambiguity, e.g. after Inline.run's splice-time [$inN_]
   rebinding), stopping at whichever vreg first fails to be a clean
   single-def IClosureMake/ICopy chain. The ONLY way that failure can
   happen for a vreg that IS locally defined is def-count <> 1 (an
   ambiguous control-flow merge); def-count = 0 means [v] is external
   to this function (typically the function's own incoming TFun
   parameter — not this function's problem to explain, the caller side
   in [rewrite_callers] owns that attribution), and def-count = 1 with
   a non-closure-chain shape is the HOF-factory-return / ref-then-call
   shape, both of which already fail earlier at knormal (decision 8) —
   they cannot actually reach this point, so they are silently skipped
   here rather than mis-attributed. Not every theoretically-possible
   escape reason is attributable at the CFG level; documented as a
   known, deliberate gap rather than silently pretended-complete. *)
let note_unresolved_closure_use (info : def_info) (fname : string) (v : vreg) : unit =
  let visited = Hashtbl.create 8 in
  let rec go v =
    if Hashtbl.mem visited v then ()
    else begin
      Hashtbl.replace visited v ();
      match Hashtbl.find_opt info.def_count v with
      | Some 1 ->
          (match Hashtbl.find_opt info.def_instr v with
           | Some (ICopy (_, s)) -> go s
           | _ -> ())
      | Some n when n <> 1 ->
          List.iter (fun i -> match i with
            | IClosureMake (_, lam_fname, _) ->
                note_escape lam_fname fname "ambiguous control-flow merge"
            | _ -> ()
          ) (try Hashtbl.find info.all_defs v with Not_found -> [])
      | _ -> ()
    end
  in
  go v

(* ---- same-function case ---- *)

let rewrite_same_function (cfg : cfg_func) : unit =
  let info = collect_defs cfg in
  Array.iter (fun (b : block) ->
    b.instrs <- List.map (fun i -> match i with
      | IApply (dopt, cl, args) ->
          (match resolve_origin info cl with
           | Some (lam_fname, caps) -> note_resolved lam_fname; ICall (dopt, lam_fname, caps @ args)
           | None -> note_unresolved_closure_use info cfg.fname cl; i)
      | other -> other
    ) b.instrs
  ) cfg.blocks

(* ---- cross-function single-hop case ---- *)

let is_tfun (ty : Ast.typ) : bool = match ty with Ast.TFun _ -> true | _ -> false

(* Alias closure of [start] under ICopy chains within [cfg]: every vreg
   that could hold the exact same runtime value as [start]. *)
let alias_set (cfg : cfg_func) (start : vreg) : (vreg, unit) Hashtbl.t =
  let aliases = Hashtbl.create 8 in
  Hashtbl.replace aliases start ();
  let changed = ref true in
  while !changed do
    changed := false;
    Array.iter (fun (b : block) ->
      List.iter (fun i -> match i with
        | ICopy (d, s) when Hashtbl.mem aliases s && not (Hashtbl.mem aliases d) ->
            Hashtbl.replace aliases d (); changed := true
        | _ -> ()) b.instrs
    ) cfg.blocks
  done;
  aliases

(* Does [callee] use param [idx] (transitively through the alias set)
   ONLY as the closure-operand of its own IApply instructions? Any other
   use (ICall arg, IApply arg, ref/heap store, region-exit return, branch
   cond, guard, self-tail forward, ...) disqualifies conservatively.
   Returns [None] when it's only-directly-applied (OK to specialize) or
   [Some reason] naming the first disqualifying use found — F6a needs
   the "why", not just a bool, to attribute the escape to a reason
   string. *)
let only_directly_applied (callee : cfg_func) (idx : int) : string option =
  let target = Printf.sprintf "param_%d" idx in
  let aliases = alias_set callee target in
  let reason = ref None in
  let check_use ?(via_self_tail = false) v =
    if !reason = None && Hashtbl.mem aliases v then
      reason := Some (if via_self_tail
                       then "forwarded across a self-tail back-edge"
                       else "forwarded through 2+ HOF hops")
  in
  Array.iter (fun (b : block) ->
    List.iter (fun i -> match i with
      | ICopy (_, s) -> ignore s (* alias propagation edge; not itself a leak *)
      | IApply (_, cl, args) ->
          (* closure-operand membership is the intended direct-call use;
             appearing in args (forwarded as a plain value) disqualifies. *)
          List.iter check_use args;
          ignore cl
      | _ -> List.iter check_use (instr_uses i)
    ) b.instrs;
    (match b.term with
     | TBranch (c, _, _, _) -> check_use c
     (* TTail is always a self-tail call (cfg.ml's own definition), so
        any leak through its arg list is specifically a loop-carried
        forward, not a generic HOF hop. *)
     | TTail (_, targs) -> List.iter (check_use ~via_self_tail:true) targs
     | TRet | TJump _ | TUnreachable -> ());
    List.iter (fun (v, _) -> check_use v) b.guards
  ) callee.blocks;
  !reason

let clone_block (b : block) : block =
  { label = b.label; instrs = b.instrs; term = b.term; preds = b.preds; guards = b.guards }

let clone_cfg (cfg : cfg_func) : cfg_func =
  { cfg with blocks = Array.map clone_block cfg.blocks }

type resolved_param = { idx : int; lam_fname : string; caps : vreg list }

let mangle (callee_name : string) (resolved : resolved_param list) : string =
  callee_name ^
  String.concat "" (List.map (fun r -> Printf.sprintf "__clo%d_%s" r.idx r.lam_fname) resolved)

(* Directly-applied-only check result, cached per (callee, idx). [None]
   = OK to specialize; [Some reason] = disqualified, with why. *)
let only_applied_cache : (string * int, string option) Hashtbl.t = Hashtbl.create 16
let only_applied_cached (table : (string, cfg_func) Hashtbl.t) (callee_name : string) (idx : int) : string option =
  match Hashtbl.find_opt only_applied_cache (callee_name, idx) with
  | Some r -> r
  | None ->
      let callee = Hashtbl.find table callee_name in
      let r = only_directly_applied callee idx in
      Hashtbl.replace only_applied_cache (callee_name, idx) r;
      r

let ensure_clone
    (table : (string, cfg_func) Hashtbl.t)
    (clone_count : (string, int) Hashtbl.t)
    (clones : (string, unit) Hashtbl.t)
    (limit : int)
    (callee_name : string)
    (resolved : resolved_param list) : string option =
  let key = mangle callee_name resolved in
  if Hashtbl.mem clones key then Some key
  else begin
    let n = try Hashtbl.find clone_count callee_name with Not_found -> 0 in
    if n >= limit then None
    else begin
      Hashtbl.replace clone_count callee_name (n + 1);
      let template = Hashtbl.find table callee_name in
      let cfg = clone_cfg template in
      let orig_arity = List.length template.params in
      let resolved_idxs = List.map (fun r -> r.idx) resolved in
      (* F4-followup: drop each resolved position's slot entirely rather
         than retiring its type to TInt in place. [shift] maps an
         original (pre-drop) index to its position after every dropped
         index below it has been removed — computed once as a single
         index-shift function so simultaneous multi-position drops (a
         HOF specialized on 2+ closure params at once) shift correctly
         instead of double-shifting via sequential single drops. *)
      let shift i = i - List.length (List.filter (fun d -> d < i) resolved_idxs) in
      let new_arity = orig_arity - List.length resolved_idxs in
      let next_slot = ref new_arity in
      let slotted = List.map (fun r ->
        let n_caps = List.length r.caps in
        let slots = List.init n_caps (fun i -> Printf.sprintf "param_%d" (!next_slot + i)) in
        next_slot := !next_slot + n_caps;
        (r, slots)
      ) resolved in
      (* Rewrite IApply -> ICall for the resolved closure operand(s) using
         the ORIGINAL (pre-drop) "param_<idx>" numbering — must happen
         before the renumbering pass below touches those literal strings. *)
      List.iter (fun (r, slots) ->
        let target = Printf.sprintf "param_%d" r.idx in
        let aliases = alias_set cfg target in
        Array.iter (fun (b : block) ->
          b.instrs <- List.map (fun i -> match i with
            | IApply (dopt, cl, args) when Hashtbl.mem aliases cl ->
                ICall (dopt, r.lam_fname, slots @ args)
            | other -> other
          ) b.instrs
        ) cfg.blocks
      ) slotted;
      (* Drop-and-renumber the two places a literal "param_<idx>" string
         must move in lockstep with the params-list drop: the
         entry-prelude ICopy (cfg_build.ml emits exactly one per scalar
         param, always in the entry block, always as a USE — never a
         dest) and any self-tail TTail's own arg list (a TCO'd loop's
         recursive call always supplies a value at every position, so a
         resolved position can still appear there whenever the forwarded
         value isn't literally aliased to the resolved closure itself —
         only_directly_applied already rejects the case where it is,
         via its TTail check, so this is a defensive rename+drop for the
         cases that check doesn't rule out, not dead code). *)
      let entry_blk = cfg.blocks.(cfg.entry) in
      entry_blk.instrs <- List.filter_map (fun i -> match i with
        | ICopy (d, s) when String.length s > 6 && String.sub s 0 6 = "param_" ->
            (match int_of_string_opt (String.sub s 6 (String.length s - 6)) with
             | Some k when k < orig_arity ->
                 if List.mem k resolved_idxs then None
                 else Some (ICopy (d, Printf.sprintf "param_%d" (shift k)))
             | _ -> Some i)
        | other -> Some other
      ) entry_blk.instrs;
      Array.iter (fun (b : block) ->
        match b.term with
        | TTail (f, targs) when f = callee_name ->
            let new_targs =
              List.filteri (fun idx _ -> not (List.mem idx resolved_idxs)) targs
            in
            b.term <- TTail (key, new_targs)
        | _ -> ()
      ) cfg.blocks;
      let new_params =
        List.filteri (fun idx _ -> not (List.mem idx resolved_idxs)) template.params @
        List.concat_map (fun (_, slots) -> List.map (fun s -> (s, Ast.TInt)) slots) slotted
      in
      let new_cfg = { cfg with fname = key; params = new_params } in
      Hashtbl.replace table key new_cfg;
      Hashtbl.replace clones key ();
      Some key
    end
  end

(* One pass over every caller's call sites; mutates [table] in place and
   sets [progress] when a rewrite fires (mirrors Monomorphize.run's own
   fixed-point loop). *)
let rewrite_callers
    (table : (string, cfg_func) Hashtbl.t)
    (clone_count : (string, int) Hashtbl.t)
    (clones : (string, unit) Hashtbl.t)
    (limit : int)
    (caller : cfg_func)
    (progress : bool ref) : unit =
  let info = collect_defs caller in
  Array.iter (fun (b : block) ->
    b.instrs <- List.concat_map (fun i -> match i with
      | ICall (d, callee_name, args) when Hashtbl.mem table callee_name ->
          let callee = Hashtbl.find table callee_name in
          let tfun_positions =
            List.mapi (fun idx (_, ty) -> (idx, ty)) callee.params
            |> List.filter (fun (_, ty) -> is_tfun ty)
            |> List.map fst
          in
          if tfun_positions = [] then [i]
          else begin
            let args_arr = Array.of_list args in
            let resolved =
              List.filter_map (fun idx ->
                if idx >= Array.length args_arr then None
                else
                  match resolve_origin info args_arr.(idx) with
                  | None ->
                      (* Couldn't even name a candidate lambda for this
                         argument (ambiguous merge, or something else
                         entirely) — attribute what we can to the
                         CALLER's own body. *)
                      note_unresolved_closure_use info caller.fname args_arr.(idx);
                      None
                  | Some (lam_fname, caps) ->
                      (match only_applied_cached table callee_name idx with
                       | None -> Some { idx; lam_fname; caps }
                       | Some reason ->
                           note_escape lam_fname callee_name reason; None)
              ) tfun_positions
            in
            if resolved = [] then [i]
            else
              match ensure_clone table clone_count clones limit callee_name resolved with
              | None ->
                  List.iter (fun r ->
                    note_escape r.lam_fname callee_name "exceeded MCAML_SPECIALIZE_LIMIT"
                  ) resolved;
                  [i]
              | Some clone_name ->
                  progress := true;
                  List.iter (fun r -> note_resolved r.lam_fname) resolved;
                  let resolved_idxs = List.map (fun r -> r.idx) resolved in
                  (* F4-followup: drop each resolved position's argument
                     entirely (the clone's param slot no longer exists at
                     all, per ensure_clone's drop-and-renumber) rather
                     than substituting a dummy 0 — one fewer command per
                     specialized call site, and the dropped closure vreg
                     naturally loses this use, which is what lets DCE
                     collect the originating IClosureMake for free. *)
                  let new_args =
                    List.filteri (fun idx _ -> not (List.mem idx resolved_idxs)) args
                  in
                  let extra_caps = List.concat_map (fun r -> r.caps) resolved in
                  [ICall (d, clone_name, new_args @ extra_caps)]
          end
      | other -> [other]
    ) b.instrs
  ) caller.blocks

let run (table : (string, cfg_func) Hashtbl.t) : unit =
  (* F3+F4 same-function case: direct, no cloning. *)
  Hashtbl.iter (fun _ cfg -> if not cfg.is_template then rewrite_same_function cfg) table;

  (* F3+F4 cross-function single-hop case: iterate to a fixed point,
     same shape as Monomorphize.run. *)
  Hashtbl.reset only_applied_cache;
  let limit =
    try int_of_string (Sys.getenv "MCAML_SPECIALIZE_LIMIT") with _ -> 8
  in
  let clone_count : (string, int) Hashtbl.t = Hashtbl.create 8 in
  let clones : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let progress = ref true in
  let iter_cap = ref 16 in
  while !progress && !iter_cap > 0 do
    decr iter_cap;
    progress := false;
    let names = Hashtbl.fold (fun k _ acc -> k :: acc) table [] in
    List.iter (fun caller_name ->
      let caller = Hashtbl.find table caller_name in
      if not caller.is_template then
        rewrite_callers table clone_count clones limit caller progress
    ) names
  done;

  (* Retire any TFun-parameterized function that no longer has any
     internal caller. Unlike an ordinary int/list/ADT parameter, a
     TFun-typed one can never be supplied by an EXTERNAL datapack
     invocation (tools/README.md's entrypoint convention sets param_N
     via `/scoreboard players set` — there is no way to hand-construct
     a valid closure cell that way), so a function with a TFun param is
     only ever a genuine "public entry point" if something inside the
     compiled program still calls it. Once every such call site has
     been resolved away — by the cross-function clone-and-redirect
     above, or (just as commonly) by Inline.run splicing its one and
     only caller before closure_spec's cross-function pass even got to
     see the ICall, same-function-resolving the inlined copy and
     leaving the ORIGINAL definition with zero remaining callers — the
     original is genuinely dead. Mark it [is_template <- true] to reuse
     the EXISTING "never emitted directly" plumbing main.ml/optimize.ml/
     codegen_cfg.ml already respect for array templates (cheaper and
     less invasive than physically removing it from the table, which
     would also need main.ml's separately-computed [fn_order] to
     change). A TFun-parameterized function that STILL has a caller
     (an unresolved one, or simply one this v1 pass didn't reach) is
     correctly left alone — its surviving Escaping IApply legitimately
     reaches the F5-deferred codegen stub if it is ever compiled, which
     is the intended (loud, not silent) v1 behavior. *)
  let is_referenced (name : string) : bool =
    let found = ref false in
    Hashtbl.iter (fun _ (cfg : cfg_func) ->
      if not !found then
        Array.iter (fun (b : block) ->
          List.iter (fun i -> match i with
            | ICall (_, f, _) when f = name -> found := true
            (* A surviving IClosureMake means some function still
               CONSTRUCTS a closure over [name] — the only way an
               Escaping lambda's body is ever invoked is through the
               runtime apply-dispatch trampoline (a `return run
               function mcaml:<name>` command STRING emitted later by
               codegen_cfg, never an ICall/TTail this scan can see
               directly), so a live IClosureMake is exactly as much a
               "real" reference as an ICall for retirement purposes.
               Without this arm, every closure whose only call sites
               are apply-dispatched (i.e. every genuinely Escaping
               closure — the same closures this whole pass exists to
               keep working) gets wrongly retired as dead, leaving the
               dispatch table pointing at a function file that was
               never emitted. *)
            | IClosureMake (_, f, _) when f = name -> found := true
            | _ -> ()) b.instrs;
          (match b.term with
           | TTail (f, _) when f = name -> found := true
           | _ -> ())
        ) cfg.blocks
    ) table;
    !found
  in
  Hashtbl.iter (fun name cfg ->
    if (not cfg.is_template)
       && List.exists (fun (_, ty) -> is_tfun ty) cfg.params
       && not (is_referenced name) then
      cfg.is_template <- true
  ) table;

  (* F6a: gather each surviving lambda's own capture count, once, for
     the ESCAPING report line's "~M cmds/call" (cost.ml's own IApply
     formula, 4 + 2*captures). All instances of a given lam_fname agree
     on capture count by construction (F2 lifts each SOURCE lambda
     occurrence to one fixed-arity helper), so first-found wins. *)
  Hashtbl.iter (fun _ cfg ->
    Array.iter (fun (b : block) ->
      List.iter (fun i -> match i with
        | IClosureMake (_, lam_fname, caps) ->
            if not (Hashtbl.mem caps_count lam_fname) then
              Hashtbl.replace caps_count lam_fname (List.length caps)
        | _ -> ()
      ) b.instrs
    ) cfg.blocks
  ) table

(* ---- F6b: MCAML_STRICT_HOT / F6a: hot-loop annotation ----

   Called once per non-template function from codegen.ml's
   [compile_cfg_to_files], between [Optimize.run] and
   [Regalloc_cfg.alloc] — the exact point the F6 kickoff named ("after
   Optimize.run returns for that function, before regalloc"), so this
   sees the FINAL, fully-optimized CFG shape (post-LICM/unroll/SROA/
   strength_reduce) without a second whole-table pre-pass or any
   reordering of main.ml's existing per-function Phase 3 loop (§13.12
   decision 7's reverted-pass-reordering lesson: pulling Optimize out
   into a separate pass changed unroll.ml's cross-function timing
   enough to miscompile a canary last session — this hooks the
   ALREADY-sequential per-function call instead).

   [Loop_detect.find_loops] already treats a TCO'd self-tail-call as a
   back-edge to the function's own entry (via
   [Dominators.extended_succs]: "TTail (f,_) when f = cfg.fname ->
   [cfg.entry]"), confirmed by direct read before writing this — so "a
   detected natural loop OR a TCO self-tail loop body" from the F6
   kickoff's own wording is ALREADY one unified check under
   [Loop_detect], not two separate mechanisms: any block in the union
   of every [loop.body] is hot. No need to special-case
   [main.ml]'s own [has_self_tail] here (that check exists for a
   different purpose — tick_guard's own per-iteration budget slot). *)
let check_hot_loop (cfg : cfg_func) : unit =
  let has_any_apply =
    Array.exists (fun (b : block) ->
      List.exists (fun i -> match i with IApply _ -> true | _ -> false) b.instrs
    ) cfg.blocks
  in
  (* Skip the whole Dominators/Loop_detect computation for the
     overwhelming majority of functions (no closures at all) — keeps
     this diagnostic's compile-time cost at zero when unused, matching
     every other Known-lambda-is-free claim in this phase. *)
  if has_any_apply then begin
    let idom = Dominators.compute cfg in
    let loops = Loop_detect.find_loops cfg idom in
    if loops <> [] then begin
      let block_loop_name : (label, string) Hashtbl.t = Hashtbl.create 16 in
      List.iter (fun (l : Loop_detect.loop) ->
        let name =
          if l.Loop_detect.header = cfg.entry
          then cfg.fname ^ " (self-tail loop)"
          else Printf.sprintf "%s:L%d" cfg.fname l.Loop_detect.header
        in
        List.iter (fun b ->
          if not (Hashtbl.mem block_loop_name b) then
            Hashtbl.replace block_loop_name b name
        ) l.Loop_detect.body
      ) loops;
      let strict_hot = try Sys.getenv "MCAML_STRICT_HOT" = "1" with Not_found -> false in
      Array.iter (fun (b : block) ->
        match Hashtbl.find_opt block_loop_name b.label with
        | None -> ()
        | Some loop_name ->
            List.iter (fun i -> match i with
              | IApply _ ->
                  (* F6a: an ambiguous-merge IApply's runtime identity
                     isn't statically known, so every candidate lambda
                     this function is a recorded site for gets the
                     hot-loop annotation — best-effort, matches
                     [site_functions]'s own documented approximation. *)
                  Hashtbl.iter (fun lam_fname sites ->
                    if Hashtbl.mem sites cfg.fname then begin
                      let e = get_entry lam_fname in
                      if e.hot_loop = None then e.hot_loop <- Some loop_name
                    end
                  ) site_functions;
                  if strict_hot then begin
                    let implicated =
                      Hashtbl.fold (fun lam_fname sites acc ->
                        if Hashtbl.mem sites cfg.fname then lam_fname :: acc else acc
                      ) site_functions []
                      |> List.sort compare
                    in
                    let who = match implicated with
                      | [] -> "an escaping closure"
                      | names -> "closure " ^ String.concat " / " names
                    in
                    failwith
                      (Printf.sprintf
                         "mcaml: MCAML_STRICT_HOT=1: %s is invoked via \
                          apply-dispatch inside hot loop %s — specialize \
                          it (avoid ref-storage, multi-hop forwarding, or \
                          self-tail forwarding) or move the call outside \
                          the loop"
                         who loop_name)
                  end
              | _ -> ()
            ) b.instrs
      ) cfg.blocks
    end
  end

let print_report () : unit =
  if Hashtbl.length report > 0 then begin
    let names = Hashtbl.fold (fun k _ acc -> k :: acc) report [] |> List.sort compare in
    List.iter (fun lam_fname ->
      let e = Hashtbl.find report lam_fname in
      match e.escape_reason with
      | None ->
          Printf.eprintf "[closure] %s: specialized (%d call site%s)\n%!"
            lam_fname e.resolved_sites (if e.resolved_sites = 1 then "" else "s")
      | Some reason ->
          let caps = try Hashtbl.find caps_count lam_fname with Not_found -> 0 in
          let cost = 4 + 2 * caps in
          let hot = match e.hot_loop with
            | Some l -> Printf.sprintf ", inside hot loop %s" l
            | None -> ""
          in
          Printf.eprintf "[closure] %s: ESCAPING via %s — ~%d cmds/call%s\n%!"
            lam_fname reason cost hot
    ) names
  end
