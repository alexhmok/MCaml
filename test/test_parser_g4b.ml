(* G4b grammar pins: multi-param type decls, multi-arg type application,
   and n-ary arrow annotations — the three forms G4 deferred and F1's
   session notes wrongly recorded as LALR(1)-infeasible (the comma-list
   formulation disambiguates on one token; menhir generates with zero
   conflicts). These tests parse strings straight through
   Parser.prog/Lexer.read and assert AST shapes, so a grammar
   regression fails here without needing the full pipeline. *)

open Ast

let parse (src : string) : Ast.program =
  Parser.prog Lexer.read (Lexing.from_string src)

(* Every expected tree below is TVar-free, so structural (=) is sound. *)
let first_param_typ (src : string) : typ =
  match parse src with
  | Fun (_, (_, t) :: _, _, _) :: _ -> t
  | _ -> Alcotest.fail "expected a Fun def with at least one param"

let check_typ msg expected actual =
  if expected <> actual then Alcotest.failf "%s: parsed typ differs" msg

let check_multi_param_decl () =
  match parse "type ('a, 'b) either = Left of 'a | Right of 'b\n" with
  | [ TypeDecl ("either", ["a"; "b"],
        [("Left", [TParam "a"]); ("Right", [TParam "b"])]) ] -> ()
  | _ -> Alcotest.fail "multi-param decl did not parse to expected TypeDecl"

let check_single_param_back_compat () =
  match parse "type 'a box = Box of 'a\n" with
  | [ TypeDecl ("box", ["a"], [("Box", [TParam "a"])]) ] -> ()
  | _ -> Alcotest.fail "single-param decl regressed"

let check_multi_arg_application () =
  check_typ "(int, bool) either"
    (TAdt ("either", [TInt; TBool]))
    (first_param_typ "fun f(x: (int, bool) either): int = 0\n");
  check_typ "nested application"
    (TAdt ("either", [TInt; TAdt ("either", [TInt; TBool])]))
    (first_param_typ "fun f(x: (int, (int, bool) either) either): int = 0\n")

let check_nary_arrow () =
  check_typ "(int, int) -> int"
    (TFun ([TInt; TInt], TInt))
    (first_param_typ "fun f(g: (int, int) -> int): int = 0\n");
  check_typ "arrow arg inside n-ary arrow"
    (TFun ([TFun ([TInt; TInt], TInt); TInt], TInt))
    (first_param_typ "fun f(g: ((int, int) -> int, int) -> int): int = 0\n")

let check_grouping_still_works () =
  check_typ "(int * int) option"
    (TAdt ("option", [TTuple [TInt; TInt]]))
    (first_param_typ "fun f(x: (int * int) option): int = 0\n");
  check_typ "plain grouping (int)"
    TInt
    (first_param_typ "fun f(x: (int)): int = 0\n");
  check_typ "tuple-arrow unchanged: int * int -> int is 1-ary on a tuple"
    (TFun ([TTuple [TInt; TInt]], TInt))
    (first_param_typ "fun f(g: int * int -> int): int = 0\n")

let suite =
  [ ("parser_g4b", [
      Alcotest.test_case "multi-param decl" `Quick check_multi_param_decl;
      Alcotest.test_case "single-param back-compat" `Quick check_single_param_back_compat;
      Alcotest.test_case "multi-arg type application" `Quick check_multi_arg_application;
      Alcotest.test_case "n-ary arrow annotation" `Quick check_nary_arrow;
      Alcotest.test_case "grouping/tuple arms unchanged" `Quick check_grouping_still_works;
    ]) ]
