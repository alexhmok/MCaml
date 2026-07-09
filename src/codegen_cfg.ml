(* codegen_cfg.ml — CFG-driven code generator (Milestone 2, §7).

   Consumes a post-regalloc [Cfg.cfg_func] and produces a
   [(mcfunction_name, commands)] list. The first pair is the top-level function body; the
   remaining pairs are helper mcfunctions (save/restore frames for non-tail
   calls, per-array macro getters for dynamic array indexing).

   Read-only over the CFG: no mutation, no liveness, no regalloc. The caller
   is responsible for having already run regalloc so that [cfg.slot_count] is
   populated and all instruction operands are physical slot names
   (["$rN"], ["param_N"], ["$ret"], ["$arr_result"]).

   Emission strategy is reverse postorder from [cfg.entry]. Each block
   carries a pre-computed guard chain in [block.guards] (established during
   [Cfg_build]); every command emitted for an instruction in block [B] is
   wrapped with an [execute if/unless] prefix composed from that chain, so
   the driver does not need to maintain a runtime guard stack. *)

open Cfg
open Codegen_helpers

(* Build the [execute ... ] prefix for a guard chain. Returns the empty
   string when the chain is empty, otherwise a string that ends in a single
   trailing space and does NOT include the terminating [run ]. Emission
   sites decide whether to append [run <inner>] or emit [inner] verbatim. *)
let build_guard_prefix (gs : (vreg * polarity) list) : string =
  if gs = [] then ""
  else begin
    let buf = Buffer.create 64 in
    Buffer.add_string buf "execute ";
    List.iter
      (fun (c, p) ->
        let kw = match p with Pos -> "if" | Neg -> "unless" in
        Buffer.add_string buf
          (Printf.sprintf "%s score %s %s matches 1 " kw c obj_name))
      gs;
    Buffer.contents buf
  end

(* Wrap a raw inner command with a pre-built guard prefix. When the inner
   command itself starts with [execute ], Minecraft's chained [execute]
   form handles nesting: [execute if ... run execute store ...] is valid
   and is exactly how the legacy codegen currently emits guarded array
   reads. We always just concat [prefix ^ "run " ^ inner]. *)
let wrap_cmd (prefix : string) (inner : string) : string =
  if prefix = "" then inner
  else prefix ^ "run " ^ inner

(* ---- per-instruction lowering ---- *)

(* Mutable state that [emit] threads through the block walk. All of it is
   local to a single [emit] call; nothing persists across calls. *)
type state = {
  cfg              : cfg_func;
  liveness         : Liveness.instr_liveness;
    (* re-computed at the start of [emit] over the post-regalloc CFG, so
       per_instr sets contain physical slot names. Used to compute the
       narrow save/restore set at each ICall. *)
  mutable main_cmds   : string list;      (* reversed; flipped at end *)
  mutable helpers     : (string * string list) list;  (* reversed *)
  mutable helper_ctr  : int;
  emitted_macros   : (aid, unit) Hashtbl.t;
  emitted_setters  : (aid, unit) Hashtbl.t;
  (* Phase A: per-pool shared-macro-helper usage. Set the first time a
     function emits an IHeapGet / IHeapSet for that pool. After the
     block walk finishes, [emit] appends one [<pool>_get.mcfunction] /
     [<pool>_set.mcfunction] pair per flagged pool. Multiple functions
     will each emit their own copy; [main.ml] dedupes [all_files] by
     filename before writing. *)
  mutable heap_get_pools : Ast.heap_pool list;
  mutable heap_set_pools : Ast.heap_pool list;
  (* Phase B: per-field cons macro helper usage. Set the first time a
     function emits an IHead / ITail. After the block walk, [emit]
     appends [cons_head.mcfunction] / [cons_tail.mcfunction] once per
     flagged field. Dedupe is by filename in main.ml. *)
  mutable emit_cons_head : bool;
  mutable emit_cons_tail : bool;
  (* Phase D / D5: ADT macro-getter usage. [emit_obj_tag] is set the
     first time an ITagGet fires; [obj_field_indices] collects the
     distinct field indices k for which an IFieldGet fired. After the
     block walk, [emit] appends [obj_tag.mcfunction] and one
     [obj_f<k>.mcfunction] per index. Dedupe is by filename in main.ml,
     same as cons_head/cons_tail. *)
  mutable emit_obj_tag : bool;
  mutable obj_field_indices : int list;
  (* Phase C: levels (k) for which IRegionExit fired in this function.
     After the block walk, [emit] appends the per-level truncation
     helpers [region_truncate_<k>_scratch.mcfunction] and
     [region_truncate_<k>_objpool.mcfunction] to [helpers]. Filename
     dedup in main.ml collapses the copies across functions. *)
  mutable region_exit_levels : int list;
  (* Phase C / C5: flagged when any IRegionExit with a TList return
     type fires in this function. Triggers emission of the shared
     level-independent stash/rebuild walker files — the walkers call
     cons_head / cons_tail internally, so emit_cons_head /
     emit_cons_tail are also flagged when this is set. *)
  mutable emit_region_walker_list : bool;
  (* Phase F / F5: whole-program closure-shape table (fname -> code),
     computed once in main.ml right after Closure_spec.run and threaded
     down through Codegen.compile_cfg_to_files. Only consulted by
     IClosureMake's lowering (to embed the right `code:<N>` in the cell
     literal); IApply's lowering never needs it — it dispatches through
     the shared mcaml:apply function, which reads $code from the cell
     itself at runtime. Defaults to Closure_layout.empty for callers
     that never construct a closure (every lookup would be dead code in
     that case, since no IClosureMake instruction could ever reach it). *)
  closure_layout : Closure_layout.t;
}

