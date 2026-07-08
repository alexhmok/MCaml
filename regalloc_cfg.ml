(* regalloc_cfg.ml — Interval-based linear-scan register allocator over the
   CFG IR (Milestone 2).

   Contract: [alloc cfg] runs Liveness.analyze on [cfg], computes live ranges
   for every non-reserved vreg, assigns each a physical slot via linear scan,
   rewrites every operand (instruction uses/def, terminator uses, and block
   guard-chain conds) in place, and sets [cfg.slot_count] to the number of
   distinct physical slots minted.

   Encoding choice: dual-position. Each global instruction index [g] has two
   sub-positions, encoded as [2*g] (reads) and [2*g+1] (writes). Operand
   uses land on the even index, defs on the odd. This makes the
   "dest cannot share slot with rhs operand" rule fall out naturally:
   for an instruction at [g], operand [v2]'s last_use is at least [2*g]
   and dest [dest]'s first_def is [2*g+1], so [last_use[v2] >= 2*g >= ...]
   means [v2] is still in [active] when [dest] is allocated — it is
   not expired because expiry tests [end < first_def], i.e. the slot
   is only reclaimed when the previous occupant's last_use strictly
   precedes the new def's position. With last_use=2*g and first_def=2*g+1,
   [2*g < 2*g+1] so expiry *would* fire — we instead want the expiry to
   be [end < first_def - 0], meaning [<= 2*g] does NOT expire. Concretely
   we test [end <= first_def - 1] i.e. [end < first_def]: with end=2*g
   and first_def=2*g+1, that holds (2*g < 2*g+1), which would expire v2.
   Wrong!

   Fix: bump an operand read at instr [g] to last_use = 2*g+1 (same sub-
   position as the def). Then [end=2*g+1] is NOT strictly less than
   [first_def=2*g+1], so v2 is NOT expired when dest is allocated.
   For cross-instruction live ranges (v2 is also read later), this only
   tightens by one sub-tick and is still correct.

   Equivalently: use last_use = 2*g+1 for reads, first_def = 2*g+1 for
   writes at the same instruction. The shared sub-position means they
   coexist in [active] at allocation time, and [dest] picks from slots
   not held by [v2] (or any other operand). *)

module VSet = Liveness.VSet

(* ---- reserved-vreg predicate, copied from regalloc.ml ---- *)

let is_reserved (n : string) : bool =
  n = "$ret" || n = "$arr_result" || n = "$tick_iters" ||
  (String.length n >= 5 && String.sub n 0 5 = "$ref_") ||
  (String.length n > 6
   && String.sub n 0 6 = "param_"
   && let suf = String.sub n 6 (String.length n - 6) in
      suf <> "" && String.for_all (function '0'..'9' -> true | _ -> false) suf)

(* ---- reverse-postorder linearization ---- *)

let reverse_postorder (cfg : Cfg.cfg_func) : int list =
  let n = Array.length cfg.blocks in
  let visited = Array.make n false in
  let order = ref [] in
  let rec dfs l =
    if not visited.(l) then begin
      visited.(l) <- true;
      let b = cfg.blocks.(l) in
      List.iter dfs (Cfg.succs b.term);
      order := l :: !order
    end
  in
  dfs cfg.entry;
  !order  (* already in RPO since we prepend on post-visit *)

(* ---- main allocation pass ---- *)

