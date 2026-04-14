(* for_lift.ml — hoist every For loop into a fresh top-level tail-recursive
   helper function. Runs AFTER alpha and BEFORE typing/knormal.

   Desugaring: `for i = lo to hi do body done` becomes a call to a synthetic
   helper

     fun <enclosing>__forN(i, hi_p, ...fvs): unit =
       if i < hi_p then (body; <enclosing>__forN(i+1, hi_p, ...fvs))
       else ()

   where fvs are the free variables of body excluding [i] (and excluding
   refs — refs resolve to globally-stable scoreboard slot names so the
   helper body references them by name without needing to pass them).

   The helper's body is the original for body verbatim; since alpha already
   ran, all bindings are globally unique and no collisions arise. Helpers
   are appended to the program so they appear AFTER their caller in the
   driver's iteration order (so knormal's persistent ref_env is populated
   by the caller before the helper is processed). *)

open Ast

module S = Set.Make (String)
module M = Map.Make (String)

let counter = ref 0
let fresh_name parent =
  incr counter;
  Printf.sprintf "%s__for%d" parent !counter

let fresh_hi_name () =
  incr counter;
  Printf.sprintf "__hi_%d" !counter

(* Is this def name a synthesized for helper? Used by main.ml to skip
   typing (helpers reference the enclosing function's locals directly,
   which are not in their own param env). *)
let is_synthetic_name (name : string) : bool =
  let needle = "__for" in
  let nlen = String.length needle in
  let slen = String.length name in
  let rec loop i =
    if i + nlen > slen then false
    else if String.sub name i nlen = needle then true
    else loop (i + 1)
  in
  loop 0

(* Simple free-variable collector. Ignores [bound] names. *)
let rec free_vars (bound : S.t) (e : expr) : S.t =
  match e with
  | Int _ | Float _ | Bool _ | Str _ | Selector _ | Coord _
  | Command _ | Unit -> S.empty
  | Var x -> if S.mem x bound then S.empty else S.singleton x
  | BinOp (_, e1, e2) ->
      S.union (free_vars bound e1) (free_vars bound e2)
  | Let (x, e1, e2) ->
      S.union (free_vars bound e1) (free_vars (S.add x bound) e2)
  | If (c, a, b) ->
      S.union (free_vars bound c)
        (S.union (free_vars bound a) (free_vars bound b))
  | App (_, args) ->
      List.fold_left (fun acc a -> S.union acc (free_vars bound a))
        S.empty args
  | Seq (e1, e2) -> S.union (free_vars bound e1) (free_vars bound e2)
  | Array es ->
      List.fold_left (fun acc a -> S.union acc (free_vars bound a))
        S.empty es
  | Index1 (a, i) -> S.union (free_vars bound a) (free_vars bound i)
  | Index2 (a, i, j) ->
      S.union (free_vars bound a)
        (S.union (free_vars bound i) (free_vars bound j))
  | IndexSet1 (a, i, v) ->
      S.union (free_vars bound a)
        (S.union (free_vars bound i) (free_vars bound v))
  | IndexSet2 (a, i, j, v) ->
      S.union (free_vars bound a)
        (S.union (free_vars bound i)
           (S.union (free_vars bound j) (free_vars bound v)))
  | Ref e -> free_vars bound e
  | Deref e -> free_vars bound e
  | RefSet (r, v) -> S.union (free_vars bound r) (free_vars bound v)
  | For (i, lo, hi, body) ->
      S.union (free_vars bound lo)
        (S.union (free_vars bound hi)
           (free_vars (S.add i bound) body))
  | Nil -> S.empty
  | Cons (h, t) -> S.union (free_vars bound h) (free_vars bound t)

