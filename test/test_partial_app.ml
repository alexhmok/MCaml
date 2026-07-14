(* Partial_app desugar pins: an under-applied call to a known top-level
   fun becomes let-temps (supplied args evaluate once) wrapping a
   Lambda whose body is the fully-applied call; exact/over-applied
   calls and array/ref-param targets are left alone. *)

open Ast

let parse (src : string) : Ast.program =
  Parser.prog Lexer.read (Lexing.from_string src)

let body_of (name : string) (prog : Ast.program) : expr =
  match List.find_opt
          (function Fun (n, _, _, _) -> n = name | _ -> false) prog with
  | Some (Fun (_, _, _, b)) -> b
  | _ -> Alcotest.failf "no fun %s in program" name

let check_under_applied () =
  let prog = Partial_app.run (parse
    "fun add(a: int, b: int): int = a + b\n\
     fun main(): int = let g = add(1) in g(2)\n") in
  match body_of "main" prog with
  | Let ("g",
      Let (t, Int 1,
        Lambda ([(p, TVar _)],
          App ("add", [Var t'; Var p']))),
      App ("g", [Int 2]))
    when t = t' && p = p' ->
      Alcotest.(check bool) "temp evaluates arg once, lambda closes over it"
        true (String.length t > 4 && String.sub t 0 4 = "__pa")
  | _ -> Alcotest.fail "under-applied add(1) did not desugar to temps+lambda"

let check_exact_untouched () =
  let src = "fun add(a: int, b: int): int = a + b\n\
             fun main(): int = add(1, 2)\n" in
  let prog = Partial_app.run (parse src) in
  match body_of "main" prog with
  | App ("add", [Int 1; Int 2]) -> ()
  | _ -> Alcotest.fail "fully-applied call was rewritten"

let check_over_untouched () =
  (* over-application stays for typing's arity error *)
  let prog = Partial_app.run (parse
    "fun add(a: int, b: int): int = a + b\n\
     fun main(): int = add(1, 2, 3)\n") in
  match body_of "main" prog with
  | App ("add", [_; _; _]) -> ()
  | _ -> Alcotest.fail "over-applied call was rewritten"

let check_array_target_skipped () =
  (* arr params are not first-class; a temp can't hold one — skip *)
  let prog = Partial_app.run (parse
    "fun dot(a: arr[int, 4], b: arr[int, 4]): int = 0\n\
     fun main(): int = let g = dot(x) in 0\n") in
  match body_of "main" prog with
  | Let ("g", App ("dot", [Var "x"]), _) -> ()
  | _ -> Alcotest.fail "array-param target should not desugar"

let check_zero_supplied () =
  (* `add()` eta-expands: no temps, all params become lambda binders *)
  let prog = Partial_app.run (parse
    "fun add(a: int, b: int): int = a + b\n\
     fun main(): int = let f = add() in f(1, 2)\n") in
  match body_of "main" prog with
  | Let ("f", Lambda ([(p, _); (q, _)], App ("add", [Var p'; Var q'])), _)
    when p = p' && q = q' -> ()
  | _ -> Alcotest.fail "add() did not eta-expand to a 2-ary lambda"

let suite =
  [ ("partial_app", [
      Alcotest.test_case "under-applied desugars" `Quick check_under_applied;
      Alcotest.test_case "exact application untouched" `Quick check_exact_untouched;
      Alcotest.test_case "over-application untouched" `Quick check_over_untouched;
      Alcotest.test_case "array-param target skipped" `Quick check_array_target_skipped;
      Alcotest.test_case "zero-supplied eta-expands" `Quick check_zero_supplied;
    ]) ]
