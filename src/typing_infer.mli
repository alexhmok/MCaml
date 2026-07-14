val infer : (string * Ast.typ) list -> Ast.expr -> Ast.typ
val type_fun_def :
  ?extra_env:(string * Ast.typ) list ->
  string -> (string * Ast.typ) list -> Ast.typ -> Ast.expr -> unit
