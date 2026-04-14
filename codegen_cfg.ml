(* codegen_cfg.ml — CFG-driven code generator (Milestone 2, §7).

   Consumes a post-regalloc [Cfg.cfg_func] and produces the same
   [(mcfunction_name, commands)] list shape as the legacy
   [Codegen.compile_def]. The first pair is the top-level function body; the
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
   helpers, and param_N is set per-call so its old value is meaningless. *)
let is_reserved_slot (s : string) : bool =
  s = "$ret" || s = "$arr_result" || s = "$tick_iters" ||
  s = "$scratch_next" || s = "$permheap_next" || s = "$conspool_next" ||
  s = "$arr_idx" ||
  (String.length s >= 5 && String.sub s 0 5 = "$ref_") ||
  (String.length s > 6
   && String.sub s 0 6 = "param_"
   && let suf = String.sub s 6 (String.length s - 6) in
      suf <> "" && String.for_all (function '0'..'9' -> true | _ -> false) suf)

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
      push_cmds st prefix (cmd_tail_jump target args)

(* ---- block walk ---- *)

(* A block is "reachable for emission" iff it is the entry block or has at
   least one predecessor. This also rules out [TUnreachable]-bodied merge
   blocks left behind when both branches of a KIf tail-call out (e.g.,
   [relu_loop]). *)
let block_is_reachable (cfg : cfg_func) (b : block) : bool =
  b.label = cfg.entry || b.preds <> []

(* Reverse postorder from [cfg.entry]. Follows [Cfg.succs]; the merge label
   on a [TBranch] is NOT a successor edge of the branch block itself (it's
   reached via the then/else arms' own terminators), so DFS naturally
   linearizes the branch structure with then-side, else-side, merge-side
   ordering. *)
let reverse_postorder (cfg : cfg_func) : label list =
  let visited = Hashtbl.create (Array.length cfg.blocks) in
  let post = ref [] in
  let rec dfs (l : label) : unit =
    if not (Hashtbl.mem visited l) then begin
      Hashtbl.add visited l ();
      let b = cfg.blocks.(l) in
      List.iter dfs (succs b.term);
      post := l :: !post
    end
  in
  dfs cfg.entry;
  (* [post] is currently in reverse-postorder already because we prepended
     each node after visiting its successors — that's postorder accumulated
     in reverse, which is exactly RPO. *)
  !post

let emit_block (st : state) (b : block) : unit =
  if block_is_reachable st.cfg b then begin
    let prefix = build_guard_prefix b.guards in
    List.iteri (fun i instr -> emit_instr st prefix b i instr) b.instrs;
    emit_term st prefix b.term
  end

(* ---- entry point ---- *)

let emit (cfg : cfg_func) : (string * string list) list =
  let liveness = Liveness.analyze cfg in
  let st = {
    cfg;
    liveness;
    main_cmds   = [];
    helpers     = [];
    helper_ctr  = 0;
    emitted_macros = Hashtbl.create 8;
    emitted_setters = Hashtbl.create 8;
  } in
  let order = reverse_postorder cfg in
  List.iter (fun l -> emit_block st cfg.blocks.(l)) order;
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
