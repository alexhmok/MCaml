exception Error of string
val fun_sigs : (string, Ast.typ list * Ast.typ) Hashtbl.t
val global_vals : (string, Ast.typ) Hashtbl.t
val register_global_val : string -> Ast.typ -> unit
val adt_decls : (string, string list * Ast.constructor list) Hashtbl.t
val ctor_info : (string, string * Ast.typ list * int) Hashtbl.t
val is_constructor : string -> bool
val record_decls : (string, (string * Ast.typ) list) Hashtbl.t
val record_fields : (string, string * int * Ast.typ) Hashtbl.t
val is_record_type : string -> bool
