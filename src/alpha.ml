(* alpha.ml *)
open Ast

module M = Map.Make(String)

let counter = ref 0
let new_name x =
  incr counter;
  Printf.sprintf "%s_%d" x !counter

(* Validate that a top-level `val` or `fun` binder name is a valid
   Minecraft resource location path segment: `[a-z_][a-z0-9_]*`.

   MCaml's lexer accepts `[a-zA-Z_][a-zA-Z0-9_]*` for identifiers, but
   codegen uses top-level binder names directly as:
     - function file names       (<fun>.mcfunction, <val>_get.mcfunction,
                                  <val>_set.mcfunction, <fun>_callN.mcfunction,
                                  <fun>__forN__body.mcfunction, …)
     - storage paths             (mcaml:heap __g_<val>)
     - init-helper dispatches    (/function mcaml:init etc.)

   Real Minecraft's `/function` command parser rejects any character
   outside `[a-z0-9/._-]` in the resource location path and bails out
   with a cryptic "expected whitespace to end one argument, but found
   trailing data" error. Silently-dropped macro getters are the
   classic failure mode: `__g_X_get.mcfunction` won't load, dynamic
   array reads become no-ops, the matmul output reads as zero, and
   the compiled model produces garbage under real Minecraft while
   sim.py (which uses Python dict lookups) keeps working.

   This check fails fast at compile time with a specific error so the
   user doesn't discover the breakage only after packaging and
   loading the datapack.

   Let-bound names and function parameters are NOT validated here —
   those only surface inside scoreboard slot names (`$ref_<name>_<N>`)
   and scoreboard player names accept any non-whitespace char. *)
let validate_toplevel_name kind name =
  let is_valid_rest c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_'
  in
  let is_valid_first c =
    (c >= 'a' && c <= 'z') || c = '_'
  in
  if String.length name = 0 then
    failwith (Printf.sprintf "top-level %s has an empty name" kind)
  else if not (is_valid_first name.[0]) then
    failwith (Printf.sprintf
      "top-level %s '%s': name must start with [a-z_] to produce a \
       valid Minecraft resource location. The /function command parser \
       accepts [a-z0-9_./-] only and silently drops functions with any \
       uppercase character. Rename '%s' to something like '%s'."
      kind name name (String.lowercase_ascii name))
  else
    String.iter (fun c ->
      if not (is_valid_rest c) then
        failwith (Printf.sprintf
          "top-level %s '%s': name must be [a-z0-9_] only, but contains \
           '%c'. Minecraft /function parser rejects it. Rename '%s' to \
           something like '%s'."
          kind name c name (String.lowercase_ascii name))
    ) name

(* Rename a parameter list, threading each fresh binder into the env.
   Shared by Lambda (in [g]) and top-level Fun (in [h]). fold_right, so
   [new_name] mints counters in reverse param order — both call sites
   always did this; preserved because the _N suffixes are observable in
   emitted slot names. *)
let rename_params env params =
  List.fold_right (fun (p, t) (ps, acc_env) ->
    let p' = new_name p in
    ((p', t) :: ps, M.add p p' acc_env)
  ) params ([], env)

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
  (* Phase F: rename the callee too when it resolves as a local binder
     (a HOF's own function-typed parameter, or a let-bound lambda alias)
     so typing's value-application check (which looks the RENAMED name
     up in its scheme env) can find it. Falls back to the untouched
     name otherwise — exactly today's behavior — so this is a no-op for
     every existing call to a genuine top-level function: top-level Fun
     names are never added to [env] (only Let/For/Match/param binders
     are), so [f] can only be found here if it shadows a local. *)
  | App(f, args) ->
      App((try M.find f env with Not_found -> f), List.map (g env) args)
  | Lambda (params, body) ->
      let (params', env') = rename_params env params in
      Lambda (params', g env' body)
  | Closure (fname, caps) -> Closure (fname, List.map (g env) caps)
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
  | Tuple es -> Tuple (List.map (g env) es)
  | Record fields ->
      Record (List.map (fun (f, e) -> (f, g env e)) fields)
  | Field (e, f) -> Field (g env e, f)
  | Region (tr, e) -> Region (tr, g env e)   (* share tr so typing's write is visible downstream *)
  (* Phase D: pattern variables are binders — rename them like Let/For
     binders so `let r = 5 in match e with Circle(r) -> r` resolves the
     body's r to the pattern binding, not the outer let. *)
  | Match (e, arms) ->
      let e' = g env e in
      let arms' = List.map (fun (p, body) ->
        (* Duplicate binders (`Square(w, w)`) must be caught HERE:
           renaming gives every PVar a fresh name, so after alpha the
           duplication is invisible to typing. *)
        check_dup_binders p;
        let (p', env') = rename_pattern env p in
        (p', g env' body)) arms in
      Match (e', arms')
  | For (i, lo, hi, body) ->
      let i' = new_name i in
      let env' = M.add i i' env in
      For (i', g env lo, g env hi, g env' body)

and check_dup_binders p =
  let rec binders p acc =
    match p with
    | PWild | PInt _ | PNil -> acc
    | PVar x -> x :: acc
    | PCtor (_, ps) | PTuple ps ->
        List.fold_left (fun a q -> binders q a) acc ps
    | PRecord fields ->
        List.fold_left (fun a (_, q) -> binders q a) acc fields
    | PCons (ph, pt) -> binders pt (binders ph acc)
  in
  let names = List.sort compare (binders p []) in
  let rec dup = function
    | a :: b :: _ when a = b -> Some a
    | _ :: rest -> dup rest
    | [] -> None
  in
  match dup names with
  | Some x ->
      failwith (Printf.sprintf
        "pattern binds variable '%s' more than once" x)
  | None -> ()

and rename_pattern env p =
  match p with
  | PWild -> (PWild, env)
  | PInt i -> (PInt i, env)
  | PVar x ->
      let x' = new_name x in
      (PVar x', M.add x x' env)
  | PCtor (c, ps) ->
      let (ps', env') = rename_pattern_list env ps in
      (PCtor (c, ps'), env')
  | PTuple ps ->
      let (ps', env') = rename_pattern_list env ps in
      (PTuple ps', env')
  | PRecord fields ->
      let (fs_rev, env') =
        List.fold_left (fun (acc, e) (f, p) ->
          let (p', e') = rename_pattern e p in
          ((f, p') :: acc, e')) ([], env) fields
      in
      (PRecord (List.rev fs_rev), env')
  | PNil -> (PNil, env)
  | PCons (ph, pt) ->
      let (ph', env') = rename_pattern env ph in
      let (pt', env'') = rename_pattern env' pt in
      (PCons (ph', pt'), env'')

(* Rename a sub-pattern list left-to-right, threading the env. *)
and rename_pattern_list env ps =
  let (ps_rev, env') =
    List.fold_left (fun (acc, e) p ->
      let (p', e') = rename_pattern e p in
      (p' :: acc, e')) ([], env) ps
  in
  (List.rev ps_rev, env')

(* Rename Definitions (Top Level) *)
let h env d =
  match d with
  | TypeDecl _ | RecordDecl _ -> d
      (* Phase D: type declarations bind no runtime names; ctor-name
         validation (Capitalized, unique) happens at registration in
         typing.ml where the error messages have full context. *)
  | Val (name, e) ->
      validate_toplevel_name "val" name;
      Val (name, g env e) (* We don't rename global values in this MVP *)
  | Fun (name, params, ret, body) ->
      validate_toplevel_name "fun" name;
      (* 1. Rename parameters *)
      let (params', env') = rename_params env params in

      (* 2. Rename body using new param names *)
      Fun (name, params', ret, g env' body)