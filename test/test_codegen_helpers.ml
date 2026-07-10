(* Golden command strings for the pure builders in codegen_helpers —
   a unit-level canary. Changing an emitted command shape means updating
   the pinned string here, deliberately. *)

open Codegen_helpers

let check_binop_elision () =
  (* SR amendment: the leading d := v1 self-copy is elided when d = v1,
     so an SR carrier increment is a single += command. *)
  Alcotest.(check (list string)) "d = v1: single command"
    [ "scoreboard players operation $r0 vars += $r1 vars" ]
    (cmd_score_binop "$r0" Ast.Add "$r0" "$r1");
  Alcotest.(check (list string)) "d <> v1: copy then op"
    [ "scoreboard players operation $r0 vars = $r2 vars";
      "scoreboard players operation $r0 vars += $r1 vars" ]
    (cmd_score_binop "$r0" Ast.Add "$r2" "$r1")

let check_comparisons () =
  Alcotest.(check (list string)) "Lt via store success + if"
    [ "execute store success score $r0 vars if score $r1 vars < $r2 vars" ]
    (cmd_score_binop "$r0" Ast.Lt "$r1" "$r2");
  Alcotest.(check (list string)) "Neq via unless ="
    [ "execute store success score $r0 vars unless score $r1 vars = $r2 vars" ]
    (cmd_score_binop "$r0" Ast.Neq "$r1" "$r2")

let check_fmult () =
  (* Q16.16 pre-shift multiply: 5 commands, 4 when d = v1. *)
  Alcotest.(check (list string)) "FMult d <> v1: 5 cmds"
    [ "scoreboard players operation $fmul_t vars = $r2 vars";
      "scoreboard players operation $fmul_t vars /= $c256 vars";
      "scoreboard players operation $r0 vars = $r1 vars";
      "scoreboard players operation $r0 vars /= $c256 vars";
      "scoreboard players operation $r0 vars *= $fmul_t vars" ]
    (cmd_score_binop "$r0" Ast.FMult "$r1" "$r2");
  Alcotest.(check int) "FMult d = v1: self-copy elided" 4
    (List.length (cmd_score_binop "$r0" Ast.FMult "$r0" "$r2"))

let check_primitives () =
  Alcotest.(check string) "score set"
    "scoreboard players set $r0 vars 42"
    (cmd_score_set "$r0" 42);
  Alcotest.(check string) "score copy"
    "scoreboard players operation $r0 vars = $r1 vars"
    (cmd_score_copy "$r0" "$r1");
  Alcotest.(check string) "arr lit const"
    "data modify storage mcaml:heap arr3 set value [1, 2, 3]"
    (cmd_arr_lit_const "arr3" [ 1; 2; 3 ])

let suite =
  [ ( "codegen_helpers",
      [ Alcotest.test_case "binop self-copy elision" `Quick check_binop_elision;
        Alcotest.test_case "comparison shapes" `Quick check_comparisons;
        Alcotest.test_case "FMult pre-shift sequence" `Quick check_fmult;
        Alcotest.test_case "primitive builders" `Quick check_primitives ] ) ]
