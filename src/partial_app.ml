(* partial_app.ml — explicit partial application.

   Approved Stage 2 item (2026-07-11): lifts the EXPLICIT-form half of
   §13.12 decision 1's v1 deferral. `f(a1 .. ak)` where [f] is a
   top-level fun of declared arity n > k desugars, post-alpha and
   pre-for_lift, into

     let __pa<N>_a1 = a1 in ... let __pa<N>_ak = ak in
     fun (__pa<N>_p{k+1}, .., __pa<N>_pn) ->
       f(__pa<N>_a1, .., __pa<N>_ak, __pa<N>_p{k+1}, .., __pa<N>_pn)

   Supplied arguments evaluate exactly once, at partial-application
   time (the let temps) — NOT per call of the resulting closure. The
   lambda then rides the entire Phase F pipeline unchanged: for_lift
   closure-converts it, closure_spec specializes call sites inlining
   exposes, and everything else takes F5's apply-dispatch runtime.
   Full auto-currying (every call site implicitly curried) remains
   rejected per decision 1 — this pass fires only on a syntactically
   under-applied call to a known top-level function.

   Deliberately NOT desugared (the ordinary arity error stays):
   - targets with an array/matrix/ref parameter — those params are not
     first-class values (arrays are compile-time storage ids, refs are
     reserved slots), so a temp cannot hold one;
   - over-application, calls through closure-typed locals (no
     syntactic arity to consult), constructors, and builtins.

   Runs after alpha (binder names are globally unique; a local
   shadowing a fun name was already renamed, so an App callee that
   matches a top-level fun name really is that fun) and before
   for_lift (which consumes the synthesized Lambda). Minted binder
   names use the "__pa" prefix + a global counter, which alpha can
   never produce, preserving global uniqueness. *)

open Ast

let counter = ref 0

let first_class_param (t : typ) : bool =
  match t with
  | TArrStatic _ | TMat _ | TRef _ -> false
  | _ -> true

(* arity map: top-level fun name -> declared param types *)
let build_map (program : def list) : (string, typ list) Hashtbl.t =
  let m = Hashtbl.create 16 in
  List.iter (function
    | Fun (name, params, _, _) ->
        Hashtbl.replace m name (List.map snd params)
    | _ -> ()) program;
  m

let rec rw (m : (string, typ list) Hashtbl.t) (e : expr) : expr =
  match e with
  | App (f, args) ->
      let args = List.map (rw m) args in
      (match Hashtbl.find_opt m f with
       | Some ptypes
         when List.length args < List.length ptypes
              && List.for_all first_class_param ptypes ->
           incr counter;
           let n = !counter in
           let k = List.length args in
           let temp i = Printf.sprintf "__pa%d_a%d" n (i + 1) in
           let pname i = Printf.sprintf "__pa%d_p%d" n (i + 1) in
           let temps = List.mapi (fun i _ -> temp i) args in
           let rest =
             List.filteri (fun i _ -> i >= k) ptypes
             |> List.mapi (fun i _ -> pname (k + i))
           in
           (* fresh unification vars for the lambda binders — the App
              in the body pins them against f's signature; sharing the
              decl's own TVar refs across defs is what we're avoiding *)
           let lam_params = List.map (fun p -> (p, TVar (ref None))) rest in
           let call =
             App (f, List.map (fun v -> Var v) temps
                     @ List.map (fun p -> Var p) rest)
           in
           List.fold_right2 (fun t a acc -> Let (t, a, acc))
             temps args (Lambda (lam_params, call))
       | _ -> App (f, args))
  | Int _ | Float _ | Bool _ | Str _ | Var _ | Selector _ | Coord _
  | Command _ | Unit | Nil -> e
  | BinOp (op, a, b) -> BinOp (op, rw m a, rw m b)
  | Let (x, a, b) -> Let (x, rw m a, rw m b)
  | If (c, a, b) -> If (rw m c, rw m a, rw m b)
  | Seq (a, b) -> Seq (rw m a, rw m b)
  | Array es -> Array (List.map (rw m) es)
  | Index1 (a, i) -> Index1 (rw m a, rw m i)
  | Index2 (a, i, j) -> Index2 (rw m a, rw m i, rw m j)
  | IndexSet1 (a, i, v) -> IndexSet1 (rw m a, rw m i, rw m v)
  | IndexSet2 (a, i, j, v) -> IndexSet2 (rw m a, rw m i, rw m j, rw m v)
  | Ref a -> Ref (rw m a)
  | Deref a -> Deref (rw m a)
  | RefSet (r, v) -> RefSet (rw m r, rw m v)
  | For (i, lo, hi, body) -> For (i, rw m lo, rw m hi, rw m body)
  | Cons (h, t) -> Cons (rw m h, rw m t)
  | Region (tr, a) -> Region (tr, rw m a)
  | Match (s, arms) ->
      Match (rw m s, List.map (fun (p, b) -> (p, rw m b)) arms)
  | Tuple es -> Tuple (List.map (rw m) es)
  | Record fields -> Record (List.map (fun (f, v) -> (f, rw m v)) fields)
  | Field (a, f) -> Field (rw m a, f)
  | Lambda (params, body) -> Lambda (params, rw m body)
  | Closure (f, caps) -> Closure (f, List.map (rw m) caps)

let run (program : def list) : def list =
  let m = build_map program in
  List.map (function
    | Fun (name, params, ret, body) -> Fun (name, params, ret, rw m body)
    | d -> d) program
