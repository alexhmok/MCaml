(* alpha.ml *)
open Ast

module M = Map.Make(String)

let counter = ref 0
let new_name x =
  incr counter;
  Printf.sprintf "%s_%d" x !counter

(* Rename Expressions *)
let rec g env e = 
  match e with
  | Var x -> Var (try M.find x env with Not_found -> x)
  | Let (x, e1, e2) ->
      let x' = new_name x in
      let env' = M.add x x' env in
      Let (x', g env e1, g env' e2)
  
  (* Recursive Boilerplate *)
  | Int i -> Int i | Float f -> Float f | Bool b -> Bool b | Str s -> Str s
  | Selector s -> Selector s | Coord(x,y,z) -> Coord(x,y,z) | Command c -> Command c
  | BinOp(op, e1, e2) -> BinOp(op, g env e1, g env e2)
  | If(c, e1, e2) -> If(g env c, g env e1, g env e2)
  | Seq(e1, e2) -> Seq(g env e1, g env e2)
  | App(f, args) -> App(f, List.map (g env) args)
  | Array elems -> Array (List.map (g env) elems)
  | Index1 (e, i) -> Index1 (g env e, g env i)
  | Index2 (e, i, j) -> Index2 (g env e, g env i, g env j)
  | IndexSet1 (a, i, v) -> IndexSet1 (g env a, g env i, g env v)
  | IndexSet2 (a, i, j, v) -> IndexSet2 (g env a, g env i, g env j, g env v)
  | Unit -> Unit
  | Ref e -> Ref (g env e)
  | Deref e -> Deref (g env e)
  (* Parser produces RefSet for every `:=`. An Index1/Index2 on the
     LHS is really an indexed assignment — rewrite it here so downstream
     passes only see the dedicated IndexSet1/IndexSet2 nodes. *)
  | RefSet (Index1 (a, i), v) ->
      IndexSet1 (g env a, g env i, g env v)
  | RefSet (Index2 (a, i, j), v) ->
      IndexSet2 (g env a, g env i, g env j, g env v)
  | RefSet (r, v) -> RefSet (g env r, g env v)
  | Nil -> Nil
  | Cons (h, t) -> Cons (g env h, g env t)
  | For (i, lo, hi, body) ->
      let i' = new_name i in
      let env' = M.add i i' env in
      For (i', g env lo, g env hi, g env' body)

(* Rename Definitions (Top Level) *)
let h env d =
  match d with
  | Val (name, e) -> Val (name, g env e) (* We don't rename global values in this MVP *)
  | Fun (name, params, ret, body) ->
      (* 1. Rename parameters *)
      let (params', env') = List.fold_right (fun (p, t) (ps, acc_env) ->
        let p' = new_name p in
        ((p', t) :: ps, M.add p p' acc_env)
      ) params ([], env) in
      
      (* 2. Rename body using new param names *)
      Fun (name, params', ret, g env' body)