(* cfg_build.ml — kexpr -> CFG lowering (Milestone 2, Stage 1).

   Entry point: [of_kexpr fname params k]. The caller is responsible for
   running Tco.optimize_tail on [k] before passing it in — KLoop nodes are
   expected to already be present where tail calls occurred.

   The lowering is a single recursive pass over the kexpr tree. It threads a
   mutable [builder] state holding the current block being filled, a
   hashtable of all blocks created so far, and a per-function fresh-label
   counter.

   Guard chains are populated during lowering, not as a post-pass: when a
   KIf is lowered, its then-arm's entry block inherits the parent block's
   guard chain with [(c, Pos)] pushed on, its else-arm gets [(c, Neg)], and
   its join block inherits the parent's chain unchanged. Any fresh block
   created *while* lowering one of the arms copies the current block's
   guard chain — so nested branches compose automatically.

   After lowering, a finalization pass reverses every block's instr list
   into forward order and populates the [preds] field of every block by
   scanning every terminator once. *)

open Cfg

(* ---- builder state ---- *)

type builder = {
  mutable cur          : block;
  blocks               : (label, block) Hashtbl.t;
  next_label           : int ref;
  (* Phase C. Lexical region-nesting depth threaded through [lower].
     Each [KRegion] bump + recurse + decrement, using the pre-bump value
     as the level [k] on the emitted IRegionEnter/IRegionExit pair. v1
     caps at 4 levels (k ∈ [0,3]); exceeding the cap is a hard error
     because save slots are a fixed global scoreboard set. *)
  mutable region_depth : int;
}

let fresh_label (b : builder) : label =
  let l = !(b.next_label) in
  incr b.next_label;
  l

(* Create a new block with the given guard chain, register it in the
   builder, and return it. *)
let new_block (b : builder) ~(guards : (vreg * polarity) list) : block =
  let l = fresh_label b in
  let blk = make_block l in
  blk.guards <- guards;
  Hashtbl.add b.blocks l blk;
  blk

(* Seal the current block with a terminator. If the block's terminator
   is already set (not TUnreachable), leave it alone — the caller
   presumably already terminated it (e.g., a nested KLoop that sealed
   the block before control returned here). *)
let seal (blk : block) (t : terminator) : unit =
  if not (block_is_sealed blk) then blk.term <- t

(* ---- the recursive lowering function ---- *)

