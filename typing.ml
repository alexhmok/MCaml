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

(* type name -> constructor list, in declaration order *)
let adt_decls : (string, constructor list) Hashtbl.t = Hashtbl.create 8

(* ctor name -> (owning type, field types, tag).
   Tags are declaration-order indices 0..n-1; D5's decision trees
   dispatch on them with `execute if score ... matches <tag>` and D4's
   cell layout stores them in the `tag` field. Constructors share ONE
   global namespace (like OCaml within a module) so an unqualified
   ctor in a pattern resolves without a type ascription. *)
let ctor_info : (string, string * typ list * int) Hashtbl.t = Hashtbl.create 16

let is_constructor (name : string) : bool = Hashtbl.mem ctor_info name

(* ADT ctor fields must be single-scoreboard-int values (§12.1 uniform
   representation): scalars and handles. TArrDyn is a (base, len) vreg
   PAIR per §3.4 so it doesn't fit one cell field — rejected in v1. *)
let rec check_field_type (decl : string) (cname : string) (ft : typ) : unit =
  match ft with
  | TInt | TFloat | TBool -> ()
  | TList _ -> ()   (* single int handle *)
  | TTuple ts ->
      (* D7: a tuple is one objpool handle, so it fits a cell field.
         Its own elements must obey the same rules. *)
      List.iter (check_field_type decl cname) ts
  | TAdt n ->
      if not (Hashtbl.mem adt_decls n) then
        raise (Error (Printf.sprintf
          "type %s, constructor %s: unknown type '%s' in field — declare \
           it before this type (v1 has no forward references between \
           type declarations)" decl cname n))
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

let register_type_decl (name : string) (ctors : constructor list) : unit =
  if Hashtbl.mem adt_decls name then
    raise (Error ("duplicate type declaration: " ^ name));
  if String.length name = 0
     || not ((name.[0] >= 'a' && name.[0] <= 'z') || name.[0] = '_') then
    raise (Error (Printf.sprintf
      "type name '%s' must start with a lowercase letter" name));
  (* Register the name before validating fields so self-recursive
     fields (`type t = Leaf | Node of t * t`) resolve. On any
     validation error compilation aborts, so partial state is moot. *)
  Hashtbl.replace adt_decls name ctors;
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
    Hashtbl.replace ctor_info cname (name, fields, tag)
  ) ctors

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

(* Validate a pattern against the scrutinee type; return its binders.
   Duplicate binders inside one pattern are caught in alpha.ml
   (rename_pattern), because alpha's renaming makes them invisible
   here. *)
let rec check_pattern (t : typ) (p : pattern) : (string * typ) list =
  match p with
  | PWild -> []
  | PVar x -> [(x, t)]
  | PInt _ ->
      if t <> TInt then
        raise (Error (Printf.sprintf
          "int literal pattern %s requires an int scrutinee"
          (string_of_pattern p)));
      []
  | PNil ->
      (match t with
       | TList TInt -> []
       | _ -> raise (Error "pattern [] requires a list scrutinee"))
  | PCons (ph, pt) ->
      (* D6: v1 monomorphic int lists (B2) — head is int, tail is list.
         A ctor sub-pattern in head position is therefore untypeable
         until Phase E, matching the fact that `::` can't build one. *)
      (match t with
       | TList TInt ->
           check_pattern TInt ph @ check_pattern (TList TInt) pt
       | _ -> raise (Error "pattern _ :: _ requires a list scrutinee"))
  | PTuple ps ->
      (match t with
       | TTuple ts ->
           if List.length ts <> List.length ps then
             raise (Error (Printf.sprintf
               "tuple pattern has %d component(s) but the scrutinee is \
                a %d-tuple" (List.length ps) (List.length ts)));
           List.concat (List.map2 check_pattern ts ps)
       | _ ->
           raise (Error "tuple pattern requires a tuple scrutinee"))
  | PCtor (c, ps) ->
      (match Hashtbl.find_opt ctor_info c with
       | None ->
           raise (Error ("Unknown constructor in pattern: " ^ c))
       | Some (adt, fields, _) ->
           (match t with
            | TAdt name when name = adt ->
                if List.length ps <> List.length fields then
                  raise (Error (Printf.sprintf
                    "constructor %s expects %d argument(s) but the \
                     pattern has %d" c (List.length fields)
                    (List.length ps)));
                List.concat (List.map2 check_pattern fields ps)
            | TAdt name ->
                raise (Error (Printf.sprintf
                  "constructor %s belongs to type %s but the scrutinee \
                   has type %s" c adt name))
            | _ ->
                raise (Error (Printf.sprintf
                  "constructor pattern %s requires a scrutinee of type %s"
                  c adt))))

(* D7: tuple elements live in objpool cell fields, so they follow the
   same representability rules as ctor fields, with tuple-specific
   messages. *)
let rec check_tuple_elem (ty : typ) : unit =
  match ty with
  | TInt | TFloat | TBool -> ()
  | TList _ -> ()
  | TTuple ts -> List.iter check_tuple_elem ts
  | TAdt n ->
      if not (Hashtbl.mem adt_decls n) then
        raise (Error (Printf.sprintf
          "tuple element of unknown type '%s'" n))
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
    | (PInt _ | PNil | PCons _ | PTuple _) :: _ -> None
    | [] -> None) matrix

