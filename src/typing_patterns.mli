val string_of_pattern : Ast.pattern -> string
val check_pattern : Ast.typ -> Ast.pattern -> (string * Ast.typ) list
val check_tuple_elem : Ast.typ -> unit
val wilds : int -> Ast.pattern list
val split_at : int -> 'a list -> 'a list * 'a list
val specialize_ctor :
  string -> int -> Ast.pattern list list -> Ast.pattern list list
val specialize_int : int -> Ast.pattern list list -> Ast.pattern list list
val specialize_tuple : int -> Ast.pattern list list -> Ast.pattern list list
val record_row :
  (string * Ast.typ) list -> (string * Ast.pattern) list -> Ast.pattern list
val specialize_record :
  (string * Ast.typ) list -> Ast.pattern list list -> Ast.pattern list list
val specialize_nil : Ast.pattern list list -> Ast.pattern list list
val specialize_cons : Ast.pattern list list -> Ast.pattern list list
val default_matrix : Ast.pattern list list -> Ast.pattern list list
val useful :
  Ast.typ list ->
  Ast.pattern list list -> Ast.pattern list -> Ast.pattern list option
