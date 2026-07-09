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
type scheme = { qvars : Ast.typ option ref list; sbody : Ast.typ; }
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