let alloc (cfg : Cfg.cfg_func) : unit =
  let liveness = Liveness.analyze cfg in
  let nblocks = Array.length cfg.blocks in
  let rpo = reverse_postorder cfg in

  (* Step 1: assign every (block, instr_idx) position a global index.
     instr_idx ranges over [0 .. num_instrs] where num_instrs is the
     terminator slot. *)
  let pos_of : (int * int, int) Hashtbl.t = Hashtbl.create 256 in
  let block_start : int array = Array.make nblocks (-1) in
  let counter = ref 0 in
  List.iter (fun lbl ->
    let b = cfg.blocks.(lbl) in
    let num_instrs = List.length b.instrs in
    block_start.(lbl) <- !counter;
    for i = 0 to num_instrs do
      Hashtbl.add pos_of (lbl, i) !counter;
      incr counter
    done
  ) rpo;
  let global_idx lbl i = Hashtbl.find pos_of (lbl, i) in

  (* Step 2: compute (first_def, last_use) per non-reserved vreg.
     Using the dual-position encoding:
       - an operand read at global g has last_use := max(cur, 2*g + 1)
       - a def at global g has first_def := min(cur, 2*g + 1)
     (Reads and writes at the same instruction share the odd sub-position.
      Cross-instruction liveness still works because different gs give
      different parities/values, and the strict-less-than expiry check
      will expire a vreg whose last_use is earlier.) *)
  let first_def : (string, int) Hashtbl.t = Hashtbl.create 128 in
  let last_use  : (string, int) Hashtbl.t = Hashtbl.create 128 in
  let bump_use v p =
    if not (is_reserved v) then
      let cur = try Hashtbl.find last_use v with Not_found -> min_int in
      if p > cur then Hashtbl.replace last_use v p
  in
  let bump_def v p =
    if not (is_reserved v) then
      let cur = try Hashtbl.find first_def v with Not_found -> max_int in
      if p < cur then Hashtbl.replace first_def v p
  in
  let seen_use v p =
    if not (is_reserved v) then begin
      bump_use v p;
      (* Defensive: if this vreg is only ever read (never syntactically
         defined), ensure it has some first_def so linear scan picks it up.
         Well-formed CFG from cfg_build shouldn't hit this — param copies
         define every param vreg in the entry prelude — but be safe. *)
      if not (Hashtbl.mem first_def v) then
        Hashtbl.replace first_def v 0
    end
  in

  (* Walk every REACHABLE block: collect defs and syntactic uses from
     instrs/term, plus liveness-set pins at every sub-position. Unreachable
     blocks (block_start = -1) are skipped — they weren't linearized in RPO
     so they have no global positions, and their contents can't affect
     any live vreg anyway. *)
  Array.iter (fun (b : Cfg.block) ->
    let lbl = b.label in
    if block_start.(lbl) < 0 then () else
    let instrs_arr = Array.of_list b.instrs in
    let num_instrs = Array.length instrs_arr in
    (* Per-instruction pass: defs and uses. *)
    for i = 0 to num_instrs - 1 do
      let g = global_idx lbl i in
      let odd = 2 * g + 1 in
      let instr = instrs_arr.(i) in
      List.iter (fun v -> seen_use v odd) (Cfg.instr_uses instr);
      (match Cfg.instr_def instr with
       | Some d -> bump_def d odd
       | None -> ())
    done;
    (* Terminator at index num_instrs. *)
    let g_term = global_idx lbl num_instrs in
    List.iter (fun v -> seen_use v (2 * g_term + 1)) (Cfg.term_uses b.term);
    (* Liveness pins (prompt §Step 2): for each v in per_instr.(lbl).(i),
       bump last_use[v] to at least the global index of position i in B.
       Under dual encoding, use 2*g+1 so that a vreg live at position i
       stays active through instruction i's write sub-position. *)
    let per_instr_block = liveness.Liveness.per_instr.(lbl) in
    for i = 0 to num_instrs do
      let g = global_idx lbl i in
      let pos = 2 * g + 1 in
      VSet.iter (fun v -> bump_use v pos) per_instr_block.(i)
    done;
    (* Block-level live_in / live_out pins — anything in live_in is alive
       at the block's first sub-position; anything in live_out is alive
       at the terminator's sub-position. *)
    let bin = liveness.Liveness.per_block.(lbl) in
    let g_start = block_start.(lbl) in
    VSet.iter (fun v -> bump_use v (2 * g_start + 1)) bin.Liveness.live_in;
    (* Similarly, live_out: a vreg in live_out of B is alive at 2*g_term+1. *)
    VSet.iter (fun v -> bump_use v (2 * g_term + 1)) bin.Liveness.live_out
  ) cfg.blocks;

  (* Collect non-reserved vregs sorted by first_def. *)
  let vregs =
    Hashtbl.fold (fun v fd acc ->
      let lu = try Hashtbl.find last_use v with Not_found -> fd in
      (v, fd, lu) :: acc
    ) first_def []
  in
  let vregs = List.sort (fun (_, fd1, _) (_, fd2, _) -> compare fd1 fd2) vregs in

  (* Step 3: linear scan. *)
  let free_slots : string list ref = ref [] in
  let active : (string * int) list ref = ref [] in
  let next_id = ref 0 in
  let map : (string, string) Hashtbl.t = Hashtbl.create 128 in

  let expire (p : int) =
    let keep, gone = List.partition (fun (_, e) -> e >= p) !active in
    active := keep;
    List.iter (fun (v', _) ->
      match Hashtbl.find_opt map v' with
      | Some slot -> free_slots := slot :: !free_slots
      | None -> ()
    ) gone
  in
  let alloc_slot () =
    match !free_slots with
    | s :: rest -> free_slots := rest; s
    | [] ->
        let s = Printf.sprintf "$r%d" !next_id in
        incr next_id;
        s
  in

  List.iter (fun (v, fd, lu) ->
    expire fd;
    let slot = alloc_slot () in
    Hashtbl.replace map v slot;
    active := (v, lu) :: !active
  ) vregs;

  cfg.slot_count <- !next_id;

  (* Step 4: rewrite operands in place. *)
  let rw (v : string) : string =
    if is_reserved v then v
    else match Hashtbl.find_opt map v with
      | Some s -> s
      | None -> v
  in
  let rewrite_instr (i : Cfg.instr) : Cfg.instr =
    match i with
    | IConst (d, k) -> IConst (rw d, k)
    | ICopy (d, v) -> ICopy (rw d, rw v)
    | ICommand _ as x -> x
    | IBinOp (d, op, a, b) -> IBinOp (rw d, op, rw a, rw b)
    | ICall (d_opt, f, args) ->
        ICall ((match d_opt with Some d -> Some (rw d) | None -> None),
               f, List.map rw args)
    | IArrLitConst _ as x -> x
    | IArrLitDyn (id, temps) -> IArrLitDyn (id, List.map rw temps)
    | IArrGetStatic (d, id, k) -> IArrGetStatic (rw d, id, k)
    | IArrGet (d, id, idx) -> IArrGet (rw d, id, rw idx)
    | IArrSetStatic (id, k, v) -> IArrSetStatic (id, k, rw v)
    | IArrSet (id, idx, v) -> IArrSet (id, rw idx, rw v)
    | IHeapAllocConst (d, p, n) -> IHeapAllocConst (rw d, p, n)
    | IHeapAlloc (d, p, n) -> IHeapAlloc (rw d, p, rw n)
    | IHeapGet (d, p, b, idx) -> IHeapGet (rw d, p, rw b, rw idx)
    | IHeapSet (p, b, idx, v) -> IHeapSet (p, rw b, rw idx, rw v)
    | ICons (d, h, t) -> ICons (rw d, rw h, rw t)
    | IHead (d, c) -> IHead (rw d, rw c)
    | ITail (d, c) -> ITail (rw d, rw c)
    | IAdtAlloc (d, tag, args) -> IAdtAlloc (rw d, tag, List.map rw args)
    | ITagGet (d, c) -> ITagGet (rw d, rw c)
    | IFieldGet (d, c, k) -> IFieldGet (rw d, rw c, k)
    | IRegionEnter _ as x -> x
    | IRegionExit (k, None, ty) -> IRegionExit (k, None, ty)
    | IRegionExit (k, Some r, ty) -> IRegionExit (k, Some (rw r), ty)
  in
  let rewrite_term (t : Cfg.terminator) : Cfg.terminator =
    match t with
    | TRet | TUnreachable | TJump _ -> t
    | TBranch (c, lt, le, lj) -> TBranch (rw c, lt, le, lj)
    | TTail (f, args) -> TTail (f, List.map rw args)
  in
  Array.iter (fun (b : Cfg.block) ->
    b.instrs <- List.map rewrite_instr b.instrs;
    b.term <- rewrite_term b.term;
    b.guards <- List.map (fun (v, p) -> (rw v, p)) b.guards
  ) cfg.blocks
