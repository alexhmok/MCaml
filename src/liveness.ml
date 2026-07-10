(* liveness.ml — Iterative backward dataflow liveness for the CFG IR.

   Consumed by regalloc_cfg.ml (per-instruction live_after) and by future
   optimization passes (per-block live_in/live_out).

   Key correctness subtlety: the guard-chain pinning described in
   §5 "The KIf cond liveness trap" of the M2 plan. Each block B carries a
   [guards] list — (cond, polarity) pairs — that codegen will use to wrap
   every emitted command in `execute if/unless score <cond> matches 1 run`.
   Those cond vregs are implicitly read by every instruction in B even
   though they don't appear in instr_uses. Liveness augments use(i) with
   those conds *per instruction and at the terminator*, so that a mid-block
   def of an unrelated temp does not "kill" pinning through the hole.

   Reserved vregs ($ret, $arr_result, param_N) are excluded from liveness
   entirely — they don't appear in use/def sets, don't propagate, and are
   identity-mapped by regalloc. *)

module VSet = Set.Make (String)

type block_liveness = {
  live_in  : VSet.t;
  live_out : VSet.t;
}

type instr_liveness = {
  per_block : block_liveness array;
  per_instr : VSet.t array array;
    (* per_instr.(lbl).(i) is the set of vregs live immediately AFTER
       instruction i finishes executing (equivalently: at the start of
       instruction i+1). per_instr.(lbl).(num_instrs) is the set live
       just before the terminator executes. Length is (num_instrs + 1). *)
}

let is_reserved = Cfg.is_reserved

let add_if_tracked (v : Cfg.vreg) (s : VSet.t) : VSet.t =
  if is_reserved v then s else VSet.add v s

let vset_of_list (vs : Cfg.vreg list) : VSet.t =
  List.fold_left (fun s v -> add_if_tracked v s) VSet.empty vs

(* Transfer function for a single def/use step:
     live := (live \ {def?}) ∪ use
   def is removed BEFORE use is added (a read-write in the same instr still
   keeps the operand live across the def — a read of v before the same
   instr's def of v means v is live-in to the instr). *)
let step (live : VSet.t) (def : Cfg.vreg option) (use : VSet.t) : VSet.t =
  let live' = match def with
    | Some d when not (is_reserved d) -> VSet.remove d live
    | _ -> live
  in
  VSet.union live' use

let reverse_postorder = Cfg.reverse_postorder

(* Use set of an instruction/terminator with the block's guard pins
   added — guard-chain pinning treats every guard cond as an implicit
   use at every step (see the header comment). *)
let use_with_pin (pin : VSet.t) (uses : Cfg.vreg list) : VSet.t =
  VSet.union (vset_of_list uses) pin

(* ---- main analysis ---- *)
let analyze (cfg : Cfg.cfg_func) : instr_liveness =
  let n = Array.length cfg.blocks in

  (* Per-block pinned set from guard chain. *)
  let pinned : VSet.t array = Array.make n VSet.empty in
  Array.iter (fun (b : Cfg.block) ->
    let s =
      List.fold_left
        (fun acc (v, _pol) -> add_if_tracked v acc)
        VSet.empty b.guards
    in
    pinned.(b.label) <- s
  ) cfg.blocks;

  (* Per-block instruction/terminator use and def pre-computed once. *)
  let live_in  = Array.make n VSet.empty in
  let live_out = Array.make n VSet.empty in

  (* Backward transfer across a whole block: given live_out, compute live_in
     by walking terminator then instructions in reverse. Guard pinning is
     added at every step. *)
  let transfer (b : Cfg.block) (lout : VSet.t) : VSet.t =
    let pin = pinned.(b.label) in
    (* Terminator first. *)
    let term_use = use_with_pin pin (Cfg.term_uses b.term) in
    let live = step lout None term_use in
    (* Terminators never define a vreg; def is None. *)
    (* Walk instructions in reverse. b.instrs is in forward order post-seal. *)
    let rev_instrs = List.rev b.instrs in
    List.fold_left (fun live i ->
      step live (Cfg.instr_def i) (use_with_pin pin (Cfg.instr_uses i))
    ) live rev_instrs
  in

  (* Determine reachable blocks. *)
  let rpo = reverse_postorder cfg in
  let reachable = Array.make n false in
  List.iter (fun l -> reachable.(l) <- true) rpo;

  (* Worklist — iterate until fixed point. *)
  let in_worklist = Array.make n false in
  let worklist : int Queue.t = Queue.create () in
  List.iter (fun l ->
    Queue.push l worklist;
    in_worklist.(l) <- true
  ) rpo;

  while not (Queue.is_empty worklist) do
    let l = Queue.pop worklist in
    in_worklist.(l) <- false;
    let b = cfg.blocks.(l) in
    (* Only process reachable blocks. *)
    if reachable.(l) then begin
      let lout_new =
        List.fold_left (fun acc s ->
          VSet.union acc live_in.(s)
        ) VSet.empty (Cfg.succs b.term)
      in
      let lin_new = transfer b lout_new in
      if not (VSet.equal lin_new live_in.(l))
         || not (VSet.equal lout_new live_out.(l))
      then begin
        live_in.(l) <- lin_new;
        live_out.(l) <- lout_new;
        List.iter (fun p ->
          if p >= 0 && p < n && reachable.(p) && not in_worklist.(p) then begin
            Queue.push p worklist;
            in_worklist.(p) <- true
          end
        ) b.preds
      end
    end
  done;

  (* ---- Materialize per-instruction live_after sets. ---- *)
  let per_instr : VSet.t array array = Array.make n [||] in
  Array.iter (fun (b : Cfg.block) ->
    let l = b.label in
    let num_instrs = List.length b.instrs in
    let arr = Array.make (num_instrs + 1) VSet.empty in
    if reachable.(l) then begin
      let pin = pinned.(l) in
      (* Start from live_out[B]; transfer across terminator to get the set
         live just before the terminator — this is arr.(num_instrs). *)
      let term_use = use_with_pin pin (Cfg.term_uses b.term) in
      let live_at_term_in = step live_out.(l) None term_use in
      arr.(num_instrs) <- live_at_term_in;
      (* Walk instructions in reverse. For instr index i, arr.(i) is the
         set live AFTER instr i finishes — i.e. live at the start of
         instr i+1 (or at the terminator input when i = num_instrs - 1).

         Starting from `live = arr.(num_instrs)` (= live just before term
         = live after instr num_instrs-1), we assign arr.(i) <- live then
         transfer across instr i to compute what's live after instr i-1. *)
      let live = ref live_at_term_in in
      let rev_instrs = List.rev b.instrs in
      let i = ref (num_instrs - 1) in
      List.iter (fun instr ->
        arr.(!i) <- !live;
        live := step !live (Cfg.instr_def instr)
                  (use_with_pin pin (Cfg.instr_uses instr));
        decr i
      ) rev_instrs
      (* After the loop, !live should equal live_in.(l) (sanity — unchecked). *)
    end;
    per_instr.(l) <- arr
  ) cfg.blocks;

  let per_block =
    Array.init n (fun i ->
      { live_in = live_in.(i); live_out = live_out.(i) })
  in
  { per_block; per_instr }
