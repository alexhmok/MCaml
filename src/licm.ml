(* licm.ml — Loop Invariant Code Motion (M4 §2).

   v1 scope. Hoists [IArrLitConst] (and [IArrLitDyn] when its temp
   operands are loop-invariant) out of every TCO'd self-recursive loop
   in the function. The plan §2 lists IConst/ICopy/IBinOp as also
   safe-to-hoist, but those have vreg destinations and would need
   regalloc to see them — which today only walks [cfg.blocks], not
   [cfg.preheader_instrs]. v1 deliberately restricts hoisting to
   no-vreg-destination instructions so the existing regalloc pass is
   unchanged. The IArrLitConst case is the standalone biggest LICM win
   the M1 stress tests flagged: e.g., dot4_loop's two array literal
   inits run N times today; after LICM they run once.

   Loop scope. Only loops whose header is the function entry block
   (i.e., TCO'd self-recursive loops produced by [tco.ml] from
   [for_lift.ml]'s helpers and from hand-written tail calls) are
   handled. These have no in-CFG entry edges to redirect, so we cannot
   construct a real preheader block in the CFG. Instead the hoisted
   instructions accumulate in [cfg.preheader_instrs] and codegen emits
   them in a wrapper file [<fname>.mcfunction] that runs once and then
   dispatches to [<fname>__body.mcfunction] (the body file). The body's
   [TTail (fname, _)] re-entries are retargeted to [<fname>__body] so
   they skip the hoisted code. See [codegen_cfg.ml] for the split.

   Soundness checks for v1 hoisting (only [IArrLit*]):
     - The header block has an empty guard chain. (True for the
       function entry by construction; we still assert it.)
     - The aid is not initialized by another instruction in the loop.
       Knormal mints unique aids per literal, so this is structurally
       guaranteed inside one function — but we still verify defensively
       by counting [IArrLit*] instructions per aid in the loop body.
     - For [IArrLitDyn], every temp it reads is defined OUTSIDE the
       loop (i.e., the values are loop-invariant). *)

open Cfg

(* Map: aid -> count of [IArrLit*] writes for that aid in the loop body. *)
let collect_arr_writes (cfg : cfg_func) (body : label list) : (aid, int) Hashtbl.t =
  let tbl = Hashtbl.create 8 in
  let bump id =
    let n = try Hashtbl.find tbl id with Not_found -> 0 in
    Hashtbl.replace tbl id (n + 1)
  in
  List.iter (fun l ->
    let b = cfg.blocks.(l) in
    List.iter (fun i ->
      match i with
      | IArrLitConst (id, _) | IArrLitDyn (id, _) -> bump id
      | _ -> ())
    b.instrs
  ) body;
  tbl

(* Set of vregs defined anywhere in the loop body. *)
let collect_loop_defs (cfg : cfg_func) (body : label list)
  : (vreg, unit) Hashtbl.t =
  let tbl = Hashtbl.create 16 in
  List.iter (fun l ->
    let b = cfg.blocks.(l) in
    List.iter (fun i ->
      match instr_def i with
      | Some d -> Hashtbl.replace tbl d ()
      | None -> ())
    b.instrs
  ) body;
  tbl

let movable_v1 (defs : (vreg, unit) Hashtbl.t)
    (writes : (aid, int) Hashtbl.t) (i : instr) : bool =
  match i with
  | IArrLitConst (id, _) ->
      (try Hashtbl.find writes id with Not_found -> 0) = 1
  | IArrLitDyn (id, temps) ->
      (try Hashtbl.find writes id with Not_found -> 0) = 1
      && List.for_all (fun u -> not (Hashtbl.mem defs u)) temps
  | _ -> false

let run_on_loop (cfg : cfg_func) (loop : Loop_detect.loop) : bool =
  if loop.header <> cfg.entry then false
  else begin
    let header_block = cfg.blocks.(loop.header) in
    if header_block.guards <> [] then false
    else begin
      let body = List.sort compare loop.body in
      let defs = collect_loop_defs cfg body in
      let writes = collect_arr_writes cfg body in
      let any_moved = ref false in
      let hoisted_acc : instr list ref = ref [] in
      List.iter (fun l ->
        let b = cfg.blocks.(l) in
        let kept = ref [] in
        List.iter (fun instr ->
          if movable_v1 defs writes instr then begin
            hoisted_acc := instr :: !hoisted_acc;
            any_moved := true
          end else
            kept := instr :: !kept
        ) b.instrs;
        b.instrs <- List.rev !kept
      ) body;
      if !any_moved then
        cfg.preheader_instrs <-
          cfg.preheader_instrs @ List.rev !hoisted_acc;
      !any_moved
    end
  end

let run (cfg : cfg_func) : bool =
  let idom = Dominators.compute cfg in
  let loops = Loop_detect.find_loops cfg idom in
  (* Innermost first; [find_loops] already sorts that way. *)
  List.fold_left
    (fun acc l -> let r = run_on_loop cfg l in r || acc)
    false loops
