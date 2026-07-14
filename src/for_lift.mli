val is_synthetic_name : string -> bool
val ref_captures_of : string -> (string * Ast.typ) list
val run : Ast.program -> Ast.program
