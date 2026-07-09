(* typing_core.ml — shared base of the typing units (split from
   typing.ml in refactor step 7): the [Error] exception every unit
   raises (main.ml catches it as [Typing.Error] through the facade),
   plus the global mutable environments (function signatures, global
   vals, ADT/record declarations). *)
open Ast

exception Error of string

(* Global function signature table. Populated by [build_sigs] on the
   post-for_lift program. Consulted by the [App] rule so that calls type
   against the callee's declared parameter/return types instead of the
   legacy "always TInt" fallback. Lookup miss => TInt fallback
   (preserves behavior for synthesized helpers and any untyped callees). *)
let fun_sigs : (string, typ list * typ) Hashtbl.t = Hashtbl.create 16

(* Phase G: type environment for top-level `val` definitions. Populated
   by [register_global_val] from main.ml before Phase 1 runs. The Var
   typing arm falls back to this table when a name is not in the local
   env, so per-function typing sees global vals as if they were
   free-variable bindings of the declared type. *)
let global_vals : (string, typ) Hashtbl.t = Hashtbl.create 4

let register_global_val (name : string) (ty : typ) : unit =
  Hashtbl.replace global_vals name ty

(* ---- Phase D: nominal ADT environment ------------------------------- *)

(* type name -> (param names in decl order, constructor list). G4:
   the value widened to carry the decl's own type-param list ([] for
   non-parameterized decls) so ctor use/pattern sites can build the
   TParam -> actual-arg substitution (§13.11 decision 2/6). *)
let adt_decls : (string, string list * constructor list) Hashtbl.t =
  Hashtbl.create 8

(* ctor name -> (owning type, field types, tag).
   Tags are declaration-order indices 0..n-1; D5's decision trees
   dispatch on them with `execute if score ... matches <tag>` and D4's
   cell layout stores them in the `tag` field. Constructors share ONE
   global namespace (like OCaml within a module) so an unqualified
   ctor in a pattern resolves without a type ascription. *)
let ctor_info : (string, string * typ list * int) Hashtbl.t = Hashtbl.create 16

let is_constructor (name : string) : bool = Hashtbl.mem ctor_info name

(* ---- D8: nominal record environment --------------------------------- *)

(* record type name -> fields in declaration order. Disjoint from
   adt_decls by construction (registration rejects collisions), but a
   record VALUE still types as TAdt name — no new typ constructor —
   so param passing, field representability, and the D5 region-return
   rejection reuse the TAdt arms. *)
let record_decls : (string, (string * typ) list) Hashtbl.t =
  Hashtbl.create 8

(* field name -> (owner record type, decl-order index, field type).
   ONE GLOBAL FIELD NAMESPACE (mirrors D3's global ctor namespace):
   a field name belongs to at most one record type, which is what lets
   `{ x = 1; y = 2 }` and `r.x` resolve without type annotations. *)
let record_fields : (string, string * int * typ) Hashtbl.t =
  Hashtbl.create 16

let is_record_type (name : string) : bool = Hashtbl.mem record_decls name
