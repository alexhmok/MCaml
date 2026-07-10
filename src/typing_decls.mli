val check_field_type : string -> string -> Ast.typ -> unit
val register_type_decl :
  string -> string list -> Ast.constructor list -> unit
val register_record_decl : string -> (string * Ast.typ) list -> unit
val build_sigs : Ast.program -> unit
