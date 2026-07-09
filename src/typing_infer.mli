val check_match_redundancy : Ast.typ -> Ast.pattern list list -> unit
val check_match_exhaustive : Ast.typ -> Ast.pattern list list -> unit
val is_builtin_app : string -> Ast.expr list -> bool
val infer_builtin_app :
  (string * Typing_unify.scheme) list -> string -> Ast.expr list -> Ast.typ
val infer : (string * Ast.typ) list -> Ast.expr -> Ast.typ
val type_fun_def :
  string -> (string * Ast.typ) list -> Ast.typ -> Ast.expr -> unit
