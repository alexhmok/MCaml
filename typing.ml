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
  | Float _ -> TInt (* MC uses fixed point, treating as Int for now *)
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
       | (Add|Sub|Mult|Div), TInt, TInt -> TInt
       | (Eq|Neq|Lt|Gt|Leq|Geq), TInt, TInt -> TBool
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

  | Region e -> infer env e

  | For (i, lo, hi, body) ->
      if infer env lo <> TInt then raise (Error "for: lo must be int");
      if infer env hi <> TInt then raise (Error "for: hi must be int");
      let env' = (i, TInt) :: env in
      let _ = infer env' body in
      (* body may type as anything; for-loops are statements, result is unit *)
      TUnit