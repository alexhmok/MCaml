(* typing_decls.ml — type/record declaration registration and the
   representability + arity/type-var-scope validators, plus
   [build_sigs]. Split from typing.ml in refactor step 7; re-exported
   through the Typing facade. *)
open Ast
open Typing_core
open Typing_unify

(* ADT ctor fields must be single-scoreboard-int values (§12.1 uniform
   representation): scalars and handles. TArrDyn is a (base, len) vreg
   PAIR per §3.4 so it doesn't fit one cell field — rejected in v1. *)
(* G4: arity + type-variable-scope validator (§13.11 decision 6). A
   SEPARATE walk from check_field_type/check_record_field_type (which
   check representability) — its only job is: does every TAdt
   application supply the right number of arguments, and does every
   TParam mention belong to the enclosing decl's own param list
   ([allowed_params], empty everywhere except while validating a type
   decl's own ctor fields)? OCaml's exhaustiveness checker cannot find
   missing call sites for this (a bad-arity type doesn't fail to
   compile on its own) — call sites are audited by hand:
   register_type_decl, register_record_decl, and build_sigs (every
   param/return annotation). *)
let rec check_typ_ok (allowed_params : string list) (t : typ) : unit =
  match resolve t with
  | TAdt (name, args) ->
      (if Hashtbl.mem adt_decls name || Hashtbl.mem record_decls name then
         let arity =
           match Hashtbl.find_opt adt_decls name with
           | Some (params, _) -> List.length params
           | None -> 0   (* record type: always arity 0 (decision 5) *)
         in
         if List.length args <> arity then
           raise (Error (Printf.sprintf
             "type %s expects %d type argument(s), got %d"
             name arity (List.length args))));
        (* an unknown name is reported by the representability checker
           that runs alongside this one; don't duplicate the message *)
      List.iter (check_typ_ok allowed_params) args
  | TParam p ->
      if not (List.mem p allowed_params) then
        raise (Error (Printf.sprintf "unbound type variable '%s" p))
  | TList t | TArrDyn t | TRef t | TArrStatic (t, _) | TMat (t, _, _) ->
      check_typ_ok allowed_params t
  | TTuple ts -> List.iter (check_typ_ok allowed_params) ts
  | TFun (ps, ret) ->
      List.iter (check_typ_ok allowed_params) ps;
      check_typ_ok allowed_params ret
  | TInt | TFloat | TBool | TUnit | TSelector | TPos | TVar _ -> ()

let rec check_field_type (decl : string) (cname : string) (ft : typ) : unit =
  match resolve ft with
  | TVar _ -> ()
      (* Phase E: an unbound tvar can only ever resolve to a single-int
         type (unify's tvar_bindable restriction), all of which are
         representable cell fields — so accepting it here is sound.
         Decl-time fields are always annotation-concrete anyway. *)
  | TInt | TFloat | TBool -> ()
  | TList _ -> ()   (* single int handle *)
  | TParam _ -> ()
      (* G4: a decl-side type var is representable by construction
         (every instantiation is one int, §13.1); scope (is this name
         actually one of THIS decl's own params?) is check_typ_ok's
         job, run alongside this checker at every registration site. *)
  | TTuple ts ->
      (* D7: a tuple is one objpool handle, so it fits a cell field.
         Its own elements must obey the same rules. *)
      List.iter (check_field_type decl cname) ts
  | TAdt (n, args) ->
      (* D8: record types are TAdt at the type level, so a ctor field
         may reference a declared record too. *)
      if not (Hashtbl.mem adt_decls n) && not (Hashtbl.mem record_decls n)
      then
        raise (Error (Printf.sprintf
          "type %s, constructor %s: unknown type '%s' in field — declare \
           it before this type (v1 has no forward references between \
           type declarations)" decl cname n))
      else List.iter (check_field_type decl cname) args
  | TArrDyn _ ->
      raise (Error (Printf.sprintf
        "type %s, constructor %s: darr fields are not supported in v1 \
         (a dynamic array is a base+len pair, not a single handle)"
        decl cname))
  | TUnit | TSelector | TPos ->
      raise (Error (Printf.sprintf
        "type %s, constructor %s: field type is not representable as an \
         ADT field" decl cname))
  | TArrStatic _ | TMat _ ->
      raise (Error (Printf.sprintf
        "type %s, constructor %s: static arrays/matrices are compile-time \
         storage, not first-class values — use a darr-free encoding or \
         a list" decl cname))
  | TRef _ ->
      raise (Error (Printf.sprintf
        "type %s, constructor %s: ref fields would break purity — \
         rejected" decl cname))
  | TFun _ ->
      raise (Error (Printf.sprintf
        "type %s, constructor %s: closures cannot be stored as an ADT \
         field in v1 — pass as a function argument, let-bind it, or \
         return it instead" decl cname))

let register_type_decl (name : string) (params : string list)
    (ctors : constructor list) : unit =
  if Hashtbl.mem adt_decls name || Hashtbl.mem record_decls name then
    raise (Error ("duplicate type declaration: " ^ name));
  if String.length name = 0
     || not ((name.[0] >= 'a' && name.[0] <= 'z') || name.[0] = '_') then
    raise (Error (Printf.sprintf
      "type name '%s' must start with a lowercase letter" name));
  (* Register the name (and its param list/arity) before validating
     fields so self-recursive/self-applied fields resolve — D3,
     extended by G4 to the param list too (`type 'a tree = Leaf | Node
     of 'a * 'a tree` needs tree's own arity in scope while checking
     its own fields). *)
  Hashtbl.replace adt_decls name (params, ctors);
  List.iteri (fun tag (cname, fields) ->
    if String.length cname = 0
       || not (cname.[0] >= 'A' && cname.[0] <= 'Z') then
      raise (Error (Printf.sprintf
        "type %s: constructor '%s' must be Capitalized (this is how \
         patterns tell constructors from variables)" name cname));
    if Hashtbl.mem ctor_info cname then
      raise (Error (Printf.sprintf
        "constructor %s is already declared by type %s — constructors \
         share one global namespace" cname
        (let (owner, _, _) = Hashtbl.find ctor_info cname in owner)));
    List.iter (check_field_type name cname) fields;
    List.iter (check_typ_ok params) fields;
    Hashtbl.replace ctor_info cname (name, fields, tag)
  ) ctors

(* D8: record registration. Same validation posture as
   register_type_decl, plus the global-field-namespace check. *)
let check_record_field_type (decl : string) (fname : string) (ft : typ)
    : unit =
  match resolve ft with
  | TVar _ -> ()   (* Phase E: see check_field_type's TVar note *)
  | TInt | TFloat | TBool | TList _ -> ()
  | TParam _ -> ()
      (* G4: representable in isolation; parameterized records are
         deferred (decision 5), so check_typ_ok — called alongside
         this checker with an EMPTY allowed-param set — is what
         actually rejects a bare 'a in a record field. *)
  | TTuple ts -> List.iter (check_field_type decl fname) ts
  | TAdt (n, args) ->
      if not (Hashtbl.mem adt_decls n) && not (Hashtbl.mem record_decls n)
      then
        raise (Error (Printf.sprintf
          "type %s, field %s: unknown type '%s' — declare it before \
           this type (v1 has no forward references between type \
           declarations)" decl fname n))
      else List.iter (check_field_type decl fname) args
  | TArrDyn _ ->
      raise (Error (Printf.sprintf
        "type %s, field %s: darr fields are not supported in v1 \
         (a dynamic array is a base+len pair, not a single handle)"
        decl fname))
  | TUnit | TSelector | TPos ->
      raise (Error (Printf.sprintf
        "type %s, field %s: field type is not representable as a \
         record field" decl fname))
  | TArrStatic _ | TMat _ ->
      raise (Error (Printf.sprintf
        "type %s, field %s: static arrays/matrices are compile-time \
         storage, not first-class values" decl fname))
  | TRef _ ->
      raise (Error (Printf.sprintf
        "type %s, field %s: ref fields would break purity — rejected"
        decl fname))
  | TFun _ ->
      raise (Error (Printf.sprintf
        "type %s, field %s: closures cannot be stored as a record \
         field in v1 — pass as a function argument, let-bind it, or \
         return it instead" decl fname))

let register_record_decl (name : string) (fields : (string * typ) list)
    : unit =
  if Hashtbl.mem adt_decls name || Hashtbl.mem record_decls name then
    raise (Error ("duplicate type declaration: " ^ name));
  if String.length name = 0
     || not ((name.[0] >= 'a' && name.[0] <= 'z') || name.[0] = '_') then
    raise (Error (Printf.sprintf
      "type name '%s' must start with a lowercase letter" name));
  if fields = [] then
    raise (Error (Printf.sprintf
      "record type %s must declare at least one field" name));
  (* Register the name first so self-recursive fields resolve
     (`type node = { v : int; next : node }` — the -1-free story for
     such a type is the user's problem, but the reference is legal). *)
  Hashtbl.replace record_decls name fields;
  List.iteri (fun idx (fname, ft) ->
    (match Hashtbl.find_opt record_fields fname with
     | Some (owner, _, _) ->
         raise (Error (Printf.sprintf
           "field %s is already declared by record type %s — field \
            names share one global namespace (like constructors)"
           fname owner))
     | None -> ());
    (* a duplicate inside THIS decl is caught the same way because we
       insert as we go *)
    check_record_field_type name fname ft;
    check_typ_ok [] ft;   (* G4: parameterized records deferred (decision 5) *)
    Hashtbl.replace record_fields fname (name, idx, ft)
  ) fields

let build_sigs (prog : program) : unit =
  Hashtbl.clear fun_sigs;
  Hashtbl.clear fun_schemes;
  List.iter (fun d ->
    match d with
    | Fun (name, params, ret, _) ->
        (* G4: fun signatures are the one surface-syntax annotation
           entry point with no dedicated representability checker
           (unlike ctor/record fields) — validate arity + type-var
           scope here (§13.11 decision 6). *)
        List.iter (fun (_, t) -> check_typ_ok [] t) params;
        check_typ_ok [] ret;
        Hashtbl.replace fun_sigs name (List.map snd params, ret)
    | Val _ | TypeDecl _ | RecordDecl _ -> ()
  ) prog