let fresh_helper_name (st : state) : string =
  st.helper_ctr <- st.helper_ctr + 1;
  Printf.sprintf "%s_call%d" st.cfg.fname st.helper_ctr

let ensure_macro_helper (st : state) (id : aid) : unit =
  if not (Hashtbl.mem st.emitted_macros id) then begin
    Hashtbl.add st.emitted_macros id ();
    let helper_name = Printf.sprintf "%s_get" id in
    st.helpers <- (helper_name, [macro_helper_body id]) :: st.helpers
  end

let ensure_macro_setter (st : state) (id : aid) : unit =
  if not (Hashtbl.mem st.emitted_setters id) then begin
    Hashtbl.add st.emitted_setters id ();
    let helper_name = Printf.sprintf "%s_set" id in
    st.helpers <- (helper_name, [macro_setter_body id]) :: st.helpers
  end

let push_cmd (st : state) (prefix : string) (inner : string) : unit =
  st.main_cmds <- wrap_cmd prefix inner :: st.main_cmds

let push_cmds (st : state) (prefix : string) (cmds : string list) : unit =
  List.iter (fun c -> push_cmd st prefix c) cmds

(* Reserved-vreg predicate for filtering save/restore sets. We never save
   reserved slots: $ret carries the return value (and is overwritten by
   the call anyway), $arr_result is a transient scratch slot used by macro
   helpers, and param_N is set per-call so its old value is meaningless.
   This is [Cfg.is_reserved] ($ret, $arr_result, $tick_iters, $ref_*,
   strict param_N) extended with codegen-only runtime slots. *)
let is_reserved_slot (s : string) : bool =
  Cfg.is_reserved s ||
  s = "$scratch_next" || s = "$permheap_next" || s = "$objpool_next" ||
  s = "$arr_idx" ||
  (* Phase C §4.1: region save slots, one pair per nesting level
     (permheap intentionally not snapshotted per §4.4). v1 caps at
     4 levels (k ∈ [0,3]); cfg_build fails loudly above that. *)
  s = "$region_save_0_scratch" || s = "$region_save_0_objpool" ||
  s = "$region_save_1_scratch" || s = "$region_save_1_objpool" ||
  s = "$region_save_2_scratch" || s = "$region_save_2_objpool" ||
  s = "$region_save_3_scratch" || s = "$region_save_3_objpool" ||
  (* C5 deep-copy walker scratch slots (shared across levels). *)
  s = "$wr_h" || s = "$wr_cache_h" || s = "$wr_prev" || s = "$wr_tmp_h" ||
  (* Phase N / N6: Q16.16 fmul scratch. $c256 holds the literal 256 so
     the pre-shift lowering can use `/=` against a scoreboard operand
     (scoreboard-operation has no immediate-int form). $fmul_t is the
     destructible scratch copy of the second operand so v2 stays live
     for any consumer after the FMult instruction. *)
  s = "$c256" || s = "$fmul_t" ||
  (* Phase F / F5: apply-dispatch scratch. $code holds the closure
     cell's shape discriminant during mcaml:apply's dispatch; the
     $apply_arg_* bank stages a call site's own (non-captured)
     arguments ahead of the runtime-resolved capture-count offset (see
     codegen_helpers.ml's cmd_apply / apply_dispatch_trampoline_body
     doc comments). Prefix-matched like $ref_ below since the count is
     a whole-program constant (K_max_apply_args) sized by
     closure_layout.ml, not a small fixed set like the region levels. *)
  s = "$code" ||
  (String.length s >= 11 && String.sub s 0 11 = "$apply_arg_")

