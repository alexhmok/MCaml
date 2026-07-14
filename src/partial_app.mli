(* Explicit partial application: desugars under-applied calls to known
   top-level functions into let-temps + a lambda, post-alpha and
   pre-for_lift. See partial_app.ml for scope and skip rules. *)

val run : Ast.def list -> Ast.def list