let specialize_int (i : int) (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PInt j :: rest -> if i = j then Some rest else None
    | (PWild | PVar _) :: rest -> Some rest
    | (PCtor _ | PNil | PCons _ | PTuple _) :: _ -> None
    | [] -> None) matrix

(* D7: tuple column. Tuples are a single always-present "ctor" of
   arity [ar], so specialization just unfolds the components. *)
let specialize_tuple (ar : int) (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PTuple ps :: rest -> Some (ps @ rest)
    | (PWild | PVar _) :: rest -> Some (wilds ar @ rest)
    | (PInt _ | PCtor _ | PNil | PCons _) :: _ -> None
    | [] -> None) matrix

(* D6: TList column specializations. The list signature is the fixed
   two-ctor set {[], ::} — [] has arity 0, :: arity 2 with column types
   [TInt; TList TInt] (v1 monomorphic, per check_pattern). *)
let specialize_nil (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PNil :: rest -> Some rest
    | (PWild | PVar _) :: rest -> Some rest
    | (PInt _ | PCtor _ | PCons _ | PTuple _) :: _ -> None
    | [] -> None) matrix

let specialize_cons (matrix : pattern list list) =
  List.filter_map (fun row ->
    match row with
    | PCons (ph, pt) :: rest -> Some (ph :: pt :: rest)
    | (PWild | PVar _) :: rest -> Some (PWild :: PWild :: rest)
    | (PInt _ | PCtor _ | PNil | PTuple _) :: _ -> None
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
           let (_, fields, _) = Hashtbl.find ctor_info c in
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
             match ty with
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
       | PNil ->
           (match useful trest (specialize_nil matrix) qrest with
            | Some w -> Some (PNil :: w)
            | None -> None)
       | PCons (ph, pt) ->
           (match useful (TInt :: TList TInt :: trest)
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
           let try_ctor (cname, fields) =
             let ar = List.length fields in
             match useful (fields @ trest)
                     (specialize_ctor cname ar matrix)
                     (wilds ar @ qrest) with
             | Some w ->
                 let (wf, wr) = split_at ar w in
                 Some (PCtor (cname, wf) :: wr)
             | None -> None
           in
           (match ty with
            | TAdt name when Hashtbl.mem adt_decls name ->
                let ctors = Hashtbl.find adt_decls name in
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
            | TList _ ->
                (* D6: the list signature is complete iff both a []
                   and a :: head appear in the column. *)
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
                       (match useful (TInt :: TList TInt :: trest)
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
  List.iter (fun d ->
    match d with
    | Fun (name, params, ret, _) ->
        Hashtbl.replace fun_sigs name (List.map snd params, ret)
    | Val _ | TypeDecl _ -> ()
  ) prog

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
      (try List.assoc x env
       with Not_found ->
         (* Phase G: fall back to global val env before erroring. *)
         (match Hashtbl.find_opt global_vals x with
          | Some ty -> ty
          | None ->
              (* Phase D: a bare Capitalized name is a nullary ctor
                 (the parser emits Var for it — no dedicated node). *)
              (match Hashtbl.find_opt ctor_info x with
               | Some (adt, [], _) -> TAdt adt
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
      (match op, t1, t2 with
       | (Add|Sub|Mult|Div|Mod), TInt, TInt -> TInt
       (* Phase N / N5: Add and Sub on Q16.16 are scalar-identical to
          int add/sub because (x*65536 + y*65536) = (x+y)*65536.
          Mult/Div on TFloat are rejected — users must call fmul/fdiv
          which lower to FMult/FDiv (different codegen). *)
       | (Add|Sub), TFloat, TFloat -> TFloat
       | (Mult|Div), TFloat, TFloat ->
           raise (Error "use fmul/fdiv for Q16.16 multiply/divide; \
                         `*` and `/` on float would emit int semantics \
                         and silently lose the fractional part")
       | (Eq|Neq|Lt|Gt|Leq|Geq), TInt, TInt -> TBool
       | (Eq|Neq|Lt|Gt|Leq|Geq), TFloat, TFloat -> TBool
       | (And|Or), TBool, TBool -> TBool
       | _ -> raise (Error "Type mismatch in binary operation"))

  | Let (x, e1, e2) ->
      let t1 = infer env e1 in
      infer ((x, t1) :: env) e2

  | If (cond, e1, e2) ->
      if infer env cond <> TBool then raise (Error "If condition must be Bool");
      let t1 = infer env e1 in
      let t2 = infer env e2 in
      if t1 <> t2 then raise (Error "If branches must have same type");
      t1

  | Seq (e1, e2) ->
      let _ = infer env e1 in
      infer env e2

  (* Phase B builtins: is_nil returns TBool so it can be used directly
     as an `if` condition; head returns TInt (the element); tail returns
     TList TInt (the rest of the list). All three accept any arg type
     since v1 is monomorphic int lists and the runtime only sees int
     handles — validating the arg type would just block the let-binding
     pattern `let l = 1 :: [] in head(l)` where l infers as TList TInt. *)
  | App ("is_nil", [arg]) ->
      let _ = infer env arg in
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
      if infer env a <> TFloat then raise (Error "fmul: first arg must be float");
      if infer env b <> TFloat then raise (Error "fmul: second arg must be float");
      TFloat
  | App ("fdiv", [a; b]) ->
      if infer env a <> TFloat then raise (Error "fdiv: first arg must be float");
      if infer env b <> TFloat then raise (Error "fdiv: second arg must be float");
      TFloat
  | App ("neg_f", [a]) ->
      if infer env a <> TFloat then raise (Error "neg_f: arg must be float");
      TFloat
  | App ("to_float", [a]) ->
      if infer env a <> TInt then raise (Error "to_float: arg must be int");
      TFloat
  | App ("to_int", [a]) ->
      if infer env a <> TFloat then raise (Error "to_int: arg must be float");
      TInt
  (* Phase N §12.1: TFloat and TInt share the same 32-bit runtime
     representation, so bit-level reinterpretation is free. These
     builtins are pure typing coercions with zero codegen cost — used
     by lib/math.mcaml to compute fractional-raw = x_bits mod 65536
     etc. on a Q16.16 value. *)
  | App ("raw_of_float", [a]) ->
      if infer env a <> TFloat then raise (Error "raw_of_float: arg must be float");
      TInt
  | App ("float_of_raw", [a]) ->
      if infer env a <> TInt then raise (Error "float_of_raw: arg must be int");
      TFloat

  (* Phase A dyn-array builtins. [array_make] materializes a fresh
     TArrDyn TInt; [array_get]/[array_set] unify against an
     already-known TArrDyn arg. The element type is carried on the
     TArrDyn constructor so future non-int widths come for free. *)
  | App ("array_make", [n; v]) ->
      if infer env n <> TInt then
        raise (Error "array_make: length must be int");
      let tv = infer env v in
      if tv <> TInt then
        raise (Error "array_make: init value must be int");
      TArrDyn tv
  | App ("array_get", [a; i]) ->
      let ta = infer env a in
      let elt =
        match ta with
        | TArrDyn t -> t
        | _ -> raise (Error "array_get: first arg must be a dynamic array")
      in
      if infer env i <> TInt then
        raise (Error "array_get: index must be int");
      elt
  | App ("array_set", [a; i; v]) ->
      let ta = infer env a in
      let elt =
        match ta with
        | TArrDyn t -> t
        | _ -> raise (Error "array_set: first arg must be a dynamic array")
      in
      if infer env i <> TInt then
        raise (Error "array_set: index must be int");
      let tv = infer env v in
      if tv <> elt then
        raise (Error "array_set: value type does not match element type");
      TUnit
  | App ("head", [arg]) ->
      let _ = infer env arg in
      TInt
  | App ("tail", [arg]) ->
      let _ = infer env arg in
      TList TInt

  (* Phase D: constructor application. Ctors are Capitalized and
     top-level fun names are validated lowercase (alpha.ml), so this
     guard can't shadow a real function. *)
  | App (f, args) when Hashtbl.mem ctor_info f ->
      let (adt, fields, _) = Hashtbl.find ctor_info f in
      if List.length args <> List.length fields then
        raise (Error (Printf.sprintf
          "constructor %s expects %d argument(s), got %d"
          f (List.length fields) (List.length args)));
      List.iter2 (fun a ft ->
        let ta = infer env a in
        if ta <> ft then
          raise (Error (Printf.sprintf
            "constructor %s: argument type mismatch" f))) args fields;
      TAdt adt

  | App (f, args) ->
      (match Hashtbl.find_opt fun_sigs f with
       | Some (param_types, ret_type) ->
           let arg_types = List.map (infer env) args in
           if List.length arg_types <> List.length param_types then
             raise (Error (Printf.sprintf
               "App %s: expected %d args, got %d" f
               (List.length param_types) (List.length arg_types)));
           List.iter2 (fun at pt ->
             if at <> pt then
               raise (Error (Printf.sprintf
                 "App %s: arg type mismatch" f))
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
           let ts = List.map (infer env) elems in
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
      let te = infer env e in
      let t =
        match te with
        | TArrStatic (t, _) -> t
        | _ -> raise (Error "a[i] requires an array")
      in
      let ti = infer env i in
      if ti <> TInt then raise (Error "array index must be int");
      t

  | Index2 (e, i, j) ->
      let te = infer env e in
      let t =
        match te with
        | TMat (t, _, _) -> t
        | _ -> raise (Error "m[i, j] requires a matrix")
      in
      let ti = infer env i in
      let tj = infer env j in
      if ti <> TInt then raise (Error "array index must be int");
      if tj <> TInt then raise (Error "array index must be int");
      t

  | IndexSet1 (base, idx, v) ->
      let tb = infer env base in
      let t =
        match tb with
        | TArrStatic (t, _) -> t
        | _ -> raise (Error "a[i] := v requires an array")
      in
      let ti = infer env idx in
      if ti <> TInt then raise (Error "array index must be int");
      let tv = infer env v in
      if tv <> t then raise (Error "a[i] := v: value type does not match element type");
      TUnit

  | IndexSet2 (base, i, j, v) ->
      let tb = infer env base in
      let t =
        match tb with
        | TMat (t, _, _) -> t
        | _ -> raise (Error "m[i, j] := v requires a matrix")
      in
      let ti = infer env i in
      let tj = infer env j in
      if ti <> TInt then raise (Error "array index must be int");
      if tj <> TInt then raise (Error "array index must be int");
      let tv = infer env v in
      if tv <> t then raise (Error "m[i, j] := v: value type does not match element type");
      TUnit

  | Unit -> TUnit

  | Ref e ->
      let t = infer env e in
      TRef t

  | Deref e ->
      (match infer env e with
       | TRef t -> t
       | _ -> raise (Error "! requires a ref"))

  | RefSet (r, v) ->
      let tr = infer env r in
      let tv = infer env v in
      (match tr with
       | TRef t when t = tv -> TUnit
       | TRef _ -> raise (Error "ref := value type mismatch")
       | _ -> raise (Error ":= requires a ref on the left"))

  | Tuple es ->
      (* D7: structural tuple. Every element must be representable as
         an objpool cell field (one scoreboard int each). *)
      let ts = List.map (infer env) es in
      List.iter check_tuple_elem ts;
      TTuple ts

  | Nil ->
      (* v1: monomorphic int lists. Nil defaults to TList TInt; the Cons
         rule below rejects anything else. *)
      TList TInt

  | Cons (h, t) ->
      let th = infer env h in
      let tt = infer env t in
      if th <> TInt then
        raise (Error "::: v1 only supports int lists (head must be int)");
      (match tt with
       | TList TInt -> TList TInt
       | _ -> raise (Error ":: tail must be a list of int"))

  | Region (tr, e) ->
      (* Infer the body's type and write it into the shared ref so
         knormal can read it at normalize time. §C2: v1 accepts every
         representable return type and relies on C5's per-type deep-
         copy walker to make it correct — no escape check here. *)
      let ty = infer env e in
      tr := ty;
      ty

  | Match (scrut, arms) ->
      let tscrut = infer env scrut in
      (match tscrut with
       | TAdt name when not (Hashtbl.mem adt_decls name) ->
           raise (Error (Printf.sprintf
             "match on a value of undeclared type %s" name))
       | _ -> ());
      (* 1. Pattern well-formedness + arm body types (binders shadow
         the outer env — assoc-list prepend). *)
      let arm_tys =
        List.map (fun (p, body) ->
          let binds = check_pattern tscrut p in
          infer (binds @ env) body) arms
      in
      let t0 = List.hd arm_tys in
      List.iteri (fun i t ->
        if t <> t0 then
          raise (Error (Printf.sprintf
            "match arms must all have the same type (arm %d disagrees \
             with arm 1)" (i + 1)))) arm_tys;
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
      if infer env lo <> TInt then raise (Error "for: lo must be int");
      if infer env hi <> TInt then raise (Error "for: hi must be int");
      let env' = (i, TInt) :: env in
      let _ = infer env' body in
      (* body may type as anything; for-loops are statements, result is unit *)
      TUnit