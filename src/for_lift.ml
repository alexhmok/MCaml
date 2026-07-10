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

(* Phase F: name for a lambda-lifted helper. Deliberately does NOT
   contain the substring "__for" (unlike fresh_name) so
   [is_synthetic_name]'s substring check does not mistake it for a
   for-loop helper and skip its real typing — a lambda helper takes
   every capture as an explicit leading param (no borrowed enclosing-
   scope names), so it needs and gets ordinary top-level typing, unlike
   a for-helper. *)
let fresh_lambda_name parent =
  incr counter;
  Printf.sprintf "%s__lam%d" parent !counter

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
  | App (f, args) ->
      (* The callee is a bare identifier, exactly like a Var read: if
         it names a local closure-typed binding (a captured HOF
         parameter or a let-bound lambda), it must be captured just
         like any other free variable, or a lambda that only ever
         CALLS a captured closure (never reads it as a plain value)
         silently loses the capture — the [Lambda] case below relies
         on this to build [fv_list] via [M.find_opt n env], and a
         global top-level function name is simply absent from [env]
         so this is a no-op for the overwhelmingly common case of
         calling an ordinary top-level function. *)
      List.fold_left (fun acc a -> S.union acc (free_vars bound a))
        (if S.mem f bound then S.empty else S.singleton f) args
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
  | Tuple es ->
      List.fold_left (fun acc a -> S.union acc (free_vars bound a))
        S.empty es
  | Record fields ->
      List.fold_left (fun acc (_, a) -> S.union acc (free_vars bound a))
        S.empty fields
  | Field (e, _) -> free_vars bound e
  | Region (_, e) -> free_vars bound e
  (* Phase F: a raw Lambda should never reach here (walk always
     converts it to Closure before computing free vars of the
     surrounding body — see the walk arm below), but stays defensively
     correct: excludes the lambda's own params, same as the real
     conversion does. *)
  | Lambda (params, body) ->
      free_vars (S.union bound (S.of_list (List.map fst params))) body
  | Closure (_, caps) ->
      List.fold_left (fun acc c -> S.union acc (free_vars bound c))
        S.empty caps
  | Match (e, arms) ->
      List.fold_left (fun acc (p, body) ->
        S.union acc (free_vars (S.union (pattern_vars p) bound) body))
        (free_vars bound e) arms

(* Phase D: names bound by a pattern (PVar binders, recursively). *)
and pattern_vars (p : pattern) : S.t =
  match p with
  | PWild | PInt _ | PNil -> S.empty
  | PVar x -> S.singleton x
  | PCtor (_, ps) | PTuple ps ->
      List.fold_left (fun acc p -> S.union acc (pattern_vars p)) S.empty ps
  | PRecord fields ->
      List.fold_left (fun acc (_, p) -> S.union acc (pattern_vars p))
        S.empty fields
  | PCons (ph, pt) -> S.union (pattern_vars ph) (pattern_vars pt)

(* Compute the capture list for a hoisted helper: the free vars that
   are known in [env] (S.elements order — deterministic), minus
   ref-typed ones. Refs lower to globally-stable scoreboard slot
   names; the helper body references them directly by name and does
   NOT need them as captures/params. Shared by the For and Lambda
   hoists below. *)
let capture_list (env : typ M.t) (fvs : S.t) : (string * typ) list =
  S.elements fvs
  |> List.filter_map (fun n ->
       match M.find_opt n env with
       | Some t -> Some (n, t)
       | None -> None)
  |> List.filter (fun (_, t) -> match t with TRef _ -> false | _ -> true)

(* Walk an expression carrying a type env. Returns (new_expr, extra_defs).

   The purely-structural arms (no binder, no name minting) all route
   through [walk1]/[walk2]/[walk3] below, which sequence the child
   walks with explicit [let]s — left-to-right child order is what keeps
   fresh-name minting (a nested For/Lambda in a left child must number
   before one in a right child) and def-list concatenation stable. *)
