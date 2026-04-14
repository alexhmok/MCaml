(* loop_detect.ml — natural loop detection + preheader insertion.

   A back-edge is an edge (b -> s) where s dominates b. The natural
   loop for a back-edge is the set of nodes that can reach b without
   passing through s (plus s itself). Multiple back-edges sharing the
   same header are merged into a single loop.

   Edges are computed under the augmented successor relation defined in
   [Dominators.extended_succs] — the self-tail-call to the function's
   own entry counts as a back-edge so TCO'd loops are visible here. *)

open Cfg

type loop = {
  header     : label;
  body       : label list;             (* includes header *)
  back_edges : (label * label) list;   (* (latch, header) pairs *)
}

(* Find every back-edge (b -> s) under the augmented successor relation. *)
let find_back_edges (cfg : cfg_func) (idom : int array)
  : (label * label) list =
  let edges = ref [] in
  Array.iter (fun (b : block) ->
    List.iter (fun s ->
      if Dominators.dominates idom s b.label then
        edges := (b.label, s) :: !edges
    ) (Dominators.extended_succs cfg b)
  ) cfg.blocks;
  !edges

(* Reverse-reachability from [latch] without crossing [header], plus
   header itself. Used to compute the body of one back-edge's loop. *)
let reachable_back_to (preds : int list array)
    (latch : label) (header : label) : label list =
  let visited : (label, unit) Hashtbl.t = Hashtbl.create 16 in
  Hashtbl.add visited header ();
  let rec walk n =
    if not (Hashtbl.mem visited n) then begin
      Hashtbl.add visited n ();
      List.iter walk preds.(n)
    end
  in
  walk latch;
  Hashtbl.fold (fun k () acc -> k :: acc) visited []

let find_loops (cfg : cfg_func) (idom : int array) : loop list =
  let preds = Dominators.extended_preds cfg in
  let back_edges = find_back_edges cfg idom in
  let by_header : (label, (label * label) list) Hashtbl.t =
    Hashtbl.create 4
  in
  List.iter (fun (latch, header) ->
    let prev = try Hashtbl.find by_header header with Not_found -> [] in
    Hashtbl.replace by_header header ((latch, header) :: prev)
  ) back_edges;
  let loops = Hashtbl.fold (fun header bes acc ->
    let body_set : (label, unit) Hashtbl.t = Hashtbl.create 16 in
    Hashtbl.add body_set header ();
    List.iter (fun (latch, _) ->
      List.iter (fun n ->
        if not (Hashtbl.mem body_set n) then Hashtbl.add body_set n ()
      ) (reachable_back_to preds latch header)
    ) bes;
    let body =
      Hashtbl.fold (fun k () acc -> k :: acc) body_set []
      |> List.sort compare
    in
    { header; body; back_edges = bes } :: acc
  ) by_header [] in
  (* Innermost-first: a loop A is "inside" loop B iff A.body is a strict
     subset of B.body. Use a stable sort over a comparison that puts the
     smaller loop first when one is contained in the other. *)
  let body_set l =
    let s = Hashtbl.create 16 in
    List.iter (fun n -> Hashtbl.add s n ()) l.body;
    s
  in
  let is_subset_of a b =
    a.header <> b.header
    && List.for_all (fun n -> Hashtbl.mem (body_set b) n) a.body
  in
  List.sort (fun a b ->
    if is_subset_of a b then -1
    else if is_subset_of b a then 1
    else compare (List.length a.body) (List.length b.body)
  ) loops

(* ---- preheader insertion ---- *)

(* Rewrite a terminator so that any reference to [from] becomes [to_].
   Used to redirect entry edges of a loop header through the freshly
   inserted preheader. Does NOT touch TTail (those are function-level
   self-edges and are handled separately if at all). *)
let redirect_term (term : terminator) (from_ : label) (to_ : label)
  : terminator =
  match term with
  | TJump l when l = from_ -> TJump to_
  | TBranch (c, lt, le, lj) ->
      let lt' = if lt = from_ then to_ else lt in
      let le' = if le = from_ then to_ else le in
      let lj' = if lj = from_ then to_ else lj in
      TBranch (c, lt', le', lj')
  | t -> t

(* Insert (or identify) a preheader for [loop]. Mutates [cfg.blocks] by
   growing the array if a fresh preheader is created. Returns the
   preheader's label.

   A preheader is a block whose only successor is the loop header and
   that sits at the same nesting level as the header. LICM/unrolling
   put their hoisted/initialized code there.

   Note: this function is wired but not yet invoked from optimize.ml or
   main.ml — it's part of the §1 infrastructure layer that LICM will
   consume in the next session. The current dump entry point only
   computes loops; it does not mutate the CFG. *)
let insert_preheader (cfg : cfg_func) (loop : loop) : label =
  let h = loop.header in
  let header_block = cfg.blocks.(h) in
  let in_body p = List.mem p loop.body in
  let entry_preds = List.filter (fun p -> not (in_body p)) header_block.preds in
  let back_preds  = List.filter in_body header_block.preds in
  (* Special case: a unique entry pred whose only successor is h is
     already a valid preheader. *)
  let reusable =
    match entry_preds with
    | [p] ->
        let pb = cfg.blocks.(p) in
        (match pb.term with
         | TJump l when l = h -> Some p
         | _ -> None)
    | _ -> None
  in
  match reusable with
  | Some p -> p
  | None ->
      let n = Array.length cfg.blocks in
      let ph_label = n in
      let ph = make_block ph_label in
      ph.guards <- header_block.guards;  (* same nesting level as header *)
      ph.term <- TJump h;
      ph.preds <- entry_preds;
      List.iter (fun p ->
        let pb = cfg.blocks.(p) in
        pb.term <- redirect_term pb.term h ph_label
      ) entry_preds;
      header_block.preds <- ph_label :: back_preds;
      let new_blocks = Array.make (n + 1) (make_block 0) in
      Array.blit cfg.blocks 0 new_blocks 0 n;
      new_blocks.(n) <- ph;
      cfg.blocks <- new_blocks;
      ph_label

(* ---- debug dump ---- *)

let dump_loops (loops : loop list) : string =
  let buf = Buffer.create 64 in
  if loops = [] then
    Buffer.add_string buf "  loops: (none)\n"
  else
    List.iter (fun l ->
      Buffer.add_string buf
        (Printf.sprintf "  loop header=L%d body=[%s] back_edges=[%s]\n"
           l.header
           (String.concat "," (List.map (fun n -> Printf.sprintf "L%d" n) l.body))
           (String.concat ","
              (List.map (fun (a, b) -> Printf.sprintf "L%d->L%d" a b)
                 l.back_edges)))
    ) loops;
  Buffer.contents buf
