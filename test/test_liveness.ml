(* Guard-chain pinning: every cond_vreg in a block's guard chain counts as
   an implicit use of every instruction in that block — the M2 correctness
   fix without which a branch cond is "dead" inside its own branches. *)

open Cfg_fixtures

let guarded () =
  mk_func
    [ mk_block 0
        [ Cfg.IConst ("c", 1);
          Cfg.IConst ("t", 3);
          Cfg.IBinOp ("u", Ast.Add, "t", "t") ]
        (Cfg.TBranch ("c", 1, 2, 3));
      mk_block 1 ~guards:[ ("c", Cfg.Pos) ] [ Cfg.IConst ("x", 5) ]
        (Cfg.TJump 3);
      mk_block 2 ~guards:[ ("c", Cfg.Neg) ] [] (Cfg.TJump 3);
      mk_block 3 [] Cfg.TRet ]

let check_pinning () =
  let lv = Liveness.analyze (guarded ()) in
  let b1 = lv.Liveness.per_block.(1) in
  Alcotest.(check bool) "guard cond live into its own branch" true
    (Liveness.VSet.mem "c" b1.Liveness.live_in);
  Alcotest.(check bool) "cond pinned across b1's instructions" true
    (Liveness.VSet.mem "c" lv.Liveness.per_instr.(1).(0));
  (* Negative control: a vreg defined and consumed inside b0 must not be
     pinned into the branch. *)
  Alcotest.(check bool) "b0-local temp not live into b1" false
    (Liveness.VSet.mem "t" b1.Liveness.live_in)

let check_reserved () =
  Alcotest.(check bool) "$ret is reserved" true (Liveness.is_reserved "$ret");
  Alcotest.(check bool) "ordinary vreg is tracked" false
    (Liveness.is_reserved "x");
  Alcotest.(check bool) "add_if_tracked drops $ret" false
    (Liveness.VSet.mem "$ret"
       (Liveness.add_if_tracked "$ret" Liveness.VSet.empty))

let suite =
  [ ( "liveness",
      [ Alcotest.test_case "guard-chain pinning" `Quick check_pinning;
        Alcotest.test_case "reserved slots untracked" `Quick check_reserved ] ) ]
