(* TTail dispatch shape: a self-tail call must be emitted as
   `return run function mcaml:<self>`, never a bare `function`
   dispatch. A bare dispatch does not terminate the caller frame, so
   when the innermost frame of a TCO'd loop takes the exit branch,
   every stacked frame falls through into the guard-wrapped exit
   commands on unwind and re-runs them once per frame (fixed in
   21bc459; sim_check_suite.py pins the end-to-end behavior via
   async_sum's non-idempotent exit branch — this is the unit pin). *)

open Cfg
open Cfg_fixtures

let contains (sub : string) (s : string) : bool =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  go 0

(* looper(param_0): if param_0 < 10 then tail self(param_0 + 1)
   else $ret = param_0. Post-regalloc shape: block 0 computes the
   cond into $r0, block 1 (guarded Pos) advances and self-tails,
   block 2 (guarded Neg) writes $ret and returns. Note the regalloc
   invariant: IBinOp never has d = v2 <> v1. *)
let self_loop_cfg () =
  mk_func ~fname:"looper" ~slot_count:2
    [ mk_block 0
        [ IConst ("$r1", 10);
          IBinOp ("$r0", Ast.Lt, "param_0", "$r1") ]
        (TBranch ("$r0", 1, 2, 2));
      mk_block 1 ~guards:[ ("$r0", Pos) ]
        [ IConst ("$r1", 1);
          IBinOp ("$r1", Ast.Add, "$r1", "param_0") ]
        (TTail ("looper", [ "$r1" ]));
      mk_block 2 ~guards:[ ("$r0", Neg) ]
        [ ICopy ("$ret", "param_0") ]
        TRet ]

let check_ttail_return_run () =
  let files = Codegen_cfg.emit (self_loop_cfg ()) in
  let main_cmds =
    match List.assoc_opt "looper" files with
    | Some cmds -> cmds
    | None -> Alcotest.fail "no looper.mcfunction emitted"
  in
  let dispatches =
    List.filter (contains "function mcaml:looper") main_cmds in
  Alcotest.(check int) "exactly one self-dispatch line" 1
    (List.length dispatches);
  let d = List.hd dispatches in
  if not (contains "return run function mcaml:looper" d) then
    Alcotest.failf "self-tail dispatch is not `return run`: %s" d

let suite =
  [ ( "codegen_cfg",
      [ Alcotest.test_case "self-TTail emits return run" `Quick
          check_ttail_return_run ] ) ]
