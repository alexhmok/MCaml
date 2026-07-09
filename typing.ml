(* typing.ml — facade over the typing units (refactor step 7). The
   implementation lives in typing_core (shared Error exception +
   global tables), typing_unify (HM engine, §13.10), typing_decls
   (type/record registration + build_sigs), typing_patterns (pattern
   typing + Maranget usefulness) and typing_infer (the infer walk +
   type_fun_def). This include chain preserves the historical
   [Typing.*] interface that main.ml / knormal.ml / for_lift.ml /
   alpha.ml reference — including [Typing.Error]'s identity: [include]
   re-exports the SAME exception constructor, so main.ml's handler
   and exit code are unchanged. *)
include Typing_core
include Typing_unify
include Typing_decls
include Typing_patterns
include Typing_infer
