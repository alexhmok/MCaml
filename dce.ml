(* dce.ml — Dead code elimination using liveness.

   Part of the M3a local optimization set. Runs liveness once, then walks
   each block and drops any instruction whose def is not live after the
   instruction, provided the instruction has no side effects. Self-copies
   (ICopy(d, d)) are dropped unconditionally — they are structurally
   no-ops regardless of liveness.

   Liveness handles guard-chain pinning internally, so DCE does not need
   to worry about guard conds being removed: any vreg appearing in a
   block's guards list is live at every instruction in that block.

   Reserved vregs ($ret, $arr_result, param_N) are never removed —
   their writes have extrinsic meaning (read by caller/callee). *)

open Cfg

(* Mirror of regalloc_cfg.ml / liveness.ml's is_reserved, kept local for
   module decoupling. *)
let is_reserved (n : string) : bool =
  n = "$ret" || n = "$arr_result" || n = "$tick_iters" ||
  (String.length n >= 5 && String.sub n 0 5 = "$ref_") ||
  (String.length n > 6
   && String.sub n 0 6 = "param_"
   && let suf = String.sub n 6 (String.length n - 6) in
      suf <> "" && String.for_all (function '0'..'9' -> true | _ -> false) suf)

(* An instruction is "side-effecting" if removing it would change program
   behavior even when its def is not live downstream.

   - ICommand: raw Minecraft command, arbitrary world effect.
   - ICall:    function may have side effects regardless of result use.
   - IArrLitConst / IArrLitDyn: write to storage (observable).
   - IArrGet / IArrGetStatic: conservatively kept — they read storage and
     have a hidden $arr_result write documented in cfg.ml. A dedicated
     dead-store / dead-load pass for arrays is M4+.

   Safely removable when dead: IConst, ICopy, IBinOp. *)
let is_side_effecting (i : instr) : bool =
  match i with
  | ICommand _ | ICall _
  | IArrLitConst _ | IArrLitDyn _
  | IArrGetStatic _ | IArrGet _
  | IArrSetStatic _ | IArrSet _
  (* Dynamic-heap ops are all side-effecting per §3.7: IHeapAlloc bumps
     the pool counter, IHeapSet writes NBT, IHeapGet mirrors IArrGet's
     hidden $arr_result write through its macro helper. None may be DCE'd. *)
  | IHeapAllocConst _ | IHeapAlloc _ | IHeapGet _ | IHeapSet _
  (* Phase B cons ops: ICons bumps $objpool_next and writes NBT;
     IHead/ITail read NBT through per-field macro helpers with the
     same hidden $arr_result write as IArrGet. All three kept. *)
  | ICons _ | IHead _ | ITail _
  (* Phase D ADT ops: IAdtAlloc bumps $objpool_next and writes NBT;
     ITagGet/IFieldGet read NBT through macro helpers with the same
     hidden $arr_result write as IArrGet. All three kept. *)
  | IAdtAlloc _ | ITagGet _ | IFieldGet _
  (* Phase C region brackets: IRegionEnter snapshots global scoreboard
     slots, IRegionExit truncates NBT pools and restores counters. Both
     are the entire region mechanism — DCE may not touch either. *)
  | IRegionEnter _ | IRegionExit _ -> true
  (* Phase F closure ops. IApply calls through a runtime value that may
     run arbitrary code regardless of whether its result is read — same
     posture as ICall, never DCE'd. IClosureMake commits to no runtime
     representation at this IR level (real allocation, if any, is
     decided by F5's codegen for whatever survives to see it) — a
     construction whose result is never read really is dead code, so it
     is safe to drop like IBinOp/ICopy. This is what makes a Known
     lambda's specialization (closure_spec.ml rewrites its consuming
     IApply to an ordinary ICall, dropping the last use) actually
     zero-cost: the abandoned IClosureMake gets removed here for free. *)
  | IApply _ -> true
  | IConst _ | ICopy _ | IBinOp _ | IClosureMake _ -> false

let run (cfg : cfg_func) : bool =
  let liveness = Liveness.analyze cfg in
  let changed = ref false in
  Array.iter (fun (b : block) ->
    let per_instr = liveness.Liveness.per_instr.(b.label) in
    (* per_instr has length (num_instrs + 1); per_instr.(i) for
       i in [0, num_instrs-1] is the set of vregs live AFTER instr i
       finishes. That is exactly the "is the def used downstream?"
       question we want to ask. *)
    let kept = ref [] in
    List.iteri (fun i instr ->
      let drop =
        match instr with
        | ICopy (d, s) when d = s ->
            (* Self-copies are structural no-ops: they write the same
               value they read. Always safe to remove, regardless of
               what liveness says about d. *)
            true
        | _ ->
            if is_side_effecting instr then false
            else begin
              match instr_def instr with
              | None -> false
              | Some d ->
                  if is_reserved d then false
                  else not (Liveness.VSet.mem d per_instr.(i))
            end
      in
      if drop then changed := true
      else kept := instr :: !kept
    ) b.instrs;
    b.instrs <- List.rev !kept
  ) cfg.blocks;
  !changed
