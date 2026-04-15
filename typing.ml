(* typing.ml *)
open Ast

exception Error of string

(* Global function signature table. Populated by [build_sigs] on the
   post-for_lift program. Consulted by the [App] rule so that calls type
   against the callee's declared parameter/return types instead of the
   legacy "always TInt" fallback. Lookup miss => TInt fallback
   (preserves behavior for synthesized helpers and any untyped callees). *)
let fun_sigs : (string, typ list * typ) Hashtbl.t = Hashtbl.create 16

let build_sigs (prog : program) : unit =
  Hashtbl.clear fun_sigs;
  List.iter (fun d ->
    match d with
    | Fun (name, params, ret, _) ->
        Hashtbl.replace fun_sigs name (List.map snd params, ret)
    | Val _ -> ()
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
       with Not_found -> raise (Error ("Undefined variable: " ^ x)))
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

  | For (i, lo, hi, body) ->
      if infer env lo <> TInt then raise (Error "for: lo must be int");
      if infer env hi <> TInt then raise (Error "for: hi must be int");
      let env' = (i, TInt) :: env in
      let _ = infer env' body in
      (* body may type as anything; for-loops are statements, result is unit *)
      TUnit