let rec lower (b : builder) (k : Knormal.kexpr) ~(dest : vreg option) : unit =
  match k with
  | Knormal.KUnit -> ()

  | Knormal.KInt i ->
      (match dest with
       | Some d -> add_instr b.cur (IConst (d, i))
       | None -> ())

  | Knormal.KVar v ->
      (match dest with
       | Some d when d <> v -> add_instr b.cur (ICopy (d, v))
       | _ -> ())

  | Knormal.KStr _ -> ()

  | Knormal.KCommand s ->
      add_instr b.cur (ICommand s)

  | Knormal.KBinOp (op, v1, v2) ->
      (match dest with
       | Some d -> add_instr b.cur (IBinOp (d, op, v1, v2))
       | None -> ())

  | Knormal.KLet (_, Knormal.KUnit, body) ->
      (* Dummy KLet-as-declaration pattern (used by knormal for BinOp and
         KArr* wrappers). The binder has no runtime effect — recurse into
         the body with the ambient dest. *)
      lower b body ~dest

  | Knormal.KLet (_, Knormal.KStr _, body) ->
      lower b body ~dest

  | Knormal.KLet (n, rhs, body) ->
      lower b rhs ~dest:(Some n);
      lower b body ~dest

  | Knormal.KSeq (a, c) ->
      lower b a ~dest:None;
      lower b c ~dest

  | Knormal.KAssign (n, rhs) ->
      (* Knormal doesn't currently emit KAssign; handle defensively as
         "lower rhs writing into n". *)
      lower b rhs ~dest:(Some n)

  | Knormal.KIf (c, t, e) ->
      let parent = b.cur in
      let parent_guards = parent.guards in
      let then_guards = parent_guards @ [(c, Pos)] in
      let else_guards = parent_guards @ [(c, Neg)] in
      let l_then_blk = new_block b ~guards:then_guards in
      let l_else_blk = new_block b ~guards:else_guards in
      let l_join_blk = new_block b ~guards:parent_guards in
      seal parent
        (TBranch (c, l_then_blk.label, l_else_blk.label, l_join_blk.label));
      (* Lower then-arm. *)
      b.cur <- l_then_blk;
      lower b t ~dest;
      (* After lowering, the current block may have changed if nested
         branches were encountered. If the final block of the arm is
         not sealed, jump to join. *)
      if not (block_is_sealed b.cur) then
        seal b.cur (TJump l_join_blk.label);
      (* Lower else-arm. *)
      b.cur <- l_else_blk;
      lower b e ~dest;
      if not (block_is_sealed b.cur) then
        seal b.cur (TJump l_join_blk.label);
      (* Continue in join. *)
      b.cur <- l_join_blk

  | Knormal.KCall (f, args) ->
      add_instr b.cur (ICall (dest, f, args))

  | Knormal.KLoop (f, args) ->
      (* Seal the current block and leave [cur] pointed at it. Any caller
         that checks [block_is_sealed b.cur] afterwards sees a sealed
         block (TTail != TUnreachable) and skips its own sealing — this
         is how the KIf handler correctly avoids injecting a TJump on a
         branch arm that ends in a tail call. Knormal never emits code
         after a KLoop, so no instructions should ever be added here; if
         that invariant is ever broken, [add_instr] will silently append
         into a sealed block, and the block's emitted output will be
         wrong. This is intentional — easier to catch in a test than to
         paper over with a dead block. *)
      seal b.cur (TTail (f, args))

  | Knormal.KArrLitConst (id, ints) ->
      let _ = dest in
      add_instr b.cur (IArrLitConst (id, ints))

  | Knormal.KArrLitDyn (id, temps) ->
      let _ = dest in
      add_instr b.cur (IArrLitDyn (id, temps))

  | Knormal.KArrGetStatic (d, id, k_idx) ->
      (* This kexpr carries its own dest; ignore ambient [dest]. *)
      let _ = dest in
      add_instr b.cur (IArrGetStatic (d, id, k_idx))

  | Knormal.KArrGet (d, id, idx) ->
      let _ = dest in
      add_instr b.cur (IArrGet (d, id, idx))

  | Knormal.KArrSetStatic (id, k_idx, v) ->
      let _ = dest in
      add_instr b.cur (IArrSetStatic (id, k_idx, v))

  | Knormal.KArrSet (id, idx, v) ->
      let _ = dest in
      add_instr b.cur (IArrSet (id, idx, v))

  | Knormal.KDynAllocConst (d, p, n) ->
      let _ = dest in
      add_instr b.cur (IHeapAllocConst (d, p, n))

  | Knormal.KDynAlloc (d, p, n) ->
      let _ = dest in
      add_instr b.cur (IHeapAlloc (d, p, n))

  | Knormal.KHeapGet (d, p, base, idx) ->
      let _ = dest in
      add_instr b.cur (IHeapGet (d, p, base, idx))

  | Knormal.KHeapSet (p, base, idx, v) ->
      let _ = dest in
      add_instr b.cur (IHeapSet (p, base, idx, v))

  | Knormal.KCons (d, h, t) ->
      let _ = dest in
      add_instr b.cur (ICons (d, h, t))

  | Knormal.KHead (d, c) ->
      let _ = dest in
      add_instr b.cur (IHead (d, c))

  | Knormal.KTail (d, c) ->
      let _ = dest in
      add_instr b.cur (ITail (d, c))

  | Knormal.KRegion body ->
      let k = b.region_depth in
      if k > 3 then
        failwith
          "mcaml: region nesting exceeds v1 ceiling of 4 levels (§4.1)";
      add_instr b.cur (IRegionEnter k);
      b.region_depth <- k + 1;
      lower b body ~dest;
      b.region_depth <- k;
      (* Only emit the exit if control can reach here. A body that ends
         in a tail call (TTail) or an unconditional return seals b.cur
         and the exit would be dead — not just wasted commands, but a
         leak: the tail jump skips the exit entirely. This is the
         concrete failure mode decision #5 addresses for TCO: we don't
         recurse into KRegion in tco.ml, so self-tail calls inside a
         region body stay as plain KCall → ICall and the exit below
         still runs before the function returns naturally. *)
      if not (block_is_sealed b.cur) then
        add_instr b.cur (IRegionExit (k, None, Ast.TUnit))

