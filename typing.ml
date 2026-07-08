(* typing.ml *)
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

(* ---- Phase E: Hindley-Milner unification engine (§13.10) ------------- *)

(* Destructive tvars: TVar (ref None) = unbound, TVar (ref (Some t)) =
   linked. [resolve] follows the link spine with path compression; it
   returns a typ whose HEAD constructor is never a bound TVar (an
   unbound TVar can still appear, and bound TVars may survive deeper
   inside — use [zonk_default] when a fully-concrete typ is required). *)
let rec resolve (t : typ) : typ =
  match t with
  | TVar r ->
      (match !r with
       | Some t' ->
           let t'' = resolve t' in
           r := Some t'';
           t''
       | None -> t)
  | _ -> t

let fresh_tvar () : typ = TVar (ref None)

(* Stable display names for unbound tvars ('a, 'b, ... then 't26, ...)
   keyed by ref identity, so one error message naming two types renders
   a shared tvar consistently. Compilation aborts on the first Error,
   so the table never grows meaningfully. *)
let tvar_names : (typ option ref * string) list ref = ref []

let tvar_name (r : typ option ref) : string =
  match List.find_opt (fun (r', _) -> r' == r) !tvar_names with
  | Some (_, n) -> n
  | None ->
      let i = List.length !tvar_names in
      let n =
        if i < 26 then Printf.sprintf "'%c" (Char.chr (Char.code 'a' + i))
        else Printf.sprintf "'t%d" i
      in
      tvar_names := (r, n) :: !tvar_names;
      n

let rec string_of_typ (t : typ) : string =
  match resolve t with
  | TInt -> "int"
  | TFloat -> "float"
  | TBool -> "bool"
  | TUnit -> "unit"
  | TSelector -> "selector"
  | TPos -> "pos"
  | TArrStatic (t, n) -> Printf.sprintf "arr[%s, %d]" (string_of_typ t) n
  | TMat (t, m, n) -> Printf.sprintf "mat[%s, %d, %d]" (string_of_typ t) m n
  | TArrDyn t -> Printf.sprintf "darr[%s]" (string_of_typ t)
  | TRef t -> "ref " ^ string_of_typ t
  | TList t -> string_of_typ t ^ " list"
  | TTuple ts ->
      "(" ^ String.concat " * " (List.map string_of_typ ts) ^ ")"
  | TAdt (n, []) -> n
  | TAdt (n, [a]) -> string_of_typ a ^ " " ^ n
  | TAdt (n, args) ->
      "(" ^ String.concat ", " (List.map string_of_typ args) ^ ") " ^ n
  | TVar r -> tvar_name r
  | TParam p -> "'" ^ p
  | TFun (ps, ret) ->
      let params_str =
        match ps with
        | [] -> "()"
        | [t] -> string_of_typ t
        | ts -> "(" ^ String.concat ", " (List.map string_of_typ ts) ^ ")"
      in
      params_str ^ " -> " ^ string_of_typ ret

let rec occurs (r : typ option ref) (t : typ) : bool =
  match resolve t with
  | TVar r' -> r == r'
  | TList t | TArrDyn t | TRef t | TArrStatic (t, _) | TMat (t, _, _) ->
      occurs r t
  | TTuple ts -> List.exists (occurs r) ts
  | TAdt (_, args) -> List.exists (occurs r) args
  | TFun (ps, ret) -> List.exists (occurs r) ps || occurs r ret
  | TInt | TFloat | TBool | TUnit | TSelector | TPos | TParam _ -> false

exception Unify_fail of typ * typ

(* §13.10 amendment (discovered in E2): a tvar may only bind to a type
   whose runtime value is ONE scoreboard int — TInt/TFloat/TBool and the
   handle types TList/TTuple/TAdt (or another tvar). Binding to TArrDyn
   (a base+len vreg PAIR), TArrStatic/TMat (compile-time storage, and
   the monomorphize template trigger), TRef (global slot, second-class),
   or TUnit/TSelector/TPos would let a polymorphic function silently
   miscompile — e.g. a generalized `fun pair_up(x) = (x, 0)` applied to
   a darr would drop the length vreg. Non-uniform params keep requiring
   explicit annotations, exactly as they do today. *)
let tvar_bindable (t : typ) : string option =
  match t with
  | TInt | TFloat | TBool | TList _ | TTuple _ | TAdt _ | TVar _
  | TFun _ -> None
  | TArrDyn _ -> Some "darr"
  | TArrStatic _ -> Some "static array"
  | TMat _ -> Some "matrix"
  | TRef _ -> Some "ref"
  | TUnit -> Some "unit"
  | TSelector -> Some "selector"
  | TPos -> Some "pos"
  (* G4: unreachable in practice — unify's TParam intercept (below)
     fires before a TVar-binding arm could ever see one. Arm exists
     only because TParam is a new typ constructor (exhaustiveness). *)
  | TParam _ -> Some "type parameter"

let rec unify (t1 : typ) (t2 : typ) : unit =
  let t1 = resolve t1 and t2 = resolve t2 in
  match t1, t2 with
  (* G4: a decl-side type param must always be substituted away (by
     instantiate_ctor / subst_typarams, §13.11 decision 6) before
     reaching unify. Intercept BEFORE the generic TVar arm below so a
     TVar-vs-TParam pairing doesn't silently destructive-bind. *)
  | TParam p, _ | _, TParam p ->
      raise (Error (Printf.sprintf
        "internal: unsubstituted type parameter '%s reached \
         unification — this is a compiler bug" p))
  | TVar r1, TVar r2 when r1 == r2 -> ()
  | TVar r, t | t, TVar r ->
      if occurs r t then
        raise (Error (Printf.sprintf
          "occurs check failed: the type variable %s occurs inside %s — \
           cannot construct an infinite type (a value cannot contain \
           itself, e.g. `x :: x`)"
          (tvar_name r) (string_of_typ t)));
      (match tvar_bindable t with
       | Some kind ->
           raise (Error (Printf.sprintf
             "cannot infer a polymorphic type for a %s value — type \
              variables range over single-scoreboard-int values \
              (int/float/bool/list/tuple/ADT); annotate the parameter \
              explicitly" kind))
       | None -> ());
      r := Some t
  | TInt, TInt | TFloat, TFloat | TBool, TBool | TUnit, TUnit
  | TSelector, TSelector | TPos, TPos -> ()
  | TList a, TList b -> unify a b
  | TArrDyn a, TArrDyn b -> unify a b
  | TRef a, TRef b -> unify a b
  | TArrStatic (a, n), TArrStatic (b, m) when n = m -> unify a b
  | TMat (a, r1, c1), TMat (b, r2, c2) when r1 = r2 && c1 = c2 -> unify a b
  | TTuple xs, TTuple ys when List.length xs = List.length ys ->
      List.iter2 unify xs ys
  | TAdt (a, args_a), TAdt (b, args_b)
    when a = b && List.length args_a = List.length args_b ->
      List.iter2 unify args_a args_b
  | TFun (p1, r1), TFun (p2, r2) when List.length p1 = List.length p2 ->
      List.iter2 unify p1 p2; unify r1 r2
  | _ -> raise (Unify_fail (t1, t2))

(* Unify with a legacy error message: every type check that predates
   Phase E keeps its exact error string by routing through this. *)
let unify_msg (t1 : typ) (t2 : typ) (msg : string) : unit =
  try unify t1 t2 with Unify_fail _ -> raise (Error msg)

(* Unify on a new (Phase E) path: the default diagnostic names both
   types (E8 quality requirement). *)
let unify_types (t1 : typ) (t2 : typ) : unit =
  try unify t1 t2
  with Unify_fail (a, b) ->
    raise (Error (Printf.sprintf "cannot unify %s with %s"
                    (string_of_typ a) (string_of_typ b)))

(* Fully resolve a typ, binding any still-unbound tvar to TInt
   (§13.10 decision 5 — sound under §13.1 uniform representation).
   This is the knormal-boundary zonk (E6) and the Region typ-ref
   writer; the result contains no TVar at any depth. *)
let rec zonk_default (t : typ) : typ =
  match resolve t with
  | TVar r -> r := Some TInt; TInt
  | TList t -> TList (zonk_default t)
  | TArrDyn t -> TArrDyn (zonk_default t)
  | TRef t -> TRef (zonk_default t)
  | TArrStatic (t, n) -> TArrStatic (zonk_default t, n)
  | TMat (t, m, n) -> TMat (zonk_default t, m, n)
  | TTuple ts -> TTuple (List.map zonk_default ts)
  | TAdt (n, args) -> TAdt (n, List.map zonk_default args)
  | TFun (ps, ret) -> TFun (List.map zonk_default ps, zonk_default ret)
  | (TInt | TFloat | TBool | TUnit | TSelector | TPos | TParam _) as t -> t

(* ---- Schemes (§13.10 decision 2: env-side, typ stays scheme-free) --- *)

type scheme = { qvars : typ option ref list; sbody : typ }

let mono (t : typ) : scheme = { qvars = []; sbody = t }

(* Copy a typ, substituting fresh tvars for the quantified refs in
   [mapping]. Resolving first means a qvar that got destructively
   bound AFTER generalization (a forward call constraining a later
   def, §13.10 decision 7) transparently copies as its resolved type. *)
let rec copy_with (mapping : (typ option ref * typ) list) (t : typ) : typ =
  match resolve t with
  | TVar r ->
      (match List.find_opt (fun (q, _) -> q == r) mapping with
       | Some (_, f) -> f
       | None -> TVar r)
  | TList t -> TList (copy_with mapping t)
  | TArrDyn t -> TArrDyn (copy_with mapping t)
  | TRef t -> TRef (copy_with mapping t)
  | TArrStatic (t, n) -> TArrStatic (copy_with mapping t, n)
  | TMat (t, m, n) -> TMat (copy_with mapping t, m, n)
  | TTuple ts -> TTuple (List.map (copy_with mapping) ts)
  | TAdt (n, args) -> TAdt (n, List.map (copy_with mapping) args)
  | TFun (ps, ret) ->
      TFun (List.map (copy_with mapping) ps, copy_with mapping ret)
  | (TInt | TFloat | TBool | TUnit | TSelector | TPos | TParam _) as t -> t

let instantiate (s : scheme) : typ =
  match s.qvars with
  | [] -> s.sbody
  | qs ->
      let mapping = List.map (fun q -> (q, fresh_tvar ())) qs in
      copy_with mapping s.sbody

(* ---- G4: decl-side type-parameter substitution (§13.11 decision 6) -- *)

(* Structurally identical recursion to [copy_with], but keyed by
   string NAME (a decl's own 'a/'b binders) rather than TVar ref
   physical identity — a genuinely separate substitution axis, not a
   variant of copy_with. Used to instantiate a ctor's raw (TParam-
   bearing) field types at every application/pattern/Maranget site. A
   name absent from [mapping] is left unchanged (should not happen —
   registration validates every TParam in a decl's fields is one of
   its own declared params — but this stays total rather than
   partial). *)
let rec subst_typarams (mapping : (string * typ) list) (t : typ) : typ =
  match t with
  | TParam p ->
      (match List.assoc_opt p mapping with Some ty -> ty | None -> t)
  | TList t -> TList (subst_typarams mapping t)
  | TArrDyn t -> TArrDyn (subst_typarams mapping t)
  | TRef t -> TRef (subst_typarams mapping t)
  | TArrStatic (t, n) -> TArrStatic (subst_typarams mapping t, n)
  | TMat (t, m, n) -> TMat (subst_typarams mapping t, m, n)
  | TTuple ts -> TTuple (List.map (subst_typarams mapping) ts)
  | TAdt (n, args) -> TAdt (n, List.map (subst_typarams mapping) args)
  | TFun (ps, ret) ->
      TFun (List.map (subst_typarams mapping) ps, subst_typarams mapping ret)
  | TInt | TFloat | TBool | TUnit | TSelector | TPos | TVar _ -> t

(* ---- E3: generalization (scan-the-env, §13.10 decision 1) ----------- *)

(* Unbound tvar refs reachable from [t], deduped by ref identity. *)
let rec free_tvars (acc : typ option ref list) (t : typ)
    : typ option ref list =
  match resolve t with
  | TVar r -> if List.exists (fun r' -> r' == r) acc then acc else r :: acc
  | TList t | TArrDyn t | TRef t | TArrStatic (t, _) | TMat (t, _, _) ->
      free_tvars acc t
  | TTuple ts -> List.fold_left free_tvars acc ts
  | TAdt (_, args) -> List.fold_left free_tvars acc args
  | TFun (ps, ret) -> List.fold_left free_tvars acc (ret :: ps)
  | TInt | TFloat | TBool | TUnit | TSelector | TPos | TParam _ -> acc

let scheme_free_tvars (acc : typ option ref list) (s : scheme)
    : typ option ref list =
  List.fold_left (fun acc r ->
    if List.exists (fun q -> q == r) s.qvars then acc
    else if List.exists (fun r' -> r' == r) acc then acc
    else r :: acc) acc (free_tvars [] s.sbody)

(* Tvars free in the GLOBAL tables (fun_sigs entries other than
   [except], plus global_vals). A tvar shared with another function's
   still-uninferred signature must not be quantified — the constraint
   linking the two defs would silently evaporate at instantiation. *)
let global_free_tvars ~(except : string) () : typ option ref list =
  let acc =
    Hashtbl.fold (fun name (params, ret) acc ->
      if name = except then acc
      else List.fold_left free_tvars acc (ret :: params))
      fun_sigs []
  in
  Hashtbl.fold (fun _ t acc -> free_tvars acc t) global_vals acc

(* §13.10 decision 3: only syntactic values generalize. *)
let rec is_value (e : expr) : bool =
  match e with
  | Int _ | Float _ | Bool _ | Unit | Nil | Var _ -> true
  | Tuple es -> List.for_all is_value es
  | Record fs -> List.for_all (fun (_, e) -> is_value e) fs
  | Cons (h, t) -> is_value h && is_value t
  | App (f, args) when Hashtbl.mem ctor_info f -> List.for_all is_value args
  | _ -> false

let generalize (env : (string * scheme) list) (name : string) (t : typ)
    : scheme =
  let outside =
    List.fold_left (fun acc (_, s) -> scheme_free_tvars acc s)
      (global_free_tvars ~except:name ()) env
  in
  let qs =
    List.filter (fun r -> not (List.exists (fun r' -> r' == r) outside))
      (free_tvars [] t)
  in
  { qvars = qs; sbody = t }

(* ---- E3/E4: generalized function signatures -------------------------- *)

(* name -> (qvars, param typs, return typ). Populated by
   [generalize_fun] right after a def's body is inferred; consulted by
   the App rule BEFORE fun_sigs (a hit here instantiates fresh tvars
   per call site; a miss falls back to the raw monotype in fun_sigs —
   which is exactly what self-recursion and forward calls want,
   §13.10 decision 7). *)
let fun_schemes
    : (string, typ option ref list * typ list * typ) Hashtbl.t =
  Hashtbl.create 16

let generalize_fun (name : string) (params : typ list) (ret : typ) : unit =
  let outside = global_free_tvars ~except:name () in
  let free = List.fold_left free_tvars [] (ret :: params) in
  let qs =
    List.filter (fun r -> not (List.exists (fun r' -> r' == r) outside))
      free
  in
  Hashtbl.replace fun_schemes name (qs, params, ret)

let instantiate_fun (qs, params, ret) : typ list * typ =
  if qs = [] then (params, ret)
  else begin
    let mapping = List.map (fun q -> (q, fresh_tvar ())) qs in
    (List.map (copy_with mapping) params, copy_with mapping ret)
  end

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

(* ---- Phase D: pattern typing + Maranget usefulness ------------------ *)

let rec string_of_pattern (p : pattern) : string =
  match p with
  | PWild -> "_"
  | PVar x -> x
  | PInt i -> string_of_int i
  | PCtor (c, []) -> c
  | PCtor (c, ps) ->
      c ^ "(" ^ String.concat ", " (List.map string_of_pattern ps) ^ ")"
  | PNil -> "[]"
  | PCons (ph, pt) ->
      (* Parenthesized so a witness nested in ctor args stays readable *)
      "(" ^ string_of_pattern ph ^ " :: " ^ string_of_pattern pt ^ ")"
  | PTuple ps ->
      "(" ^ String.concat ", " (List.map string_of_pattern ps) ^ ")"
  | PRecord fields ->
      "{" ^ String.concat "; "
              (List.map (fun (f, p) -> f ^ " = " ^ string_of_pattern p)
                 fields)
      ^ "}"

(* Validate a pattern against the scrutinee type; return its binders.
   Duplicate binders inside one pattern are caught in alpha.ml
   (rename_pattern), because alpha's renaming makes them invisible
   here. *)
let rec check_pattern (t : typ) (p : pattern) : (string * typ) list =
  match p with
  | PWild -> []
  | PVar x -> [(x, t)]
  | PInt _ ->
      unify_msg t TInt (Printf.sprintf
        "int literal pattern %s requires an int scrutinee"
        (string_of_pattern p));
      []
  | PNil ->
      (* E4b: element-generic — a tvar scrutinee pins to a fresh list. *)
      unify_msg t (TList (fresh_tvar ()))
        "pattern [] requires a list scrutinee";
      []
  | PCons (ph, pt) ->
      (* E4b: 'a list — the head sub-pattern checks against the
         element type, so ctor-in-list patterns (`Circle(r) :: t`) are
         now typeable (the D6 scope note coming due). *)
      let elem = fresh_tvar () in
      unify_msg t (TList elem) "pattern _ :: _ requires a list scrutinee";
      check_pattern elem ph @ check_pattern (TList elem) pt
  | PRecord fields ->
      (match resolve t with
       | TVar _ ->
           (* Phase E: an unannotated scrutinee — resolve the owner
              record type from the first field name (one global field
              namespace, same rule as the Record literal arm), pin the
              scrutinee, and re-dispatch on the now-concrete type. *)
           (match fields with
            | [] -> raise (Error "record pattern requires a record scrutinee")
            | (f0, _) :: _ ->
                (match Hashtbl.find_opt record_fields f0 with
                 | Some (owner, _, _) ->
                     unify_msg t (TAdt (owner, []))
                       "record pattern requires a record scrutinee";
                     check_pattern (TAdt (owner, [])) p
                 | None ->
                     raise (Error (Printf.sprintf
                       "unknown record field %s" f0))))
       | TAdt (name, _) when Hashtbl.mem record_decls name ->
           let decl = Hashtbl.find record_decls name in
           (* dup fields within the pattern *)
           let rec dup = function
             | (a, _) :: rest ->
                 if List.mem_assoc a rest then Some a else dup rest
             | [] -> None
           in
           (match dup fields with
            | Some f ->
                raise (Error (Printf.sprintf
                  "record pattern mentions field %s twice" f))
            | None -> ());
           List.concat
             (List.map (fun (f, p) ->
                match List.assoc_opt f decl with
                | Some ft -> check_pattern ft p
                | None ->
                    raise (Error (Printf.sprintf
                      "record type %s has no field %s" name f)))
               fields)
       | _ ->
           raise (Error "record pattern requires a record scrutinee"))
  | PTuple ps ->
      (match resolve t with
       | TTuple ts ->
           if List.length ts <> List.length ps then
             raise (Error (Printf.sprintf
               "tuple pattern has %d component(s) but the scrutinee is \
                a %d-tuple" (List.length ps) (List.length ts)));
           List.concat (List.map2 check_pattern ts ps)
       | TVar _ ->
           (* Phase E: pin an unannotated scrutinee to a tuple of the
              pattern's arity with fresh element tvars. *)
           let ts = List.map (fun _ -> fresh_tvar ()) ps in
           unify_msg t (TTuple ts)
             "tuple pattern requires a tuple scrutinee";
           List.concat (List.map2 check_pattern ts ps)
       | _ ->
           raise (Error "tuple pattern requires a tuple scrutinee"))
  | PCtor (c, ps) ->
      (match Hashtbl.find_opt ctor_info c with
       | None ->
           raise (Error ("Unknown constructor in pattern: " ^ c))
       | Some (adt, raw_fields, _) ->
           (* G4: instantiate the owner's params — mint fresh tvars and
              pin the scrutinee if it's still unresolved, or reuse the
              scrutinee's OWN already-known args, then substitute them
              into raw_fields before recursing (§13.11 decision 6). *)
           let (owner_params, _) = Hashtbl.find adt_decls adt in
           let args =
             match resolve t with
             | TVar _ ->
                 let fresh = List.map (fun _ -> fresh_tvar ()) owner_params in
                 unify_msg t (TAdt (adt, fresh)) (Printf.sprintf
                   "constructor pattern %s requires a scrutinee of type %s"
                   c adt);
                 fresh
             | TAdt (name, args) when name = adt -> args
             | TAdt (name, _) ->
                 raise (Error (Printf.sprintf
                   "constructor %s belongs to type %s but the scrutinee \
                    has type %s" c adt name))
             | _ ->
                 raise (Error (Printf.sprintf
                   "constructor pattern %s requires a scrutinee of type %s"
                   c adt))
           in
           let fields =
             List.map (subst_typarams (List.combine owner_params args))
               raw_fields
           in
           if List.length ps <> List.length fields then
             raise (Error (Printf.sprintf
               "constructor %s expects %d argument(s) but the \
                pattern has %d" c (List.length fields)
               (List.length ps)));
           List.concat (List.map2 check_pattern fields ps))

(* D7: tuple elements live in objpool cell fields, so they follow the
   same representability rules as ctor fields, with tuple-specific
   messages. *)
let rec check_tuple_elem (ty : typ) : unit =
  match resolve ty with
  | TVar _ -> ()
      (* Phase E: unify's tvar_bindable restriction guarantees this can
         only resolve to a single-int type — every one a representable
         cell field. This is what keeps a tuple-polymorphic swap
         (E8) typeable without a representability hole. *)
  | TInt | TFloat | TBool -> ()
  | TList _ -> ()
  | TParam _ -> ()   (* G4: see check_field_type's TParam note *)
  | TTuple ts -> List.iter check_tuple_elem ts
  | TAdt (n, args) ->
      if not (Hashtbl.mem adt_decls n) && not (Hashtbl.mem record_decls n)
      then
        raise (Error (Printf.sprintf
          "tuple element of unknown type '%s'" n))
      else List.iter check_tuple_elem args
  | TArrDyn _ ->
      raise (Error
        "tuple element: darr is not supported in v1 (a dynamic array \
         is a base+len pair, not a single handle)")
  | TUnit | TSelector | TPos ->
      raise (Error
        "tuple element type is not representable as an objpool cell \
         field")
  | TArrStatic _ | TMat _ ->
      raise (Error
        "tuple element: static arrays/matrices are compile-time \
         storage, not first-class values")
  | TRef _ ->
      raise (Error "tuple element: ref fields would break purity — \
                    rejected")
  | TFun _ ->
      raise (Error "tuple element: closures cannot be stored in a \
                    tuple in v1 — pass as a function argument, \
                    let-bind it, or return it instead")

let wilds n = List.init n (fun _ -> PWild)

let rec split_at n l =
  if n = 0 then ([], l)
  else
    match l with
    | [] -> raise (Error "internal: split_at underflow in match analysis")
    | x :: rest -> let (a, b) = split_at (n - 1) rest in (x :: a, b)

(* Matrix specializations (Maranget 2007, "Warnings for pattern
   matching"). A matrix row is a pattern vector; specialization peels
   the first column. *)
let specialize_ctor (c : string) (ar : int) (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PCtor (c', ps) :: rest -> if c' = c then Some (ps @ rest) else None
    | (PWild | PVar _) :: rest -> Some (wilds ar @ rest)
    | (PInt _ | PNil | PCons _ | PTuple _ | PRecord _) :: _ -> None
    | [] -> None) matrix

let specialize_int (i : int) (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PInt j :: rest -> if i = j then Some rest else None
    | (PWild | PVar _) :: rest -> Some rest
    | (PCtor _ | PNil | PCons _ | PTuple _ | PRecord _) :: _ -> None
    | [] -> None) matrix

(* D7: tuple column. Tuples are a single always-present "ctor" of
   arity [ar], so specialization just unfolds the components. *)
let specialize_tuple (ar : int) (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PTuple ps :: rest -> Some (ps @ rest)
    | (PWild | PVar _) :: rest -> Some (wilds ar @ rest)
    | (PInt _ | PCtor _ | PNil | PCons _ | PRecord _) :: _ -> None
    | [] -> None) matrix

(* D8: expand a record pattern's field list to a full decl-order
   sub-pattern vector (missing fields = PWild). After this a record
   column is exactly a tuple column. *)
let record_row (decl : (string * typ) list)
    (fields : (string * pattern) list) : pattern list =
  List.map (fun (f, _) ->
    match List.assoc_opt f fields with
    | Some p -> p
    | None -> PWild) decl

let specialize_record (decl : (string * typ) list)
    (matrix : pattern list list) =
  let ar = List.length decl in
  List.filter_map (fun row ->
    match row with
    | PRecord fields :: rest -> Some (record_row decl fields @ rest)
    | (PWild | PVar _) :: rest -> Some (wilds ar @ rest)
    | (PInt _ | PCtor _ | PNil | PCons _ | PTuple _) :: _ -> None
    | [] -> None) matrix

(* D6: TList column specializations. The list signature is the fixed
   two-ctor set {[], ::} — [] has arity 0, :: arity 2 with column types
   [TInt; TList TInt] (v1 monomorphic, per check_pattern). *)
let specialize_nil (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PNil :: rest -> Some rest
    | (PWild | PVar _) :: rest -> Some rest
    | (PInt _ | PCtor _ | PCons _ | PTuple _ | PRecord _) :: _ -> None
    | [] -> None) matrix

let specialize_cons (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PCons (ph, pt) :: rest -> Some (ph :: pt :: rest)
    | (PWild | PVar _) :: rest -> Some (PWild :: PWild :: rest)
    | (PInt _ | PCtor _ | PNil | PTuple _ | PRecord _) :: _ -> None
    | [] -> None) matrix

let default_matrix (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | (PWild | PVar _) :: rest -> Some rest
    | _ -> None) matrix

(* Usefulness with witness: is there a value vector that [q] matches
   but no row of [matrix] does? Returns an example as a pattern vector
   (PWild = don't-care). Exhaustiveness = usefulness of the all-wild
   vector; redundancy of arm k = non-usefulness of its pattern w.r.t.
   arms 0..k-1. [tys] tracks per-column types for the complete-
   signature test. All ctor names in play were validated by
   check_pattern, so ctor_info lookups here cannot miss. *)
let rec useful (tys : typ list) (matrix : pattern list list)
    (q : pattern list) : pattern list option =
  match tys, q with
  | [], [] -> if matrix = [] then Some [] else None
  | ty :: trest, qh :: qrest ->
      (match qh with
       | PCtor (c, ps) ->
           let (owner, raw_fields, _) = Hashtbl.find ctor_info c in
           (* G4: substitute the column's ACTUAL instantiation args
              (from ty, already resolved to TAdt (owner, args) by
              check_pattern before matrices run) into raw_fields, so
              witnesses stay concrete (§13.11 decision 6). *)
           let fields =
             match resolve ty with
             | TAdt (name, args) when name = owner ->
                 let (params, _) = Hashtbl.find adt_decls owner in
                 List.map (subst_typarams (List.combine params args))
                   raw_fields
             | _ -> raw_fields
           in
           let ar = List.length fields in
           (match useful (fields @ trest)
                    (specialize_ctor c ar matrix) (ps @ qrest) with
            | Some w ->
                let (wf, wr) = split_at ar w in
                Some (PCtor (c, wf) :: wr)
            | None -> None)
       | PInt i ->
           (match useful trest (specialize_int i matrix) qrest with
            | Some w -> Some (PInt i :: w)
            | None -> None)
       | PTuple ps ->
           let ts =
             match resolve ty with
             | TTuple ts -> ts
             | _ ->
                 raise (Error
                   "internal: tuple pattern on a non-tuple column in \
                    match analysis")
           in
           let ar = List.length ps in
           (match useful (ts @ trest)
                    (specialize_tuple ar matrix) (ps @ qrest) with
            | Some w ->
                let (wf, wr) = split_at ar w in
                Some (PTuple wf :: wr)
            | None -> None)
       | PRecord qfields ->
           let decl =
             match resolve ty with
             | TAdt (n, _) when Hashtbl.mem record_decls n ->
                 Hashtbl.find record_decls n
             | _ ->
                 raise (Error
                   "internal: record pattern on a non-record column in \
                    match analysis")
           in
           let ar = List.length decl in
           (match useful (List.map snd decl @ trest)
                    (specialize_record decl matrix)
                    (record_row decl qfields @ qrest) with
            | Some w ->
                let (wf, wr) = split_at ar w in
                Some (PRecord
                        (List.map2 (fun (f, _) p -> (f, p)) decl wf)
                      :: wr)
            | None -> None)
       | PNil ->
           (match useful trest (specialize_nil matrix) qrest with
            | Some w -> Some (PNil :: w)
            | None -> None)
       | PCons (ph, pt) ->
           (* E4b: sub-columns carry the scrutinee's element type. A
              defensive TInt covers the can't-happen unresolved case
              (check_pattern pinned the column before matrices run). *)
           let elem =
             match resolve ty with TList e -> e | _ -> TInt
           in
           (match useful (elem :: TList elem :: trest)
                    (specialize_cons matrix) (ph :: pt :: qrest) with
            | Some w ->
                let (wf, wr) = split_at 2 w in
                (match wf with
                 | [wh; wt] -> Some (PCons (wh, wt) :: wr)
                 | _ -> assert false)
            | None -> None)
       | PWild | PVar _ ->
           let head_ctor_names =
             List.filter_map (fun row ->
               match row with
               | PCtor (c, _) :: _ -> Some c
               | _ -> None) matrix
           in
           (* Phase E: resolve before dispatching on the column type. A
              still-unbound tvar column can only carry wild/var patterns
              (anything stronger would have bound it in check_pattern),
              so it falls to the final catch-all arm — witnesses never
              contain tvars. *)
           (match resolve ty with
            | TAdt (name, _) when Hashtbl.mem record_decls name ->
                (* D8: record column — a single always-present "ctor",
                   same shape as the TTuple arm below. *)
                let decl = Hashtbl.find record_decls name in
                let ar = List.length decl in
                let has_rec =
                  List.exists (fun row ->
                    match row with PRecord _ :: _ -> true | _ -> false)
                    matrix
                in
                if has_rec then
                  (match useful (List.map snd decl @ trest)
                           (specialize_record decl matrix)
                           (wilds ar @ qrest) with
                   | Some w ->
                       let (wf, wr) = split_at ar w in
                       Some (PRecord
                               (List.map2 (fun (f, _) p -> (f, p))
                                  decl wf)
                             :: wr)
                   | None -> None)
                else
                  (match useful trest (default_matrix matrix) qrest with
                   | Some w -> Some (PWild :: w)
                   | None -> None)
            | TAdt (name, args) when Hashtbl.mem adt_decls name ->
                let (params, ctors) = Hashtbl.find adt_decls name in
                (* G4: substitute this column's actual instantiation
                   args into each ctor's raw field types before
                   specializing, mirroring E4b's TList-elem threading
                   (§13.11 decision 6). *)
                let mapping = List.combine params args in
                let try_ctor (cname, raw_fields) =
                  let fields =
                    List.map (subst_typarams mapping) raw_fields
                  in
                  let ar = List.length fields in
                  match useful (fields @ trest)
                          (specialize_ctor cname ar matrix)
                          (wilds ar @ qrest) with
                  | Some w ->
                      let (wf, wr) = split_at ar w in
                      Some (PCtor (cname, wf) :: wr)
                  | None -> None
                in
                let complete =
                  List.for_all
                    (fun (cn, _) -> List.mem cn head_ctor_names) ctors
                in
                if complete then
                  (* every ctor appears: q is useful iff it is useful
                     under at least one specialization *)
                  List.fold_left (fun acc c ->
                    match acc with Some _ -> acc | None -> try_ctor c)
                    None ctors
                else
                  (match useful trest (default_matrix matrix) qrest with
                   | Some w ->
                       (* name a missing ctor so the error is actionable *)
                       (match List.find_opt
                                (fun (cn, _) ->
                                  not (List.mem cn head_ctor_names))
                                ctors with
                        | Some (cn, fields) ->
                            Some (PCtor (cn, wilds (List.length fields)) :: w)
                        | None -> Some (PWild :: w))
                   | None -> None)
            | TList elem ->
                (* D6: the list signature is complete iff both a []
                   and a :: head appear in the column. E4b: cons
                   sub-columns carry the element type. *)
                let has_nil =
                  List.exists (fun row ->
                    match row with PNil :: _ -> true | _ -> false) matrix
                and has_cons =
                  List.exists (fun row ->
                    match row with PCons _ :: _ -> true | _ -> false)
                    matrix
                in
                if has_nil && has_cons then
                  (match useful trest (specialize_nil matrix) qrest with
                   | Some w -> Some (PNil :: w)
                   | None ->
                       (match useful (elem :: TList elem :: trest)
                                (specialize_cons matrix)
                                (PWild :: PWild :: qrest) with
                        | Some w ->
                            let (wf, wr) = split_at 2 w in
                            (match wf with
                             | [wh; wt] -> Some (PCons (wh, wt) :: wr)
                             | _ -> assert false)
                        | None -> None))
                else
                  (match useful trest (default_matrix matrix) qrest with
                   | Some w ->
                       (* name a missing list ctor for the witness *)
                       let head =
                         if not has_nil then PNil
                         else PCons (PWild, PWild)
                       in
                       Some (head :: w)
                   | None -> None)
            | TTuple ts ->
                (* D7: the tuple signature has exactly one "ctor" and it
                   is complete iff any PTuple heads the column. When
                   none does, every row is wild/var here and the default
                   matrix is equivalent (and cheaper). *)
                let ar = List.length ts in
                let has_tuple =
                  List.exists (fun row ->
                    match row with PTuple _ :: _ -> true | _ -> false)
                    matrix
                in
                if has_tuple then
                  (match useful (ts @ trest)
                           (specialize_tuple ar matrix)
                           (wilds ar @ qrest) with
                   | Some w ->
                       let (wf, wr) = split_at ar w in
                       Some (PTuple wf :: wr)
                   | None -> None)
                else
                  (match useful trest (default_matrix matrix) qrest with
                   | Some w -> Some (PWild :: w)
                   | None -> None)
            | TInt ->
                (* the int signature is never complete *)
                (match useful trest (default_matrix matrix) qrest with
                 | Some w ->
                     let ints =
                       List.filter_map (fun row ->
                         match row with
                         | PInt i :: _ -> Some i
                         | _ -> None) matrix
                     in
                     let head =
                       if ints = [] then PWild
                       else PInt (1 + List.fold_left max (List.hd ints) ints)
                     in
                     Some (head :: w)
                 | None -> None)
            | _ ->
                (* column type admits only wild/var patterns *)
                (match useful trest (default_matrix matrix) qrest with
                 | Some w -> Some (PWild :: w)
                 | None -> None)))
  | _ -> raise (Error "internal: column/pattern arity mismatch in match analysis")

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

(* Phase E: [infer] is unification-based. The env maps name -> scheme
   (§13.10 decision 2); a public wrapper below restores the historical
   (string * typ) list signature for main.ml / for_lift call sites.
   Every pre-Phase-E type check routes through [unify_msg] with its
   original error string. *)
let rec infer env e =
  match e with
  | Int _ -> TInt
  | Float _ -> TFloat
    (* Phase N / N1: Float literals now have a real type. The Q16.16
       encoding (x *. 65536 → int) lands in N4; arithmetic arms land
       in N5. Under §12.1 both TInt and TFloat are 32-bit signed
       scoreboard ints at runtime, so codegen is type-erased. *)
  | Bool _ -> TBool
  | Str _ -> TUnit (* Strings are special, treated as Unit for logic *)
  | Var x ->
      (match List.assoc_opt x env with
       | Some s -> instantiate s
       | None ->
         (* Phase G: fall back to global val env before erroring. *)
         (match Hashtbl.find_opt global_vals x with
          | Some ty -> ty
          | None ->
              (* Phase D: a bare Capitalized name is a nullary ctor
                 (the parser emits Var for it — no dedicated node). *)
              (match Hashtbl.find_opt ctor_info x with
               | Some (adt, [], _) ->
                   (* G4: even a nullary ctor's owner may be
                      parameterized (`None : 'a option`) — mint fresh
                      args per mention (§13.11 decision 6). *)
                   let (params, _) = Hashtbl.find adt_decls adt in
                   TAdt (adt, List.map (fun _ -> fresh_tvar ()) params)
               | Some (_, fields, _) ->
                   raise (Error (Printf.sprintf
                     "constructor %s expects %d argument(s): write %s(...)"
                     x (List.length fields) x))
               | None -> raise (Error ("Undefined variable: " ^ x)))))
  | Selector _ -> TSelector
  | Coord _ -> TPos
  | Command _ -> TUnit
  
  | BinOp (op, e1, e2) ->
      let t1 = infer env e1 in
      let t2 = infer env e2 in
      (match op with
       | Add | Sub | Mult | Div | Mod ->
           unify_msg t1 t2 "Type mismatch in binary operation";
           (match resolve t1 with
            | TInt -> TInt
            (* Phase N / N5: Add and Sub on Q16.16 are scalar-identical
               to int add/sub because (x*65536 + y*65536) = (x+y)*65536.
               Mult/Div on TFloat are rejected — users must call
               fmul/fdiv which lower to FMult/FDiv (different codegen).
               Mod on TFloat falls through to the generic rejection,
               exactly as before Phase E. *)
            | TFloat ->
                (match op with
                 | Add | Sub -> TFloat
                 | Mult | Div ->
                     raise (Error "use fmul/fdiv for Q16.16 multiply/divide; \
                                   `*` and `/` on float would emit int semantics \
                                   and silently lose the fractional part")
                 | _ -> raise (Error "Type mismatch in binary operation"))
            | TVar _ ->
                (* §13.10 decision 5: two unconstrained operands default
                   to int eagerly (OCaml-compatible `+`). *)
                unify_msg t1 TInt "Type mismatch in binary operation";
                TInt
            | _ -> raise (Error "Type mismatch in binary operation"))
       | Eq | Neq | Lt | Gt | Leq | Geq ->
           unify_msg t1 t2 "Type mismatch in binary operation";
           (match resolve t1 with
            | TInt | TFloat -> TBool
            | TVar _ ->
                unify_msg t1 TInt "Type mismatch in binary operation";
                TBool
            | _ -> raise (Error "Type mismatch in binary operation"))
       | And | Or ->
           unify_msg t1 TBool "Type mismatch in binary operation";
           unify_msg t2 TBool "Type mismatch in binary operation";
           TBool
       | FMult | FDiv ->
           (* Internal ops minted by knormal from fmul/fdiv Apps — the
              surface parser never produces them, so reaching this arm
              was and stays the generic rejection (pre-E catch-all). *)
           raise (Error "Type mismatch in binary operation"))

  | Let (x, e1, e2) ->
      let t1 = infer env e1 in
      (* E3: syntactic values generalize (§13.10 decision 3); expansive
         RHSes — `ref e` above all — stay monomorphic. *)
      let s1 = if is_value e1 then generalize env x t1 else mono t1 in
      infer ((x, s1) :: env) e2

  | If (cond, e1, e2) ->
      unify_msg (infer env cond) TBool "If condition must be Bool";
      let t1 = infer env e1 in
      let t2 = infer env e2 in
      unify_msg t1 t2 "If branches must have same type";
      t1

  | Seq (e1, e2) ->
      let _ = infer env e1 in
      infer env e2

  (* Phase B builtins, E4b-generic: is_nil : 'a list -> bool,
     head : 'a list -> 'a, tail : 'a list -> 'a list. The pre-E4b
     accept-anything laxity is gone — unification makes the let-binding
     pattern `let l = 1 :: [] in head(l)` type directly, which was the
     only reason for it. *)
  | App ("is_nil", [arg]) ->
      unify_msg (infer env arg) (TList (fresh_tvar ()))
        "is_nil: arg must be a list";
      TBool

  (* Phase N / N5: Q16.16 fixed-point multiply/divide/negate builtins.
     We use explicit App-builtins instead of overloading `*`/`/` because
     dispatching on operand type would require knormal to track a
     per-variable type environment, which it currently doesn't. The
     deliberate asymmetry — `+`/`-` work on TFloat, but `*`/`/` route
     through fmul/fdiv — matches the asymmetry in how they lower: Add
     and Sub are one scoreboard op each; FMult and FDiv are multi-
     command inlined sequences (see N6/N7). *)
  | App ("fmul", [a; b]) ->
      unify_msg (infer env a) TFloat "fmul: first arg must be float";
      unify_msg (infer env b) TFloat "fmul: second arg must be float";
      TFloat
  | App ("fdiv", [a; b]) ->
      unify_msg (infer env a) TFloat "fdiv: first arg must be float";
      unify_msg (infer env b) TFloat "fdiv: second arg must be float";
      TFloat
  | App ("neg_f", [a]) ->
      unify_msg (infer env a) TFloat "neg_f: arg must be float";
      TFloat
  | App ("to_float", [a]) ->
      unify_msg (infer env a) TInt "to_float: arg must be int";
      TFloat
  | App ("to_int", [a]) ->
      unify_msg (infer env a) TFloat "to_int: arg must be float";
      TInt
  (* Phase N §12.1: TFloat and TInt share the same 32-bit runtime
     representation, so bit-level reinterpretation is free. These
     builtins are pure typing coercions with zero codegen cost — used
     by lib/math.mcaml to compute fractional-raw = x_bits mod 65536
     etc. on a Q16.16 value. *)
  | App ("raw_of_float", [a]) ->
      unify_msg (infer env a) TFloat "raw_of_float: arg must be float";
      TInt
  | App ("float_of_raw", [a]) ->
      unify_msg (infer env a) TInt "float_of_raw: arg must be int";
      TFloat

  (* Phase A dyn-array builtins. [array_make] materializes a fresh
     TArrDyn TInt; [array_get]/[array_set] unify against an
     already-known TArrDyn arg. The element type is carried on the
     TArrDyn constructor so future non-int widths come for free. *)
  | App ("array_make", [n; v]) ->
      unify_msg (infer env n) TInt "array_make: length must be int";
      let tv = infer env v in
      unify_msg tv TInt "array_make: init value must be int";
      TArrDyn tv
  | App ("array_get", [a; i]) ->
      (* Note: no TVar arm here — unify's tvar_bindable restriction
         means an unannotated param can never become a darr, so the
         first arg must already be annotation-concrete (the `darr`
         keyword), exactly as before Phase E. *)
      let elt =
        match resolve (infer env a) with
        | TArrDyn t -> t
        | _ -> raise (Error "array_get: first arg must be a dynamic array")
      in
      unify_msg (infer env i) TInt "array_get: index must be int";
      elt
  | App ("array_set", [a; i; v]) ->
      let elt =
        match resolve (infer env a) with
        | TArrDyn t -> t
        | _ -> raise (Error "array_set: first arg must be a dynamic array")
      in
      unify_msg (infer env i) TInt "array_set: index must be int";
      unify_msg (infer env v) elt
        "array_set: value type does not match element type";
      TUnit
  | App ("head", [arg]) ->
      let elem = fresh_tvar () in
      unify_msg (infer env arg) (TList elem) "head: arg must be a list";
      elem
  | App ("tail", [arg]) ->
      let elem = fresh_tvar () in
      unify_msg (infer env arg) (TList elem) "tail: arg must be a list";
      TList elem

  (* Phase F: value application — calling a local var/param bound to a
     TFun value (a HOF's own function-typed parameter, or a let-bound
     lambda alias, reached through zero or more aliases per §13.12
     decision 2). Must be checked before the ctor_info/global-function
     cascade below: ctor names are always Capitalized (so a lowercase
     local binder can never collide with one) and a local binding
     shadows any same-named global by construction — alpha.ml renames
     the App callee to the local's alpha-renamed name whenever it
     resolves as a local binder, so this lookup only ever fires for a
     genuine local. instantiate is pure (mints fresh tvars, no
     destructive mutation), so calling it twice here is safe, just
     slightly wasteful. *)
  | App (f, args) when
      (match List.assoc_opt f env with
       | Some s -> (match resolve (instantiate s) with
                    | TFun _ -> true | _ -> false)
       | None -> false) ->
      (match resolve (instantiate (List.assoc f env)) with
       | TFun (param_types, ret_type) ->
           if List.length args <> List.length param_types then
             raise (Error (Printf.sprintf
               "App %s: expected %d argument(s), got %d" f
               (List.length param_types) (List.length args)));
           List.iter2 (fun a pt ->
             unify_msg (infer env a) pt (Printf.sprintf
               "App %s: argument type mismatch" f)) args param_types;
           ret_type
       | _ -> assert false)

  (* Phase D: constructor application. Ctors are Capitalized and
     top-level fun names are validated lowercase (alpha.ml), so this
     guard can't shadow a real function. *)
  | App (f, args) when Hashtbl.mem ctor_info f ->
      let (adt, raw_fields, _) = Hashtbl.find ctor_info f in
      (* G4: instantiate — fresh tvars per the owner's declared params,
         substituted into the raw (TParam-bearing) field types before
         unifying each argument (§13.11 decision 6; mirrors E4b's
         Nil/Cons fresh-tvar-then-unify shape). *)
      let (params, _) = Hashtbl.find adt_decls adt in
      let fresh = List.map (fun _ -> fresh_tvar ()) params in
      let fields =
        List.map (subst_typarams (List.combine params fresh)) raw_fields
      in
      if List.length args <> List.length fields then
        raise (Error (Printf.sprintf
          "constructor %s expects %d argument(s), got %d"
          f (List.length fields) (List.length args)));
      List.iter2 (fun a ft ->
        unify_msg (infer env a) ft (Printf.sprintf
          "constructor %s: argument type mismatch" f)) args fields;
      TAdt (adt, fresh)

  | App (f, args) ->
      (* E3: generalized signature first (fresh instantiation per call
         site); raw monotype second (self-recursion + forward calls,
         §13.10 decision 7); TInt fallback last (synthesized helpers,
         unchanged since Phase 1). *)
      let sig_opt =
        match Hashtbl.find_opt fun_schemes f with
        | Some fs -> Some (instantiate_fun fs)
        | None -> Hashtbl.find_opt fun_sigs f
      in
      (match sig_opt with
       | Some (param_types, ret_type) ->
           let arg_types = List.map (infer env) args in
           if List.length arg_types <> List.length param_types then
             raise (Error (Printf.sprintf
               "App %s: expected %d args, got %d" f
               (List.length param_types) (List.length arg_types)));
           List.iter2 (fun at pt ->
             try unify at pt
             with Unify_fail (a, b) ->
               (* Legacy prefix preserved; the unify pair is appended
                  for E8 diagnostic quality. *)
               raise (Error (Printf.sprintf
                 "App %s: arg type mismatch (cannot unify %s with %s)"
                 f (string_of_typ a) (string_of_typ b)))
           ) arg_types param_types;
           ret_type
       | None ->
           (* Unknown signature (e.g. synthesized helper): fall back. *)
           List.iter (fun a -> let _ = infer env a in ()) args;
           TInt)

  | Array elems ->
      (match elems with
       | [] -> TArrStatic (TInt, 0)
       | _ ->
           (* Static array literals stay equality-checked on resolved
              types: their element types are always literal-concrete
              (ints, floats, nested rows), never tvars. *)
           let ts = List.map (fun e -> resolve (infer env e)) elems in
           if List.for_all (fun t -> t = TInt) ts then
             TArrStatic (TInt, List.length elems)
           (* Phase Math: accept uniform float element arrays. Runtime
              representation is still int (Q16.16) per §12.1, but the
              declared element type matters for downstream fmul/fdiv
              unification. *)
           else if List.for_all (fun t -> t = TFloat) ts then
             TArrStatic (TFloat, List.length elems)
           else
             let get_inner_len t =
               match t with
               | TArrStatic (TInt, k) -> k
               | _ -> raise (Error "Array elements must all be int or all be arrays of int with matching length")
             in
             let k = get_inner_len (List.hd ts) in
             if List.for_all (fun t -> t = TArrStatic (TInt, k)) ts then
               TMat (TInt, List.length elems, k)
             else
               raise (Error "Array elements must all be int or all be arrays of int with matching length"))

  | Index1 (e, i) ->
      (* No TVar arm: a static array type can't be inferred (its length
         is compile-time data), so the base must be annotation-concrete
         — same posture as array_get above. *)
      let t =
        match resolve (infer env e) with
        | TArrStatic (t, _) -> t
        | _ -> raise (Error "a[i] requires an array")
      in
      unify_msg (infer env i) TInt "array index must be int";
      t

  | Index2 (e, i, j) ->
      let t =
        match resolve (infer env e) with
        | TMat (t, _, _) -> t
        | _ -> raise (Error "m[i, j] requires a matrix")
      in
      unify_msg (infer env i) TInt "array index must be int";
      unify_msg (infer env j) TInt "array index must be int";
      t

  | IndexSet1 (base, idx, v) ->
      let t =
        match resolve (infer env base) with
        | TArrStatic (t, _) -> t
        | _ -> raise (Error "a[i] := v requires an array")
      in
      unify_msg (infer env idx) TInt "array index must be int";
      unify_msg (infer env v) t
        "a[i] := v: value type does not match element type";
      TUnit

  | IndexSet2 (base, i, j, v) ->
      let t =
        match resolve (infer env base) with
        | TMat (t, _, _) -> t
        | _ -> raise (Error "m[i, j] := v requires a matrix")
      in
      unify_msg (infer env i) TInt "array index must be int";
      unify_msg (infer env j) TInt "array index must be int";
      unify_msg (infer env v) t
        "m[i, j] := v: value type does not match element type";
      TUnit

  | Unit -> TUnit

  | Ref e ->
      let t = infer env e in
      TRef t

  | Deref e ->
      (* No TVar arm: tvar_bindable rejects TRef, so a ref must be
         annotation- or literal-concrete — refs stay second-class. *)
      (match resolve (infer env e) with
       | TRef t -> t
       | _ -> raise (Error "! requires a ref"))

  | RefSet (r, v) ->
      let tr = infer env r in
      let tv = infer env v in
      (match resolve tr with
       | TRef t ->
           unify_msg t tv "ref := value type mismatch";
           TUnit
       | _ -> raise (Error ":= requires a ref on the left"))

  | Tuple es ->
      (* D7: structural tuple. Every element must be representable as
         an objpool cell field (one scoreboard int each). *)
      let ts = List.map (infer env) es in
      List.iter check_tuple_elem ts;
      TTuple ts

  | Record fields ->
      (* D8: the owner type resolves from the first field name (one
         global field namespace). The literal must provide the EXACT
         field set — no unknowns, no duplicates, no omissions — in any
         order. *)
      (match fields with
       | [] -> raise (Error "empty record literal")
       | (f0, _) :: _ ->
           let owner =
             match Hashtbl.find_opt record_fields f0 with
             | Some (owner, _, _) -> owner
             | None ->
                 raise (Error (Printf.sprintf
                   "unknown record field %s" f0))
           in
           let decl = Hashtbl.find record_decls owner in
           List.iter (fun (f, e) ->
             (match List.assoc_opt f decl with
              | None ->
                  raise (Error (Printf.sprintf
                    "record type %s has no field %s" owner f))
              | Some ft ->
                  unify_msg (infer env e) ft (Printf.sprintf
                    "record type %s: field %s type mismatch" owner f));
             if List.length (List.filter (fun (f', _) -> f' = f) fields)
                > 1 then
               raise (Error (Printf.sprintf
                 "record literal mentions field %s twice" f))) fields;
           List.iter (fun (f, _) ->
             if not (List.mem_assoc f fields) then
               raise (Error (Printf.sprintf
                 "record literal of type %s is missing field %s"
                 owner f))) decl;
           TAdt (owner, []))  (* G4/decision 5: records stay monomorphic *)

  | Field (e, f) ->
      (* D8: r.x — the 3-cmd single-field read. *)
      (match Hashtbl.find_opt record_fields f with
       | None ->
           raise (Error (Printf.sprintf "unknown record field %s" f))
       | Some (owner, _, ft) ->
           (match resolve (infer env e) with
            | TAdt (n, _) when n = owner -> ft
            | TAdt (n, _) when Hashtbl.mem record_decls n ->
                raise (Error (Printf.sprintf
                  "field %s belongs to record type %s but the value \
                   has type %s" f owner n))
            | TVar _ as tv ->
                (* Phase E: the field names its owner — pin the value. *)
                unify_msg tv (TAdt (owner, [])) (Printf.sprintf
                  ".%s requires a value of record type %s" f owner);
                ft
            | _ ->
                raise (Error (Printf.sprintf
                  ".%s requires a value of record type %s" f owner))))

  (* Phase F: lambda expression. A raw Lambda should never reach the
     REAL Phase 1 typing pass — for_lift.ml fully converts every Lambda
     into a Closure before typing ever runs (§13.12 F1 sub-decision 3)
     — so this arm exists to serve for_lift's OWN degraded-mode oracle
     call (Typing.infer on a Let RHS, used only to thread free-variable
     types for an enclosing for-loop/lambda's capture list), which
     queries the ORIGINAL pre-conversion expression. Structural and
     sound either way: params are monomorphic var binders (never
     generalized — §13.12 F1 sub-decision 1), so this is exactly the
     rule a real Lambda arm would need. *)
  | Lambda (params, body) ->
      let env' =
        List.fold_left (fun acc (p, t) -> (p, mono t) :: acc) env params in
      TFun (List.map snd params, infer env' body)

  (* Phase F: closure-conversion IR. for_lift.ml lifted this lambda's
     body into the top-level helper [fname] (already registered in
     fun_sigs by build_sigs, which runs before any def's body is
     inferred — for_lift appends synthesized helpers to the program
     BEFORE build_sigs runs) taking every capture as a leading param.
     [caps] carries exactly those captured-value expressions, so the
     split point between "captures" and "the lambda's own params" is
     simply their count. *)
  | Closure (fname, caps) ->
      let (param_types, ret_type) =
        match Hashtbl.find_opt fun_sigs fname with
        | Some sig_ -> sig_
        | None ->
            raise (Error (Printf.sprintf
              "internal: closure-lifted helper %s has no signature — \
               this is a compiler bug" fname))
      in
      let n_caps = List.length caps in
      let (cap_types, own_types) =
        try split_at n_caps param_types
        with Error _ ->
          raise (Error (Printf.sprintf
            "internal: closure-lifted helper %s has fewer params (%d) \
             than captured values (%d) — this is a compiler bug"
            fname (List.length param_types) n_caps))
      in
      List.iter2 (fun c ct ->
        unify_msg (infer env c) ct
          "internal: closure capture type mismatch — this is a compiler bug")
        caps cap_types;
      TFun (own_types, ret_type)

  | Nil ->
      (* E4b: 'a list — every [] mention gets a fresh element tvar,
         pinned by unification (or defaulted to TInt at the knormal
         boundary if nothing constrains it — which preserves the old
         `[]` behavior exactly). Runtime unchanged: nil is the -1
         sentinel regardless of element type. *)
      TList (fresh_tvar ())

  | Cons (h, t) ->
      let th = infer env h in
      let tt = infer env t in
      let elem = fresh_tvar () in
      unify_msg tt (TList elem) ":: tail must be a list";
      (try unify th elem
       with Unify_fail _ ->
         raise (Error (Printf.sprintf
           ":: head type %s does not match the list element type %s"
           (string_of_typ th) (string_of_typ elem))));
      TList elem

  | Region (tr, e) ->
      (* Infer the body's type and write it into the shared ref so
         knormal can read it at normalize time. §C2: v1 accepts every
         representable return type and relies on C5's per-type deep-
         copy walker to make it correct — no escape check here.
         Phase E: knormal dispatches on this ref's CONTENTS, so it gets
         the fully-zonked form (residual tvars default to TInt per
         §13.10 decision 5 — `region (fun () -> [])` walks as an int
         list, which is exactly the C5 walker's domain). *)
      let ty = infer env e in
      tr := zonk_default ty;
      ty

  | Match (scrut, arms) ->
      let tscrut = infer env scrut in
      (match resolve tscrut with
       | TAdt (name, _)
         when not (Hashtbl.mem adt_decls name)
              && not (Hashtbl.mem record_decls name) ->
           raise (Error (Printf.sprintf
             "match on a value of undeclared type %s" name))
       | _ -> ());
      (* 1. Pattern well-formedness + arm body types (binders shadow
         the outer env — assoc-list prepend). Pattern binders are
         monomorphic (they are lambda-bound, not let-bound). *)
      let arm_tys =
        List.map (fun (p, body) ->
          let binds = check_pattern tscrut p in
          infer (List.map (fun (n, t) -> (n, mono t)) binds @ env) body)
          arms
      in
      let t0 = List.hd arm_tys in
      List.iteri (fun i t ->
        unify_msg t0 t (Printf.sprintf
          "match arms must all have the same type (arm %d disagrees \
           with arm 1)" (i + 1))) arm_tys;
      (* 2. Redundancy: arm k must match some value arms 0..k-1 miss. *)
      let rows = List.map (fun (p, _) -> [p]) arms in
      let _ =
        List.fold_left (fun (i, prev) row ->
          (match row with
           | [p] ->
               (match useful [tscrut] (List.rev prev) row with
                | Some _ -> ()
                | None ->
                    raise (Error (Printf.sprintf
                      "match arm %d (%s) is unreachable — the arms \
                       before it already match everything it matches"
                      (i + 1) (string_of_pattern p))))
           | _ -> ());
          (i + 1, row :: prev)) (0, []) rows
      in
      (* 3. Exhaustiveness: a wildcard useful against all arms means
         some value falls through — report a concrete witness. *)
      (match useful [tscrut] rows [PWild] with
       | Some (w :: _) ->
           raise (Error (Printf.sprintf
             "match is not exhaustive — example of an unmatched value: %s"
             (string_of_pattern w)))
       | Some [] ->
           raise (Error "match is not exhaustive")
       | None -> ());
      t0

  | For (i, lo, hi, body) ->
      unify_msg (infer env lo) TInt "for: lo must be int";
      unify_msg (infer env hi) TInt "for: hi must be int";
      let env' = (i, mono TInt) :: env in
      let _ = infer env' body in
      (* body may type as anything; for-loops are statements, result is unit *)
      TUnit

(* Public wrapper: the historical signature. main.ml and for_lift pass
   (string * typ) list envs; schemes are internal to this module
   (§13.10 decision 2). The shadowing is deliberate — every recursive
   call above binds to the scheme-env version. *)
let infer (env : (string * typ) list) (e : expr) : typ =
  infer (List.map (fun (n, t) -> (n, mono t)) env) e

(* E4: per-def driver entry point (main.ml pass 1). Types the body
   under the param env, checks the declared return type — an
   annotation is a unification constraint, so an omitted return (a
   parser-minted TVar) just binds, while a wrong annotation is now a
   type error (§13.10 decision 6, a documented strengthening over the
   pre-E decorative return type) — then generalizes the signature into
   fun_schemes for later call sites. *)
let type_fun_def (name : string) (params : (string * typ) list)
    (ret : typ) (body : expr) : unit =
  let tbody = infer params body in
  (try unify ret tbody
   with Unify_fail _ ->
     raise (Error (Printf.sprintf
       "fun %s: declared return type %s does not match body type %s"
       name (string_of_typ ret) (string_of_typ tbody))));
  generalize_fun name (List.map snd params) ret