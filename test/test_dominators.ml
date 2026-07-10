(* Dominators + natural-loop detection on hand-built CFGs, including the
   self-TTail-to-entry augmentation that makes TCO'd loops visible. *)

open Cfg_fixtures

let diamond () =
  mk_func
    [ mk_block 0 [ Cfg.IConst ("c", 1) ] (Cfg.TBranch ("c", 1, 2, 3));
      mk_block 1 [] (Cfg.TJump 3);
      mk_block 2 [] (Cfg.TJump 3);
      mk_block 3 [] Cfg.TRet ]

(* The canonical tco.ml output shape: header at entry, one arm tail-calls
   self, the other exits. Dominators must treat the self-TTail as a back
   edge to entry even though Cfg.succs says a TTail leaves the CFG. *)
let tco_loop () =
  mk_func ~fname:"loopy"
    [ mk_block 0 [ Cfg.IConst ("c", 1) ] (Cfg.TBranch ("c", 1, 2, 2));
      mk_block 1 [] (Cfg.TTail ("loopy", []));
      mk_block 2 [] Cfg.TRet ]

let check_diamond () =
  let f = diamond () in
  let idom = Dominators.compute f in
  Alcotest.(check (array int)) "idom" [| -1; 0; 0; 0 |] idom;
  Alcotest.(check bool) "entry dominates merge" true
    (Dominators.dominates idom 0 3);
  Alcotest.(check bool) "one arm does not dominate merge" false
    (Dominators.dominates idom 1 3);
  Alcotest.(check bool) "every block self-dominates" true
    (Dominators.dominates idom 3 3)

let check_tco_loop () =
  let f = tco_loop () in
  Alcotest.(check (list int)) "self-TTail augments succs with entry" [ 0 ]
    (Dominators.extended_succs f f.Cfg.blocks.(1));
  let idom = Dominators.compute f in
  Alcotest.(check (list (pair int int))) "back edge from tail block" [ (1, 0) ]
    (Loop_detect.find_back_edges f idom);
  match Loop_detect.find_loops f idom with
  | [ l ] ->
      Alcotest.(check int) "header at entry" 0 l.Loop_detect.header;
      Alcotest.(check (list int)) "body is header + latch" [ 0; 1 ]
        (List.sort compare l.Loop_detect.body)
  | ls -> Alcotest.failf "expected exactly one loop, got %d" (List.length ls)

let suite =
  [ ( "dominators",
      [ Alcotest.test_case "diamond idom tree" `Quick check_diamond;
        Alcotest.test_case "TCO self-loop detection" `Quick check_tco_loop ] ) ]
