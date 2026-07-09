(* typing_patterns.ml — Phase D pattern typing + Maranget usefulness
   (exhaustiveness/redundancy analysis). Split from typing.ml in
   refactor step 7; re-exported through the Typing facade. *)
open Ast
open Typing_core
open Typing_unify

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
