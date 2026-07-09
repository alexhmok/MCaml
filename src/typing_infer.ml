(* typing_infer.ml — the unification-based [infer] walk, its public
   (string * typ) list wrapper, and the per-def driver [type_fun_def].
   Split from typing.ml in refactor step 7; re-exported through the
   Typing facade. *)
open Ast
open Typing_core
open Typing_unify
open Typing_patterns

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
           (* OCaml-style split: plain operators are int-only. Float
              arithmetic goes through the dotted operators (+. -. *. /.)
              below — mixing them is a type error, not silent coercion. *)
           unify_msg t1 t2 "Type mismatch in binary operation";
           (match resolve t1 with
            | TInt -> TInt
            | TFloat ->
                raise (Error "`+`/`-`/`*`/`/`/`%` are int-only; \
                              use `+.`/`-.`/`*.`/`/.` for float arithmetic")
            | TVar _ ->
                (* §13.10 decision 5: two unconstrained operands default
                   to int eagerly (OCaml-compatible `+`). *)
                unify_msg t1 TInt "Type mismatch in binary operation";
                TInt
            | _ -> raise (Error "Type mismatch in binary operation"))
       | FAdd | FSub | FMult | FDiv ->
           (* Phase N / N5: FAdd/FSub are scalar-identical to Add/Sub on
              Q16.16 encoding — (x*65536 + y*65536) = (x+y)*65536 — but
              still type-checked as their own arm so `+.`/`-.` reject int
              operands exactly as `+`/`-` reject float ones. FMult/FDiv
              lower to the multi-command pre-shift/scale-up sequences in
              codegen_helpers.ml. *)
           unify_msg t1 t2 "Type mismatch in binary operation";
           (match resolve t1 with
            | TFloat -> TFloat
            | TVar _ ->
                unify_msg t1 TFloat "Type mismatch in binary operation";
                TFloat
            | _ ->
                raise (Error "`+.`/`-.`/`*.`/`/.` are float-only; \
                              use `+`/`-`/`*`/`/` for int arithmetic"))
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
           TBool)

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