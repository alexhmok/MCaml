(* inline.ml — M3c-1b: leaf-function inlining.

   Runs between cfg_build and optimize+regalloc. Given a table of already-
   lowered cfg_funcs, splices every call to a leaf callee into the caller
   and mutates the table in place.

   Leaf = contains zero ICall instructions AND zero TTail terminators. The
   TTail exclusion matters because TCO-converted self-recursive functions
   have no ICall but still carry TTail; inlining one of those into a
   different function would re-emit the original tail-call at a non-tail
   position — wrong and also nonsense semantically.

   Splice mechanics (see mcaml-m3c-inlining.md §"Mechanics"):
     1. Split caller block B at the ICall. Head keeps instrs [0..i-1] and
        jumps to the inlined entry. A new "kont" block holds [i+1..] with
        B's original terminator.
     2. Clone every callee block. Each clone lives at a fresh label
        n_old + callee_label in the caller's label space.
     3. Rewrite vregs in the clones:
          - $ret           -> $ret (reserved — knormal already emits
                              ICall(None, f, args); ICopy(d, $ret) so the
                              caller reads the return via $ret after the
                              inlined body runs. Don't redirect it.)
          - $arr_result    -> $arr_result (reserved slot, shared)
          - param_i        -> caller's i-th call arg
          - any other vreg -> "$in<event>_<original>"
     4. Rewrite terminators:
          - TRet           -> TJump kont_label
          - TJump l        -> TJump (clone_label_of l)
          - TBranch ...    -> same, with cond rewritten, labels clone-mapped
     5. Compose guards: clone.guards = caller_block.guards @ rewritten
        callee_clone.guards. This keeps the inlined body under all the
        enclosing branches of the call site, and still preserves the
        callee's own internal branching structure.
     6. Rebuild caller.blocks: old_blocks ++ cloned_blocks ++ [kont].
        Recompute preds. *)

open Cfg

let max_leaf_size = 30
let max_caller_growth = 3     (* hard cap: post-inline size / initial size *)

let event_counter = ref 0
let fresh_event () = let e = !event_counter in incr event_counter; e

(* ---- classification ---- *)

let is_leaf (f : cfg_func) : bool =
  (* Phase C: region-containing functions are never leaves from the
     inliner's perspective. Inlining two region-bearing bodies into the
     same caller would let their level-0 save slots collide — the same
     hazard that keeps nested `region` across call boundaries out of
     v1. Also, region-containing functions can only be public entry
     points (enforced in main.ml), and public entries are never
     inlinable targets anyway, so this is belt-and-braces. *)
  Array.for_all (fun (b : block) ->
    List.for_all (fun i ->
      match i with
      | ICall _ -> false
      | IRegionEnter _ | IRegionExit _ -> false
      | _ -> true) b.instrs
    && (match b.term with TTail _ -> false | _ -> true)
  ) f.blocks

let size_of (f : cfg_func) : int =
  Array.fold_left (fun acc (b : block) -> acc + List.length b.instrs) 0 f.blocks

(* ---- vreg rewriting ---- *)

let is_ref_slot v =
  String.length v >= 5 && String.sub v 0 5 = "$ref_"

let make_rewriter ~event_id ~(args : vreg array) : vreg -> vreg =
  let prefix = Printf.sprintf "$in%d_" event_id in
  fun v ->
    if v = "$ret" || v = "$arr_result" || v = "$tick_iters" || is_ref_slot v then v
    else
      match param_index v with
      | Some idx when idx >= 0 && idx < Array.length args -> args.(idx)
      | _ -> prefix ^ v

let rewrite_guards (rw : vreg -> vreg) (gs : (vreg * polarity) list) =
  List.map (fun (v, p) -> (rw v, p)) gs

let rewrite_term ~(label_map : label -> label) ~(kont_label : label)
    (rw : vreg -> vreg) (t : terminator) : terminator =
  match t with
  | TRet -> TJump kont_label
  | TJump l -> TJump (label_map l)
  | TBranch (c, lt, le, lj) ->
      TBranch (rw c, label_map lt, label_map le, label_map lj)
  | TTail (f, args) -> TTail (f, List.map rw args)
  | TUnreachable -> TUnreachable

(* ---- preds recompute (no instr reversal — unlike cfg_build.finalize_all) ---- *)

let recompute_preds (blocks : block array) : unit =
  Array.iter (fun b -> b.preds <- []) blocks;
  Array.iter (fun (b : block) ->
    List.iter (fun s ->
      let succ = blocks.(s) in
      if not (List.mem b.label succ.preds) then
        succ.preds <- b.label :: succ.preds
    ) (succs b.term)
  ) blocks

(* ---- one splice event ---- *)

let rec split_at n xs =
  if n <= 0 then ([], xs)
  else match xs with
    | [] -> ([], [])
    | x :: rest ->
        let (a, b) = split_at (n - 1) rest in
        (x :: a, b)

let find_call
    (caller : cfg_func) (is_inlinable : string -> bool)
  : (int * int * vreg option * string * vreg list) option =
  let result = ref None in
  (try
     Array.iter (fun (b : block) ->
       List.iteri (fun i instr ->
         match instr with
         | ICall (dest, fname, args) when is_inlinable fname ->
             result := Some (b.label, i, dest, fname, args);
             raise Exit
         | _ -> ()
       ) b.instrs
     ) caller.blocks
   with Exit -> ());
  !result

let splice_once
    (caller : cfg_func) (callee : cfg_func)
    ~(block_idx : int) ~(instr_idx : int)
    ~(args : vreg list) : cfg_func =
  let event_id = fresh_event () in
  let args_arr = Array.of_list args in
  let rw = make_rewriter ~event_id ~args:args_arr in

  let n_old = Array.length caller.blocks in
  let n_callee = Array.length callee.blocks in
  let clone_label_of l = n_old + l in
  let kont_label = n_old + n_callee in
  let label_map = clone_label_of in

  let b_src = caller.blocks.(block_idx) in
  let b_guards = b_src.guards in

  let (head, tail_with_call) = split_at instr_idx b_src.instrs in
  let tail = match tail_with_call with _ :: rest -> rest | [] -> [] in

  let kont = {
    label  = kont_label;
    instrs = tail;
    term   = b_src.term;
    preds  = [];
    guards = b_guards;
  } in

  b_src.instrs <- head;
  b_src.term <- TJump (clone_label_of callee.entry);

  let cloned = Array.map (fun (cb : block) ->
    let new_instrs = List.map (map_instr_vregs rw) cb.instrs in
    let new_term = rewrite_term ~label_map ~kont_label rw cb.term in
    let new_guards = b_guards @ rewrite_guards rw cb.guards in
    {
      label  = clone_label_of cb.label;
      instrs = new_instrs;
      term   = new_term;
      preds  = [];
      guards = new_guards;
    }
  ) callee.blocks in

  let total = n_old + n_callee + 1 in
  let new_blocks = Array.make total (make_block 0) in
  Array.blit caller.blocks 0 new_blocks 0 n_old;
  Array.blit cloned 0 new_blocks n_old n_callee;
  new_blocks.(kont_label) <- kont;

  recompute_preds new_blocks;

  { caller with blocks = new_blocks }

(* ---- top-level driver ---- *)

let run (table : (string, cfg_func) Hashtbl.t) : unit =
  let initial_sizes : (string, int) Hashtbl.t = Hashtbl.create 16 in
  Hashtbl.iter (fun name cfg ->
    Hashtbl.add initial_sizes name (size_of cfg)) table;

  (* Leaves are classified on the initial snapshot. We don't re-classify
     after inlining because (a) a leaf that got inlined into still stays
     a leaf; (b) we don't chase inlined-into-inlined chains in M3c-1. *)
  let leaf_set : (string, unit) Hashtbl.t = Hashtbl.create 8 in
  Hashtbl.iter (fun name cfg ->
    if (not cfg.is_template)
       && is_leaf cfg && size_of cfg <= max_leaf_size then
      Hashtbl.add leaf_set name ()
  ) table;

  let caller_names = Hashtbl.fold (fun k _ acc -> k :: acc) table [] in
  List.iter (fun caller_name ->
    let caller0 = Hashtbl.find table caller_name in
    if caller0.is_template then () else
    let initial = Hashtbl.find initial_sizes caller_name in
    let cap = initial * max_caller_growth in
    let keep_going = ref true in
    while !keep_going do
      let caller = Hashtbl.find table caller_name in
      if size_of caller > cap then keep_going := false
      else
        let is_inlinable n =
          n <> caller_name
          && Hashtbl.mem leaf_set n
          && Hashtbl.mem table n
        in
        match find_call caller is_inlinable with
        | None -> keep_going := false
        | Some (bl, i, _dest, callee_name, args) ->
            let callee = Hashtbl.find table callee_name in
            let new_caller =
              splice_once caller callee
                ~block_idx:bl ~instr_idx:i ~args
            in
            Hashtbl.replace table caller_name new_caller
    done
  ) caller_names
