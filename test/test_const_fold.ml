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

(* Int32 wrap parity: scoreboard values are Java ints, so overflowing
   folds must wrap two's-complement (TODO.md decision 2026-07-11:
   fold WITH the wrap, matching vanilla, rather than refuse to fold).
   Pins wrap32 itself plus the Add/Mult/FMult/Div rewrite paths. *)
let check_wrap32_literals () =
  Alcotest.(check int) "max_int32 + 1 wraps to min_int32"
    (-2147483648) (wrap32 (2147483647 + 1));
  Alcotest.(check int) "min_int32 - 1 wraps to max_int32"
    2147483647 (wrap32 (-2147483648 - 1));
  Alcotest.(check int) "2e9 + 2e9 wraps"
    (-294967296) (wrap32 (2000000000 + 2000000000));
  Alcotest.(check int) "65536 * 65536 wraps to 0"
    0 (wrap32 (65536 * 65536));
  Alcotest.(check int) "100000 * 100000 wraps"
    1410065408 (wrap32 (100000 * 100000));
  Alcotest.(check int) "in-range values pass through"
    (-7) (wrap32 (-7));
  Alcotest.(check int) "MIN_INT floorDiv -1 wraps to MIN_INT"
    (-2147483648) (wrap32 (floor_div (-2147483648) (-1)))

let fold_of env i =
  let instr, _, changed = rewrite_instr env i in
  (instr, changed)

let check_wrap32_rewrites () =
  let env k1 k2 = set_const (set_const M.empty "a" k1) "b" k2 in
  (* Add overflow folds to the wrapped runtime value. *)
  (match fold_of (env 2000000000 2000000000)
           (Cfg.IBinOp ("d", Ast.Add, "a", "b")) with
   | Cfg.IConst ("d", -294967296), true -> ()
   | i, _ -> Alcotest.failf "Add: expected IConst(d, -294967296), got %s"
               (Cfg.string_of_instr i));
  (* Mult overflow folds wrapped. *)
  (match fold_of (env 100000 100000)
           (Cfg.IBinOp ("d", Ast.Mult, "a", "b")) with
   | Cfg.IConst ("d", 1410065408), true -> ()
   | i, _ -> Alcotest.failf "Mult: expected IConst(d, 1410065408), got %s"
               (Cfg.string_of_instr i));
  (* Sub underflow folds wrapped. *)
  (match fold_of (env (-2147483648) 1)
           (Cfg.IBinOp ("d", Ast.Sub, "a", "b")) with
   | Cfg.IConst ("d", 2147483647), true -> ()
   | i, _ -> Alcotest.failf "Sub: expected IConst(d, 2147483647), got %s"
               (Cfg.string_of_instr i));
  (* FMult used to decline on overflow; now folds the wrapped
     pre-shift product (a/256)*(b/256). *)
  (match fold_of (env 2147483647 2147483647)
           (Cfg.IBinOp ("d", Ast.FMult, "a", "b")) with
   | Cfg.IConst ("d", k), true ->
       let expect = wrap32 (floor_div 2147483647 256 * floor_div 2147483647 256) in
       Alcotest.(check int) "FMult wrapped product" expect k
   | i, _ -> Alcotest.failf "FMult: expected a fold, got %s"
               (Cfg.string_of_instr i));
  (* Div MIN_INT / -1 folds to MIN_INT (Java floorDiv overflow case). *)
  (match fold_of (env (-2147483648) (-1))
           (Cfg.IBinOp ("d", Ast.Div, "a", "b")) with
   | Cfg.IConst ("d", -2147483648), true -> ()
   | i, _ -> Alcotest.failf "Div: expected IConst(d, -2147483648), got %s"
               (Cfg.string_of_instr i))

let suite =
  [ ( "const_fold",
      [ Alcotest.test_case "floor literals" `Quick check_literals;
        Alcotest.test_case "floor grid identity" `Quick check_grid;
        Alcotest.test_case "Div/Mod const rewrite" `Quick check_rewrite;
        Alcotest.test_case "int32 wrap literals" `Quick check_wrap32_literals;
        Alcotest.test_case "int32 wrap rewrites" `Quick check_wrap32_rewrites ] ) ]
