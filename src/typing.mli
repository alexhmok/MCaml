exception Error of string
val fun_sigs : (string, Ast.typ list * Ast.typ) Hashtbl.t
val register_global_val : string -> Ast.typ -> unit
val adt_decls : (string, string list * Ast.constructor list) Hashtbl.t
val ctor_info : (string, string * Ast.typ list * int) Hashtbl.t
val is_constructor : string -> bool
val record_decls : (string, (string * Ast.typ) list) Hashtbl.t
val record_fields : (string, string * int * Ast.typ) Hashtbl.t
exception Unify_fail of Ast.typ * Ast.typ
val zonk_default : Ast.typ -> Ast.typ
type scheme =
  Typing_unify.scheme = {
  qvars : Ast.typ option ref list;
  sbody : Ast.typ;
}
val register_type_decl :
  string -> string list -> Ast.constructor list -> unit
val register_record_decl : string -> (string * Ast.typ) list -> unit
val build_sigs : Ast.program -> unit
val infer : (string * Ast.typ) list -> Ast.expr -> Ast.typ
val type_fun_def :
  string -> (string * Ast.typ) list -> Ast.typ -> Ast.expr -> unit