(* Compute the slots that must be saved across an ICall at position [i] in
   block [b]. Equals [live_after(b, i) \ {dest_of_call} \ reserved_slots].
   The dest is excluded because the call's $ret value will overwrite it
   immediately after the helper returns; saving the old value is wasted
   work. Reserved slots are excluded because their semantics is managed
   elsewhere. The result is sorted alphabetically so the helper file's
   field-name assignments are deterministic across runs. *)
let slots_live_across_call
    (st : state) (b : block) (i : int) (d_opt : vreg option) : string list =
  let live_after = st.liveness.Liveness.per_instr.(b.label).(i) in
  let live = match d_opt with
    | Some d -> Liveness.VSet.remove d live_after
    | None -> live_after
  in
  Liveness.VSet.fold
    (fun s acc -> if is_reserved_slot s then acc else s :: acc)
    live []
  |> List.sort compare

(* Lower a single instruction to zero or more guarded commands and append
   them to [st.main_cmds]. [prefix] is the guard-chain prefix for the
   containing block. [b] and [i] are the containing block and the
   instruction's index within it; needed only for ICall to look up the
   live-across set. *)
let emit_instr (st : state) (prefix : string) (b : block) (i : int) (instr : instr) : unit =
  match instr with
  | IConst (d, k) ->
      push_cmd st prefix (cmd_score_set d k)
  | ICopy (d, s) when d = s ->
      ()                                (* self-copy elided *)
  | ICopy (d, s) ->
      push_cmd st prefix (cmd_score_copy d s)
  | ICommand s ->
      push_cmd st prefix s
  | IBinOp (d, op, a, b') ->
      push_cmds st prefix (cmd_score_binop d op a b')
  | ICall (d_opt, f, args) ->
      let slots = slots_live_across_call st b i d_opt in
      if slots = [] then begin
        (* Direct call: no slots live across the call (either because nothing
           is live downstream or because the only thing live IS the call's
           dest, which we don't need to save). Emit param sets + function
           call inline; no helper file. *)
        push_cmds st prefix (cmd_tail_jump f args);
        (match d_opt with
         | Some d when d <> "$ret" ->
             push_cmd st prefix (cmd_score_copy d "$ret")
         | _ -> ())
      end else begin
        let helper = fresh_helper_name st in
        let helper_body = cmd_call_helper_body_narrow ~slots ~target:f ~args in
        st.helpers <- (helper, helper_body) :: st.helpers;
        push_cmd st prefix (Printf.sprintf "function mcaml:%s" helper);
        (match d_opt with
         | Some d when d <> "$ret" ->
             push_cmd st prefix (cmd_score_copy d "$ret")
         | _ -> ())
      end
  | IArrLitConst (id, ints) ->
      ensure_macro_helper st id;
      push_cmd st prefix (cmd_arr_lit_const id ints)
  | IArrLitDyn (id, temps) ->
      ensure_macro_helper st id;
      push_cmds st prefix (cmd_arr_lit_dyn id temps)
  | IArrGetStatic (d, id, k) ->
      ensure_macro_helper st id;
      push_cmd st prefix (cmd_arr_get_static d id k)
  | IArrGet (d, id, idx) ->
      ensure_macro_helper st id;
      push_cmds st prefix (cmd_arr_get d id idx)
  | IArrSetStatic (id, k, v) ->
      push_cmd st prefix (cmd_arr_set_static id k v)
  | IArrSet (id, idx, v) ->
      ensure_macro_setter st id;
      push_cmds st prefix (cmd_arr_set id idx v)
  | IHeapAllocConst (d, p, n) ->
      push_cmds st prefix (cmd_heap_alloc_const d p n)
  | IHeapGet (d, p, base, idx) ->
      if not (List.mem p st.heap_get_pools) then
        st.heap_get_pools <- p :: st.heap_get_pools;
      push_cmds st prefix (cmd_heap_get d p base idx)
  | IHeapSet (p, base, idx, v) ->
      if not (List.mem p st.heap_set_pools) then
        st.heap_set_pools <- p :: st.heap_set_pools;
      push_cmds st prefix (cmd_heap_set p base idx v)
  | IHeapAlloc _ ->
      failwith
        "codegen_cfg: runtime-n Array.make (IHeapAlloc vreg-form) not \
         yet implemented — use Array.make(<int-literal>, 0)"
  | IClosureMake (d, fname, caps) ->
      let code = Closure_layout.code_of st.closure_layout fname in
      push_cmds st prefix (cmd_closure_make d code caps)
  | IApply (d_opt, cl, args) ->
      (* Same save/restore obligation as ICall (§7 above): physical
         scoreboard slots are one flat global namespace, so dispatching
         through mcaml:apply into an arbitrary lifted lambda helper can
         clobber any of THIS function's other live slots exactly like an
         ordinary function call can — the lambda helper has no idea it's
         being invoked via apply and freely reuses $r0, $r1, ... for its
         own locals. Missing this save/restore was caught empirically:
         a self-tail loop forwarding a captured closure across its own
         back-edge silently clobbered the carried closure handle on the
         second iteration (a real bug found and fixed while adding F5's
         escaping-shape test coverage, not a hypothetical). *)
      let slots = slots_live_across_call st b i d_opt in
      if slots = [] then
        push_cmds st prefix (cmd_apply cl args)
      else begin
        let helper = fresh_helper_name st in
        let helper_body = cmd_apply_helper_body ~slots ~cl ~args in
        st.helpers <- (helper, helper_body) :: st.helpers;
        push_cmd st prefix (Printf.sprintf "function mcaml:%s" helper)
      end;
      (match d_opt with
       | Some d when d <> "$ret" ->
           push_cmd st prefix (cmd_score_copy d "$ret")
       | _ -> ())
  | ICons (d, h, t) ->
      push_cmds st prefix (cmd_cons d h t)
  | IHead (d, c) ->
      st.emit_cons_head <- true;
      push_cmds st prefix (cmd_cons_head d c)
  | ITail (d, c) ->
      st.emit_cons_tail <- true;
      push_cmds st prefix (cmd_cons_tail d c)
  | IAdtAlloc (d, tag, args) ->
      push_cmds st prefix (cmd_adt_alloc d tag args)
  | ITagGet (d, c) ->
      st.emit_obj_tag <- true;
      push_cmds st prefix (cmd_obj_tag_get d c)
  | IFieldGet (d, c, k) ->
      if not (List.mem k st.obj_field_indices) then
        st.obj_field_indices <- k :: st.obj_field_indices;
      push_cmds st prefix (cmd_obj_field_get d c k)
  | IRegionEnter k ->
      push_cmds st prefix (cmd_region_enter k)
  | IRegionExit (k, ret, ret_typ) ->
      if not (List.mem k st.region_exit_levels) then
        st.region_exit_levels <- k :: st.region_exit_levels;
      (* Dispatch on the return type from cfg_build. Primitive returns
         use the 2-command C4 path; TList TInt returns run the stash+
         truncate+rebuild Strategy-B walker from C5; other heap types
         are not supported in v1 and fail loudly. *)
      (match ret_typ with
       | Ast.TInt | Ast.TBool | Ast.TUnit ->
           push_cmds st prefix (cmd_region_exit_primitive k)
       | Ast.TList Ast.TInt ->
           (match ret with
            | None ->
                failwith
                  "codegen_cfg: TList region exit has no return vreg \
                   (cfg_build invariant violated)"
            | Some r ->
                st.emit_region_walker_list <- true;
                (* Walker body calls cons_head / cons_tail to read
                   child cells, so those macro helpers must also be
                   emitted in this function's helper set. *)
                st.emit_cons_head <- true;
                st.emit_cons_tail <- true;
                push_cmds st prefix (cmd_region_exit_list_int k r))
       | Ast.TArrDyn _ ->
           failwith
             "codegen_cfg: TArrDyn region returns are not supported in \
              v1 — wrap the array-producing expression with an int-\
              returning reducer or flag to extend the walker set"
       | Ast.TAdt (name, _) ->
           (* Phase D / D5 settled decision: no generic tag-preserving
              deep-copy walker yet. Same v1 posture as TArrDyn. *)
           failwith
             (Printf.sprintf
                "codegen_cfg: region returns of ADT values (type %s) \
                 are not supported in v1 — reduce to a primitive \
                 inside the region or flag to extend the walker set"
                name)
       | _ ->
           failwith
             (Printf.sprintf
                "codegen_cfg: region return type %s has no v1 walker"
                (match ret_typ with
                 | Ast.TList _ -> "TList <nested>"
                 | Ast.TArrStatic _ -> "TArrStatic"
                 | Ast.TMat _ -> "TMat"
                 | Ast.TRef _ -> "TRef"
                 | Ast.TTuple _ -> "TTuple"
                 | _ -> "<unknown>")))

(* Lower a terminator. Only [TTail] produces commands; the others are
   structural and get emitted as nothing.

   Self-tail retargeting (M4 §2 LICM split). When the function has a
   non-empty [preheader_instrs] list, codegen splits it into a wrapper
   file [<fname>.mcfunction] and a body file [<fname>__body.mcfunction]
   (see [emit] below). [TTail (fname, _)] re-entries inside the body
   must skip the wrapper's hoisted preheader code, so we retarget them
   to [<fname>__body]. External callers that issue [function
   mcaml:<fname>] still hit the wrapper, which runs the preheader once
   and then dispatches to the body. *)
let emit_term (st : state) (prefix : string) (t : terminator) : unit =
  match t with
  | TRet | TJump _ | TBranch _ | TUnreachable -> ()
  | TTail (f, args) ->
      let target =
        if f = st.cfg.fname && st.cfg.preheader_instrs <> []
        then f ^ "__body"
        else f
      in
      (* The dispatch itself is emitted as `return run function …`, NOT a
         bare `function …`. A bare dispatch does not terminate this
         function: when the callee returns, Minecraft resumes at the next
         line of THIS file — the other match arms / merge blocks that
         follow the tail dispatch in emission order. Those lines are
         guarded by conds whose physical slots the callee just clobbered
         (a TTail has no save/restore helper by design), so they can
         re-execute with stale truth values and corrupt $ret or any slot
         they write (observed: count_leaves_tco under MCAML_NO_M3A
         returned 2 instead of 5; optimized builds survived only because
         their exit arms happened to be idempotent under re-execution).
         `return run` (MC 1.20.5+, same baseline as tick_guard's
         `return 0`) makes the dispatch atomically terminate the caller
         frame, which also stops mid-loop tick_guard yields from
         replaying every ancestor's exit arm during unwind. *)
      let cmds =
        match List.rev (cmd_tail_jump target args) with
        | dispatch :: rest_rev ->
            List.rev (("return run " ^ dispatch) :: rest_rev)
        | [] -> []
      in
      push_cmds st prefix cmds

(* ---- block walk ---- *)

let emit_block (st : state) (b : block) : unit =
  if block_is_reachable st.cfg b then begin
    let prefix = build_guard_prefix b.guards in
    List.iteri (fun i instr -> emit_instr st prefix b i instr) b.instrs;
    emit_term st prefix b.term
  end

(* ---- entry point ---- *)

let emit ?(closure_layout = Closure_layout.empty) (cfg : cfg_func) : (string * string list) list =
  let liveness = Liveness.analyze cfg in
  let st = {
    cfg;
    liveness;
    main_cmds   = [];
    helpers     = [];
    helper_ctr  = 0;
    emitted_macros = Hashtbl.create 8;
    emitted_setters = Hashtbl.create 8;
    heap_get_pools = [];
    heap_set_pools = [];
    emit_cons_head = false;
    emit_cons_tail = false;
    emit_obj_tag = false;
    obj_field_indices = [];
    region_exit_levels = [];
    emit_region_walker_list = false;
    closure_layout;
  } in
  let order = reverse_postorder cfg in
  List.iter (fun l -> emit_block st cfg.blocks.(l)) order;
  (* Phase A: append per-pool shared macro helpers whose usage this
     function flagged. Filename is [<pool>_get] / [<pool>_set] — identical
     across functions, so main.ml dedupes all_files by filename before
     writing. *)
  List.iter (fun p ->
    let name = Printf.sprintf "%s_get" (pool_name p) in
    st.helpers <- (name, [pool_get_body p]) :: st.helpers
  ) st.heap_get_pools;
  List.iter (fun p ->
    let name = Printf.sprintf "%s_set" (pool_name p) in
    st.helpers <- (name, [pool_set_body p]) :: st.helpers
  ) st.heap_set_pools;
  (* Phase B: per-field cons macro helpers. Filename is global ([cons_head]
     / [cons_tail]), so main.ml's filename dedupe collapses the multiple
     copies produced across functions. *)
  if st.emit_cons_head then
    st.helpers <- ("cons_head", [cons_head_body]) :: st.helpers;
  if st.emit_cons_tail then
    st.helpers <- ("cons_tail", [cons_tail_body]) :: st.helpers;
  (* Phase D / D5: ADT macro getters — one obj_tag plus one obj_f<k>
     per distinct field index this function read. Filenames are global
     so main.ml's dedupe collapses copies across functions. *)
  if st.emit_obj_tag then
    st.helpers <- ("obj_tag", [obj_tag_body]) :: st.helpers;
  List.iter (fun k ->
    st.helpers <-
      (Printf.sprintf "obj_f%d" k, [obj_field_body k]) :: st.helpers
  ) (List.sort compare st.obj_field_indices);
  (* Phase C: per-level truncation helpers, one scratch and one
     objpool helper per level observed in this function. Filenames
     are global so main.ml's filename dedupe collapses copies from
     multiple functions sharing the same levels. *)
  List.iter (fun k ->
    let sname = Printf.sprintf "region_truncate_%d_scratch" k in
    let cname = Printf.sprintf "region_truncate_%d_objpool" k in
    st.helpers <- (sname, region_truncate_scratch_body k) :: st.helpers;
    st.helpers <- (cname, region_truncate_objpool_body k) :: st.helpers
  ) st.region_exit_levels;
  (* Phase C / C5: TList-return walker helpers. Level-independent —
     the stash walker walks the child chain and the rebuild walker
     empties region_tmp objpool into the parent objpool, neither
     referencing the per-level save slots. Single shared filename
     per walker, deduped across all functions by main.ml. *)
  if st.emit_region_walker_list then begin
    st.helpers <-
      ("region_walker_list_stash", region_walker_list_stash_body) :: st.helpers;
    st.helpers <-
      ("region_walker_list_rebuild", region_walker_list_rebuild_body) :: st.helpers
  end;
  let body_cmds = List.rev st.main_cmds in
  if cfg.preheader_instrs = [] then
    (cfg.fname, body_cmds) :: List.rev st.helpers
  else begin
    (* M4 §2 LICM split. Emit the hoisted preheader instructions into a
       fresh wrapper file [<fname>.mcfunction] that ends in a function
       call to [<fname>__body], then emit the actual function body into
       [<fname>__body.mcfunction]. The wrapper has an empty guard chain
       (it's the function entry by definition). The dummy block argument
       is unused — emit_instr only consults [b]/[i] for ICall, which v1
       LICM never hoists. *)
    st.main_cmds <- [];
    let dummy_block = make_block (-1) in
    List.iteri (fun i instr ->
      emit_instr st "" dummy_block i instr) cfg.preheader_instrs;
    let wrapper_cmds = List.rev st.main_cmds in
    let body_name = cfg.fname ^ "__body" in
    let wrapper_full =
      wrapper_cmds @ [Printf.sprintf "function mcaml:%s" body_name]
    in
    (cfg.fname, wrapper_full)
    :: (body_name, body_cmds)
    :: List.rev st.helpers
  end
