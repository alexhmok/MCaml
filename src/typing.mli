exception Error of string
val fun_sigs : (string, Ast.typ list * Ast.typ) Hashtbl.t
val global_vals : (string, Ast.typ) Hashtbl.t
val register_global_val : string -> Ast.typ -> unit
val adt_decls : (string, string list * Ast.constructor list) Hashtbl.t
val ctor_info : (string, string * Ast.typ list * int) Hashtbl.t
val is_constructor : string -> bool
val record_decls : (string, (string * Ast.typ) list) Hashtbl.t
val record_fields : (string, string * int * Ast.typ) Hashtbl.t
val resolve : Ast.typ -> Ast.typ
val fresh_tvar : unit -> Ast.typ
val tvar_names : (Ast.typ option ref * string) list ref
val tvar_name : Ast.typ option ref -> string
val string_of_typ : Ast.typ -> string
val occurs : Ast.typ option ref -> Ast.typ -> bool
exception Unify_fail of Ast.typ * Ast.typ
val tvar_bindable : Ast.typ -> string option
val unify : Ast.typ -> Ast.typ -> unit
val unify_msg : Ast.typ -> Ast.typ -> string -> unit
val zonk_default : Ast.typ -> Ast.typ
type scheme =
  Typing_unify.scheme = {
  qvars : Ast.typ option ref list;
  sbody : Ast.typ;
}
val mono : Ast.typ -> scheme
val copy_with : (Ast.typ option ref * Ast.typ) list -> Ast.typ -> Ast.typ
val instantiate : scheme -> Ast.typ
val subst_typarams : (string * Ast.typ) list -> Ast.typ -> Ast.typ
val free_tvars :
  Ast.typ option ref list -> Ast.typ -> Ast.typ option ref list
val scheme_free_tvars :
  Ast.typ option ref list -> scheme -> Ast.typ option ref list
val global_free_tvars : except:string -> unit -> Ast.typ option ref list
val is_value : Ast.expr -> bool
val generalize : (string * scheme) list -> string -> Ast.typ -> scheme
val fun_schemes :
  (string, Ast.typ option ref list * Ast.typ list * Ast.typ) Hashtbl.t
val generalize_fun : string -> Ast.typ list -> Ast.typ -> unit
val instantiate_fun :
  Ast.typ option ref list * Ast.typ list * Ast.typ -> Ast.typ list * Ast.typ
val check_typ_ok : string list -> Ast.typ -> unit
val check_field_type : string -> string -> Ast.typ -> unit
val register_type_decl :
  string -> string list -> Ast.constructor list -> unit
val check_record_field_type : string -> string -> Ast.typ -> unit
val register_record_decl : string -> (string * Ast.typ) list -> unit
val build_sigs : Ast.program -> unit
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
val infer : (string * Ast.typ) list -> Ast.expr -> Ast.typ
val type_fun_def :
  string -> (string * Ast.typ) list -> Ast.typ -> Ast.expr -> unit