(* Walk an expression carrying a type env. Returns (new_expr, extra_defs). *)
let rec walk (parent : string) (env : typ M.t) (e : expr)
  : expr * def list =
  match e with
  | For (i, lo, hi, body) ->
      let (lo', d1) = walk parent env lo in
      let (hi', d2) = walk parent env hi in
      let body_env = M.add i TInt env in
      let (body', d3) = walk parent body_env body in
      (* Free variables in body' (minus i). Only keep ones known in env. *)
      let fvs = S.remove i (free_vars (S.singleton i) body') in
      let fv_list =
        S.elements fvs
        |> List.filter_map (fun n ->
             match M.find_opt n env with
             | Some t -> Some (n, t)
             | None -> None)
      in
      (* Refs lower to globally-stable scoreboard slot names; the helper
         body references them directly by name and does NOT need them as
         parameters. Filter them out. *)
      let fv_list =
        List.filter
          (fun (_, t) -> match t with TRef _ -> false | _ -> true)
          fv_list
      in
      let synth = fresh_name parent in
      let hi_p = fresh_hi_name () in
      let params =
        (i, TInt) :: (hi_p, TInt)
        :: List.map (fun (n, t) -> (n, t)) fv_list
      in
      let fv_args = List.map (fun (n, _) -> Var n) fv_list in
      let recur =
        App (synth, BinOp (Add, Var i, Int 1) :: Var hi_p :: fv_args)
      in
      (* Both If branches must type. App currently types as TInt, Int 0
         types as TInt, so they match. The helper's declared return type
         is TUnit but typing does not check that. *)
      let helper_body =
        If (BinOp (Lt, Var i, Var hi_p),
            Seq (body', recur),
            Int 0)
      in
      let helper = Fun (synth, params, TUnit, helper_body) in
      let call = App (synth, lo' :: hi' :: fv_args) in
      (call, d1 @ d2 @ d3 @ [helper])
  | Let (x, e1, e2) ->
      let (e1', d1) = walk parent env e1 in
      (* Infer the type of e1 in the current env for threading. Typing
         errors are surfaced when main.ml later runs typing on the result. *)
      let tx =
        try Typing.infer (M.bindings env) e1
        with Typing.Error _ -> TInt
      in
      let env' = M.add x tx env in
      let (e2', d2) = walk parent env' e2 in
      (Let (x, e1', e2'), d1 @ d2)
  | BinOp (op, a, b) ->
      let (a', d1) = walk parent env a in
      let (b', d2) = walk parent env b in
      (BinOp (op, a', b'), d1 @ d2)
  | If (c, a, b) ->
      let (c', d1) = walk parent env c in
      let (a', d2) = walk parent env a in
      let (b', d3) = walk parent env b in
      (If (c', a', b'), d1 @ d2 @ d3)
  | Seq (a, b) ->
      let (a', d1) = walk parent env a in
      let (b', d2) = walk parent env b in
      (Seq (a', b'), d1 @ d2)
  | App (f, args) ->
      let pairs = List.map (walk parent env) args in
      let args' = List.map fst pairs in
      let defs = List.concat_map snd pairs in
      (App (f, args'), defs)
  | Array es ->
      let pairs = List.map (walk parent env) es in
      (Array (List.map fst pairs), List.concat_map snd pairs)
  | Index1 (a, i) ->
      let (a', d1) = walk parent env a in
      let (i', d2) = walk parent env i in
      (Index1 (a', i'), d1 @ d2)
  | Index2 (a, i, j) ->
      let (a', d1) = walk parent env a in
      let (i', d2) = walk parent env i in
      let (j', d3) = walk parent env j in
      (Index2 (a', i', j'), d1 @ d2 @ d3)
  | IndexSet1 (a, i, v) ->
      let (a', d1) = walk parent env a in
      let (i', d2) = walk parent env i in
      let (v', d3) = walk parent env v in
      (IndexSet1 (a', i', v'), d1 @ d2 @ d3)
  | IndexSet2 (a, i, j, v) ->
      let (a', d1) = walk parent env a in
      let (i', d2) = walk parent env i in
      let (j', d3) = walk parent env j in
      let (v', d4) = walk parent env v in
      (IndexSet2 (a', i', j', v'), d1 @ d2 @ d3 @ d4)
  | Ref e ->
      let (e', d) = walk parent env e in
      (Ref e', d)
  | Deref e ->
      let (e', d) = walk parent env e in
      (Deref e', d)
  | RefSet (r, v) ->
      let (r', d1) = walk parent env r in
      let (v', d2) = walk parent env v in
      (RefSet (r', v'), d1 @ d2)
  | Nil -> (Nil, [])
  | Cons (h, t) ->
      let (h', d1) = walk parent env h in
      let (t', d2) = walk parent env t in
      (Cons (h', t'), d1 @ d2)
  | Int _ | Float _ | Bool _ | Str _ | Selector _ | Coord _
  | Command _ | Unit | Var _ -> (e, [])

let lift_def (d : def) : def list =
  match d with
  | Val _ -> [d]
  | Fun (name, params, ret, body) ->
      let env =
        List.fold_left (fun m (p, t) -> M.add p t m) M.empty params
      in
      let (body', extras) = walk name env body in
      Fun (name, params, ret, body') :: extras

let run (prog : program) : program =
  List.concat_map lift_def prog
