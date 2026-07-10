val string_of_pattern : Ast.pattern -> string
val check_pattern : Ast.typ -> Ast.pattern -> (string * Ast.typ) list
val check_tuple_elem : Ast.typ -> unit
val split_at : int -> 'a list -> 'a list * 'a list
val useful :
  Ast.typ list ->
  Ast.pattern list list -> Ast.pattern list -> Ast.pattern list option
