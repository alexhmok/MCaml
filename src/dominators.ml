(* dominators.ml — dominator-tree computation over a Cfg.cfg_func.

   Uses the Cooper/Harvey/Kennedy iterative algorithm: walk blocks in
   reverse postorder and at each non-entry block intersect the idoms of
   its already-processed preds, where intersect walks both fingers up
   the partial idom tree using postorder numbers as a "depth" proxy.

   Self-tail-call edges. A `TTail (f, _)` terminator with `f = cfg.fname`
   is treated as an edge back to `cfg.entry`. Without this, the CFG of
   every TCO'd function (sum_to, dot4_loop, sum8_loop, ...) is acyclic
   from a CFG-only point of view and §2 loop detection finds nothing.
   The augmentation makes the self-tail edge visible to dominator and
   loop analysis. Cross-function tail calls are still left out — they
   leave the function entirely.

   Returns an [idom] array where [idom.(i)] is the immediate dominator
   of block i, or [-1] for the entry block (no dominator) and for any
   unreachable blocks (which currently shouldn't exist but the code is
   defensive). *)

open Cfg

(* Successors of [b], augmented with the self-tail back-edge to entry. *)
let extended_succs (cfg : cfg_func) (b : block) : int list =
  match b.term with
  | TTail (f, _) when f = cfg.fname -> [cfg.entry]
  | t -> succs t

(* Predecessors under the augmented successor relation. Indexed by label. *)
let extended_preds (cfg : cfg_func) : int list array =
  let n = Array.length cfg.blocks in
  let preds = Array.make n [] in
  Array.iter (fun (b : block) ->
    List.iter (fun s ->
      if not (List.mem b.label preds.(s)) then
        preds.(s) <- b.label :: preds.(s))
      (extended_succs cfg b)
  ) cfg.blocks;
  preds

(* DFS from entry, producing reverse postorder + a postorder index per
   reachable block. Unreachable blocks get postorder -1. *)
let reverse_postorder (cfg : cfg_func) : int list * int array =
  let n = Array.length cfg.blocks in
  let visited = Array.make n false in
  let postnum = Array.make n (-1) in
  let counter = ref 0 in
  let order = ref [] in
  let rec dfs v =
    if not visited.(v) then begin
      visited.(v) <- true;
      List.iter dfs (extended_succs cfg cfg.blocks.(v));
      postnum.(v) <- !counter;
      incr counter;
      order := v :: !order
    end
  in
  dfs cfg.entry;
  (!order, postnum)

let compute (cfg : cfg_func) : int array =
  let n = Array.length cfg.blocks in
  let (rpo, postnum) = reverse_postorder cfg in
  let preds = extended_preds cfg in
  let idom = Array.make n (-1) in
  (* Sentinel: entry's idom is itself during the loop, so [intersect]'s
     finger walk terminates cleanly. We set it to -1 at the end. *)
  idom.(cfg.entry) <- cfg.entry;
  let intersect b1 b2 =
    let f1 = ref b1 and f2 = ref b2 in
    while !f1 <> !f2 do
      while postnum.(!f1) < postnum.(!f2) do f1 := idom.(!f1) done;
      while postnum.(!f2) < postnum.(!f1) do f2 := idom.(!f2) done
    done;
    !f1
  in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun b ->
      if b <> cfg.entry then begin
        let processed =
          List.filter (fun p -> idom.(p) <> -1) preds.(b)
        in
        match processed with
        | [] -> ()
        | first :: rest ->
            let new_idom = List.fold_left intersect first rest in
            if idom.(b) <> new_idom then begin
              idom.(b) <- new_idom;
              changed := true
            end
      end
    ) rpo
  done;
  idom.(cfg.entry) <- -1;
  idom

(* Does block [a] dominate block [b]? A block dominates itself. *)
let dominates (idom : int array) (a : int) (b : int) : bool =
  if a = b then true
  else
    let cur = ref b in
    let result = ref false in
    let stop = ref false in
    while not !stop do
      let p = idom.(!cur) in
      if p = -1 then stop := true
      else if p = a then begin result := true; stop := true end
      else if p = !cur then stop := true
      else cur := p
    done;
    !result

let dump (cfg : cfg_func) (idom : int array) : string =
  let buf = Buffer.create 64 in
  Buffer.add_string buf "  idom: ";
  Array.iteri (fun i d ->
    if i > 0 then Buffer.add_string buf " ";
    if d = -1 then Buffer.add_string buf (Printf.sprintf "L%d:-" i)
    else Buffer.add_string buf (Printf.sprintf "L%d:L%d" i d)
  ) idom;
  Buffer.add_char buf '\n';
  Buffer.contents buf
