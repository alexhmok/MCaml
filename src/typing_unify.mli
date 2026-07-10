val resolve : Ast.typ -> Ast.typ
val fresh_tvar : unit -> Ast.typ
val string_of_typ : Ast.typ -> string
exception Unify_fail of Ast.typ * Ast.typ
val tvar_bindable : Ast.typ -> string option
val unify : Ast.typ -> Ast.typ -> unit
val unify_msg : Ast.typ -> Ast.typ -> string -> unit
val zonk_default : Ast.typ -> Ast.typ
type scheme = { qvars : Ast.typ option ref list; sbody : Ast.typ; }
val mono : Ast.typ -> scheme
val instantiate : scheme -> Ast.typ
val subst_typarams : (string * Ast.typ) list -> Ast.typ -> Ast.typ
val is_value : Ast.expr -> bool
val generalize : (string * scheme) list -> string -> Ast.typ -> scheme
val fun_schemes :
  (string, Ast.typ option ref list * Ast.typ list * Ast.typ) Hashtbl.t
val generalize_fun : string -> Ast.typ list -> Ast.typ -> unit
val instantiate_fun :
  Ast.typ option ref list * Ast.typ list * Ast.typ -> Ast.typ list * Ast.typ
