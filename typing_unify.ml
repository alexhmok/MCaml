(* typing_unify.ml — Phase E Hindley-Milner unification engine
   (§13.10): resolve/unify/zonk, schemes + generalization, and the G4
   decl-side type-parameter substitution. Split from typing.ml in
   refactor step 7; re-exported through the Typing facade. *)
open Ast
open Typing_core

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