let rec walk (parent : string) (env : typ M.t) (e : expr)
  : expr * def list =
  match e with
  | For (i, lo, hi, body) ->
      let (lo', d1) = walk parent env lo in
      let (hi', d2) = walk parent env hi in
      let body_env = M.add i TInt env in
      let (body', d3) = walk parent body_env body in
      (* Free variables in body' (minus i). Only keep ones known in env;
         ref-typed fvs are filtered (see [capture_list]). *)
      let fvs = S.remove i (free_vars (S.singleton i) body') in
      let fv_list = capture_list env fvs in
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
      walk2 parent env (fun a b -> BinOp (op, a, b)) a b
  | If (c, a, b) ->
      walk3 parent env (fun c a b -> If (c, a, b)) c a b
  | Seq (a, b) ->
      walk2 parent env (fun a b -> Seq (a, b)) a b
  | App (f, args) ->
      let (args', defs) = walk_list parent env args in
      (App (f, args'), defs)
  | Array es ->
      let (es', defs) = walk_list parent env es in
      (Array es', defs)
  | Index1 (a, i) ->
      walk2 parent env (fun a i -> Index1 (a, i)) a i
  | Index2 (a, i, j) ->
      walk3 parent env (fun a i j -> Index2 (a, i, j)) a i j
  | IndexSet1 (a, i, v) ->
      walk3 parent env (fun a i v -> IndexSet1 (a, i, v)) a i v
  | IndexSet2 (a, i, j, v) ->
      let (a', d1) = walk parent env a in
      let (i', d2) = walk parent env i in
      let (j', d3) = walk parent env j in
      let (v', d4) = walk parent env v in
      (IndexSet2 (a', i', j', v'), d1 @ d2 @ d3 @ d4)
  | Ref e ->
      walk1 parent env (fun e -> Ref e) e
  | Deref e ->
      walk1 parent env (fun e -> Deref e) e
  | RefSet (r, v) ->
      walk2 parent env (fun r v -> RefSet (r, v)) r v
  | Nil -> (Nil, [])
  | Cons (h, t) ->
      walk2 parent env (fun h t -> Cons (h, t)) h t
  | Tuple es ->
      let (es', defs) = walk_list parent env es in
      (Tuple es', defs)
  | Record fields ->
      let pairs =
        List.map (fun (f, e) ->
          let (e', d) = walk parent env e in ((f, e'), d)) fields
      in
      (Record (List.map fst pairs), List.concat_map snd pairs)
  | Field (e, f) ->
      walk1 parent env (fun e -> Field (e, f)) e
  | Region (tr, e) ->
      walk1 parent env (fun e -> Region (tr, e)) e  (* share tr *)
  (* Phase F: closure conversion. Structurally identical to the For
     case above — hoist the lambda's body into a synthetic top-level
     helper taking its free variables as extra (leading) params, and
     replace the occurrence with a call-free reference to that helper
     plus the captured values. Differs from For in exactly one way: a
     lambda is a VALUE (may be stored/returned/passed), not something
     called immediately at its own site, so the replacement is a
     Closure node (which typing reads as TFun(own_params, ret)), not an
     App. (§13.12 F1 sub-decision 3.) *)
  | Lambda (params, body) ->
      let bound_names = S.of_list (List.map fst params) in
      let body_env =
        List.fold_left (fun m (p, t) -> M.add p t m) env params
      in
      let (body', d_inner) = walk parent body_env body in
      let fvs = free_vars bound_names body' in
      let fv_list = capture_list env fvs in
      let synth = fresh_lambda_name parent in
      let helper_params = fv_list @ params in
      let fv_args = List.map (fun (n, _) -> Var n) fv_list in
      (* E4-style optional return annotation: mint an unbound tvar so
         the real Phase 1 typing pass (this helper is NOT
         is_synthetic_name-skipped, unlike a for-helper) infers/checks
         it from body' normally. *)
      let helper = Fun (synth, helper_params, TVar (ref None), body') in
      (Closure (synth, fv_args), d_inner @ [helper])
  (* Only ever produced by this walk itself (see above), never present
     in the input program — kept for match exhaustiveness / defensive
     correctness if a Closure ever arrives already-converted. *)
  | Closure (fname, caps) ->
      let (caps', defs) = walk_list parent env caps in
      (Closure (fname, caps'), defs)
  | Match (e, arms) ->
      let (e', d0) = walk parent env e in
      (* Pattern binders enter the env as TInt: under the §12.1 uniform
         representation every ADT field is a scoreboard int (scalar or
         handle), and the env here only feeds For-helper fv capture and
         Let type threading. Precise field types are typing.ml's job. *)
      let pairs = List.map (fun (p, body) ->
        let env' =
          S.fold (fun v m -> M.add v TInt m) (pattern_vars p) env in
        let (body', d) = walk parent env' body in
        ((p, body'), d)) arms
      in
      (Match (e', List.map fst pairs), d0 @ List.concat_map snd pairs)
  | Int _ | Float _ | Bool _ | Str _ | Selector _ | Coord _
  | Command _ | Unit | Var _ -> (e, [])

(* Walk each expression of a list left-to-right, concatenating the
   hoisted defs in traversal order (helper emission order is
   load-bearing — helpers are compiled in source order). *)
and walk_list (parent : string) (env : typ M.t) (es : expr list)
  : expr list * def list =
  let pairs = List.map (walk parent env) es in
  (List.map fst pairs, List.concat_map snd pairs)

(* Structural-arm combinators: walk 1/2/3 children left-to-right with
   explicit sequential [let]s (see the note on [walk]), rebuild with
   [mk], concatenate the hoisted defs in child order. *)
and walk1 parent env mk a =
  let (a', d) = walk parent env a in
  (mk a', d)

and walk2 parent env mk a b =
  let (a', d1) = walk parent env a in
  let (b', d2) = walk parent env b in
  (mk a' b', d1 @ d2)

and walk3 parent env mk a b c =
  let (a', d1) = walk parent env a in
  let (b', d2) = walk parent env b in
  let (c', d3) = walk parent env c in
  (mk a' b' c', d1 @ d2 @ d3)

let lift_def (d : def) : def list =
  match d with
  | Val _ | TypeDecl _ | RecordDecl _ -> [d]
  | Fun (name, params, ret, body) ->
      let env =
        List.fold_left (fun m (p, t) -> M.add p t m) M.empty params
      in
      let (body', extras) = walk name env body in
      Fun (name, params, ret, body') :: extras

let run (prog : program) : program =
  List.concat_map lift_def prog
