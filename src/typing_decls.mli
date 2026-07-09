val check_typ_ok : string list -> Ast.typ -> unit
val check_field_type : string -> string -> Ast.typ -> unit
val register_type_decl :
  string -> string list -> Ast.constructor list -> unit
val check_record_field_type : string -> string -> Ast.typ -> unit
val register_record_decl : string -> (string * Ast.typ) list -> unit
val build_sigs : Ast.program -> unit
