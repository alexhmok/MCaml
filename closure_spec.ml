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
}

let collect_defs (cfg : cfg_func) : def_info =
  let def_count = Hashtbl.create 16 in
  let def_instr = Hashtbl.create 16 in
  let note d i =
    Hashtbl.replace def_count d (1 + (try Hashtbl.find def_count d with Not_found -> 0));
    if not (Hashtbl.mem def_instr d) then Hashtbl.replace def_instr d i
  in
  Array.iter (fun (b : block) ->
    List.iter (fun i -> match instr_def i with
      | Some d -> note d i
      | None -> ()) b.instrs
  ) cfg.blocks;
  { def_count; def_instr }

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

(* ---- same-function case ---- *)

let rewrite_same_function (cfg : cfg_func) : unit =
  let info = collect_defs cfg in
  Array.iter (fun (b : block) ->
    b.instrs <- List.map (fun i -> match i with
      | IApply (dopt, cl, args) ->
          (match resolve_origin info cl with
           | Some (lam_fname, caps) -> ICall (dopt, lam_fname, caps @ args)
           | None -> i)
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
   cond, guard, self-tail forward, ...) disqualifies conservatively. *)
let only_directly_applied (callee : cfg_func) (idx : int) : bool =
  let target = Printf.sprintf "param_%d" idx in
  let aliases = alias_set callee target in
  let ok = ref true in
  let check_use v = if Hashtbl.mem aliases v then ok := false in
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
     | TTail (_, targs) -> List.iter check_use targs
     | TRet | TJump _ | TUnreachable -> ());
    List.iter (fun (v, _) -> check_use v) b.guards
  ) callee.blocks;
  !ok

let clone_block (b : block) : block =
  { label = b.label; instrs = b.instrs; term = b.term; preds = b.preds; guards = b.guards }

let clone_cfg (cfg : cfg_func) : cfg_func =
  { cfg with blocks = Array.map clone_block cfg.blocks }

type resolved_param = { idx : int; lam_fname : string; caps : vreg list }

let mangle (callee_name : string) (resolved : resolved_param list) : string =
  callee_name ^
  String.concat "" (List.map (fun r -> Printf.sprintf "__clo%d_%s" r.idx r.lam_fname) resolved)

(* Directly-applied-only check result, cached per (callee, idx). *)
let only_applied_cache : (string * int, bool) Hashtbl.t = Hashtbl.create 16
let only_applied_cached (table : (string, cfg_func) Hashtbl.t) (callee_name : string) (idx : int) : bool =
  match Hashtbl.find_opt only_applied_cache (callee_name, idx) with
  | Some b -> b
  | None ->
      let callee = Hashtbl.find table callee_name in
      let b = only_directly_applied callee idx in
      Hashtbl.replace only_applied_cache (callee_name, idx) b;
      b

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
      let next_slot = ref orig_arity in
      let slotted = List.map (fun r ->
        let n_caps = List.length r.caps in
        let slots = List.init n_caps (fun i -> Printf.sprintf "param_%d" (!next_slot + i)) in
        next_slot := !next_slot + n_caps;
        (r, slots)
      ) resolved in
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
      (* Retire each resolved position's TFun type to TInt in the clone's
         own params list. This is what stops the fixed-point loop from
         re-selecting the SAME already-specialized position as a fresh
         candidate on the next iteration (its closure operand is gone —
         rewritten to ICall above — but the original param slot is still
         passed positionally and must not keep looking like an open
         TFun parameter, or resolve_origin would successfully re-resolve
         it against the exact same origin every iteration, cloning a
         new, pointlessly-nested name each time until iter_cap cuts it
         off instead of reaching a fixed point). Types elsewhere in
         cfg_func.params are "debug provenance only" (cfg.ml), so
         changing this one is safe. *)
      let resolved_idxs = List.map (fun r -> r.idx) resolved in
      let retired_params =
        List.mapi (fun idx (pname, ty) ->
          if List.mem idx resolved_idxs then (pname, Ast.TInt) else (pname, ty)
        ) template.params
      in
      let new_params =
        retired_params @
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
let dummy_counter = ref 0
let fresh_dummy () = incr dummy_counter; Printf.sprintf "$clo_dummy%d" !dummy_counter

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
                else if not (only_applied_cached table callee_name idx) then None
                else
                  match resolve_origin info args_arr.(idx) with
                  | Some (lam_fname, caps) -> Some { idx; lam_fname; caps }
                  | None -> None
              ) tfun_positions
            in
            if resolved = [] then [i]
            else
              match ensure_clone table clone_count clones limit callee_name resolved with
              | None -> [i]
              | Some clone_name ->
                  progress := true;
                  let resolved_idxs = List.map (fun r -> r.idx) resolved in
                  (* Replace each resolved position's argument with a
                     fresh dummy 0 instead of the original closure vreg.
                     Otherwise the closure vreg would still count as
                     "used" (an argument to a live ICall) even though
                     the clone never reads it (its param slot was
                     retired to TInt in ensure_clone), which would keep
                     the originating IClosureMake artificially alive for
                     DCE and defeat the whole point of the
                     specialization — a Known lambda must reach zero
                     remaining uses of its IClosureMake to actually be
                     zero-cost. *)
                  let dummy_defs = ref [] in
                  let new_args =
                    List.mapi (fun idx a ->
                      if List.mem idx resolved_idxs then begin
                        let dv = fresh_dummy () in
                        dummy_defs := IConst (dv, 0) :: !dummy_defs;
                        dv
                      end else a
                    ) args
                  in
                  let extra_caps = List.concat_map (fun r -> r.caps) resolved in
                  List.rev !dummy_defs @ [ICall (d, clone_name, new_args @ extra_caps)]
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
  ) table