(* ---- finalization: reverse instrs, populate preds ---- *)

let finalize_all (blocks : block array) : unit =
  Array.iter finalize_block blocks;
  (* Clear any stale preds. *)
  Array.iter (fun b -> b.preds <- []) blocks;
  (* One scan: for every block's terminator, add the block's label to
     each successor's preds. *)
  Array.iter (fun (b : block) ->
    List.iter (fun (s : label) ->
      let succ = blocks.(s) in
      if not (List.mem b.label succ.preds) then
        succ.preds <- b.label :: succ.preds
    ) (succs b.term)
  ) blocks

(* Convert the hashtable of blocks into a densely-packed array where
   [blocks.(i).label = i]. We assigned labels as sequential integers, so
   this is a direct index. *)
let blocks_of_table (tbl : (label, block) Hashtbl.t) : block array =
  let n = Hashtbl.length tbl in
  let arr = Array.make n (make_block 0) in
  Hashtbl.iter (fun l blk -> arr.(l) <- blk) tbl;
  arr

(* ---- top-level entry ---- *)

let of_kexpr (fname : string) (params : (string * Ast.typ) list)
    (k : Knormal.kexpr) : cfg_func =
  let blocks_tbl : (label, block) Hashtbl.t = Hashtbl.create 16 in
  let next_label = ref 0 in
  (* Create the entry block manually (before the builder exists) so the
     builder can point [cur] at it. It has an empty guard chain. *)
  let entry_label =
    let l = !next_label in
    incr next_label;
    l
  in
  let entry_blk = make_block entry_label in
  Hashtbl.add blocks_tbl entry_label entry_blk;
  let b = {
    cur = entry_blk;
    blocks = blocks_tbl;
    next_label;
    region_depth = 0;
  } in

  (* Parameter prelude: ICopy(p_name, "param_i") for each scalar parameter.
     Array/matrix parameters are not runtime values — knormal resolves
     references through arr_env to sentinel storage ids — so we skip the
     prelude copy for them. *)
  List.iteri (fun i (p_name, ty) ->
    match ty with
    | Ast.TArrStatic _ | Ast.TMat _ -> ()
    | _ ->
        let param_slot = Printf.sprintf "param_%d" i in
        add_instr entry_blk (ICopy (p_name, param_slot))
  ) params;

  (* Lower the body. The top-level body's value is discarded from the
     CFG's perspective — knormal's entry point writes the result into
     "$ret" via the normalize_to-dest pattern, so any return value has
     already been bound by the time we get here. *)
  lower b k ~dest:None;

  (* After lowering, the current block (whichever it is) may or may not
     already be sealed. If it's not, it's the function's natural return
     point — seal it with TRet. *)
  if not (block_is_sealed b.cur) then
    seal b.cur TRet;

  let blocks = blocks_of_table blocks_tbl in
  finalize_all blocks;

  let is_template =
    List.exists (fun (_, t) ->
      match t with Ast.TArrStatic _ | Ast.TMat _ -> true | _ -> false) params
  in
  {
    fname;
    params;
    entry = entry_label;
    blocks;
    slot_count = 0;
    preheader_instrs = [];
    is_template;
  }
