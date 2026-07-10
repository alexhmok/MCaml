(* Floor-division parity: floor_div/floor_mod must match vanilla
   scoreboard /= %= (Java floorDiv/floorMod, measured in-game 2026-07-07)
   and sim.py — NOT OCaml's truncating (/) and (mod). Unit-level pin of
   the mc_test_suite t04/t05, t07/t08, t61/t62 fold/runtime parity. *)

open Const_fold

let check_literals () =
  Alcotest.(check int) "-7 / 2 floors to -4" (-4) (floor_div (-7) 2);
  Alcotest.(check int) "-7 % 3 = 2" 2 (floor_mod (-7) 3);
  Alcotest.(check int) "7 / -2 floors to -4" (-4) (floor_div 7 (-2));
  Alcotest.(check int) "7 % -3 = -2 (divisor's sign)" (-2) (floor_mod 7 (-3));
  Alcotest.(check int) "-9 / 3 exact" (-3) (floor_div (-9) 3);
  Alcotest.(check int) "8 / 2" 4 (floor_div 8 2);
  Alcotest.(check int) "8 % 3" 2 (floor_mod 8 3)

(* a = q*b + m with m taking the divisor's sign and |m| < |b| — the
   floorDiv/floorMod contract, over a grid that crosses every sign
   combination. OCaml's (/)/(mod) fail this for a < 0. *)
let check_grid () =
  List.iter
    (fun b ->
      for a = -20 to 20 do
        let q = floor_div a b and m = floor_mod a b in
        if q * b + m <> a then
          Alcotest.failf "identity broken: %d <> %d*%d + %d" a q b m;
        if m <> 0 && (m > 0) <> (b > 0) then
          Alcotest.failf "%d mod %d = %d: sign differs from divisor" a b m;
        if abs m >= abs b then
          Alcotest.failf "%d mod %d = %d: |m| >= |b|" a b m
      done)
    [ -7; -3; -2; -1; 1; 2; 3; 7 ]

(* The fold path itself routes through floor_div/floor_mod: a const-const
   IBinOp Div/Mod rewrites to the floored IConst. *)
let check_rewrite () =
  let env = set_const (set_const M.empty "a" (-7)) "b" 2 in
  let instr, _, changed =
    rewrite_instr env (Cfg.IBinOp ("d", Ast.Div, "a", "b"))
  in
  Alcotest.(check bool) "Div rewrite fired" true changed;
  (match instr with
   | Cfg.IConst ("d", -4) -> ()
   | i -> Alcotest.failf "expected IConst(d, -4), got %s" (Cfg.string_of_instr i));
  let instr, _, _ = rewrite_instr env (Cfg.IBinOp ("m", Ast.Mod, "a", "b")) in
  match instr with
  | Cfg.IConst ("m", 1) -> ()
  | i -> Alcotest.failf "expected IConst(m, 1), got %s" (Cfg.string_of_instr i)

let suite =
  [ ( "const_fold",
      [ Alcotest.test_case "floor literals" `Quick check_literals;
        Alcotest.test_case "floor grid identity" `Quick check_grid;
        Alcotest.test_case "Div/Mod const rewrite" `Quick check_rewrite ] ) ]
