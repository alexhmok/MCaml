(* const_fold.ml — constant propagation + algebraic simplification.

   Per-block forward walk. Tracks a vreg -> int map of values known to be
   compile-time constants at the current program point. Rewrites each
   instruction in place to a simpler form whenever enough operands resolve
   to constants.

   Scope:
   - Does NOT delete instructions (DCE's job).
   - Does NOT touch terminators (branch-elim's job).
   - Does NOT rewrite reserved vregs ($ret, $arr_result, param_N).
   - Per-block only: the map is reset at every block boundary. *)

open Cfg

module M = Map.Make(String)

(* Vanilla scoreboard /= and %= are floorDiv/floorMod (confirmed
   in-game 2026-07-07 on 1.21.x via mc_test_suite t05/t08), NOT
   OCaml's truncating / and mod. Every fold of a division — including
   the Q16.16 pre-shift/scale-up steps below — must floor, or folded
   and runtime code paths diverge on negative operands. sim.py models
   the same floor semantics. *)
let floor_div (a : int) (b : int) : int =
  let q = a / b in
  if a mod b <> 0 && (a < 0) <> (b < 0) then q - 1 else q

let floor_mod (a : int) (b : int) : int =
  a - (floor_div a b) * b

(* Scoreboard values are Java 32-bit ints: += -= *= wrap two's-
   complement, and Math.floorDiv's single overflow case
   (MIN_INT / -1) wraps to MIN_INT too. OCaml's native int is 63-bit,
   so every fold that models a runtime scoreboard op must wrap its
   result to int32 or folded and unfolded code paths diverge the
   moment constant arithmetic overflows (e.g. 2000000000 + 2000000000
   folds to 4000000000 host-side but the runtime computes
   -294967296). Semantics decision (TODO.md 2026-07-11): fold WITH
   the wrap — deterministic and exactly what vanilla does — rather
   than refuse to fold. *)
let wrap32 (n : int) : int =
  let m = n land 0xFFFFFFFF in
  if m >= 0x80000000 then m - 0x100000000 else m

(* Look up [v] in the constant map. Reserved vregs ([Cfg.is_reserved])
   are never known. *)
let get (m : int M.t) (v : vreg) : int option =
  if is_reserved v then None else M.find_opt v m

(* Remove [d] from the map (its old constant status, if any, is lost). *)
let kill (m : int M.t) (d : vreg) : int M.t = M.remove d m

(* Set [d] to a known constant [k] in the map. Reserved vregs are never
   recorded — we must never learn that (say) $ret is a constant since its
   reads cross CFG boundaries invisibly. *)
let set_const (m : int M.t) (d : vreg) (k : int) : int M.t =
  if is_reserved d then M.remove d m else M.add d k m

(* IBinOp with both operands constant: full fold. [i] is returned
   unchanged when the fold must be declined (div-by-zero). Every
   arithmetic result is wrapped to int32 via [wrap32] — the runtime
   is Java int scoreboard ops, which wrap at every step. *)
let fold_binop_const (m : int M.t) (i : instr) (d : vreg)
    (op : Ast.binop) (ka : int) (kb : int) : instr * int M.t * bool =
  let open Ast in
  let fold k = (IConst (d, k), set_const m d k, true) in
  let bool_int x = if x then 1 else 0 in
  match op with
  | Add  -> fold (wrap32 (ka + kb))
  | Sub  -> fold (wrap32 (ka - kb))
  (* FAdd/FSub are scalar-identical to Add/Sub on Q16.16
     encoding (see typing.ml's BinOp comment) — no rescale
     needed for constant folding either. *)
  | FAdd -> fold (wrap32 (ka + kb))
  | FSub -> fold (wrap32 (ka - kb))
  | Mult -> fold (wrap32 (ka * kb))
  | Div  ->
      if kb = 0 then
        (* Do not fold div-by-zero; let runtime handle it. *)
        (i, kill m d, false)
      else
        (* wrap32 covers the single floorDiv overflow case:
           MIN_INT / -1 wraps back to MIN_INT, as Java does. *)
        fold (wrap32 (floor_div ka kb))
  | Mod  ->
      if kb = 0 then
        (i, kill m d, false)
      else
        fold (floor_mod ka kb)
  (* Phase N / N9: Q16.16 fold arms. Must match the runtime
     lowering EXACTLY including precision loss — folded and
     unfolded code paths must produce byte-identical
     scoreboard results or any bisect across a fold boundary
     would yield a false positive. Overflow at any multiply
     step wraps to int32, exactly as the runtime's scoreboard
     ops do (these arms used to decline the fold instead —
     also correct, but wrap is what vanilla computes, so
     folding stays legal AND profitable). *)
  | FMult ->
      (* Matches codegen_helpers N6 pre-shift: (a/256)*(b/256).
         The pre-shifts lower to scoreboard /=, so they floor. *)
      let a' = floor_div ka 256 in
      let b' = floor_div kb 256 in
      fold (wrap32 (a' * b'))
  | FDiv ->
      (* Matches codegen_helpers N7 scale-up-numerator:
         ((a*256)/b)*256, wrapping at each multiply step like
         the scoreboard ops it models. *)
      if kb = 0 then
        (i, kill m d, false)
      else begin
        let first = wrap32 (ka * 256) in
        let divided = floor_div first kb in
        fold (wrap32 (divided * 256))
      end
  | Eq   -> fold (bool_int (ka = kb))
  | Neq  -> fold (bool_int (ka <> kb))
  | Lt   -> fold (bool_int (ka < kb))
  | Gt   -> fold (bool_int (ka > kb))
  | Leq  -> fold (bool_int (ka <= kb))
  | Geq  -> fold (bool_int (ka >= kb))
  | And  -> fold (min ka kb)
  | Or   -> fold (max ka kb)

(* Only [a] is known. Algebraic simp on the left operand.
   We only rewrite to ICopy when the source vreg [b] is not
   reserved — ICopy with a reserved source would create a new
   use of a reserved vreg, which is fine in principle, but
   we're conservative and leave those alone. *)
let simplify_binop_left (m : int M.t) (i : instr) (d : vreg)
    (op : Ast.binop) (ka : int) (b : vreg) : instr * int M.t * bool =
  let open Ast in
  match op with
  | Add when ka = 0 && not (is_reserved b) ->
      (ICopy (d, b), kill m d, true)
  | Mult when ka = 0 ->
      (IConst (d, 0), set_const m d 0, true)
  | Mult when ka = 1 && not (is_reserved b) ->
      (ICopy (d, b), kill m d, true)
  | _ ->
      (i, kill m d, false)

(* Only [b] is known. Algebraic simp on the right operand. *)
let simplify_binop_right (m : int M.t) (i : instr) (d : vreg)
    (op : Ast.binop) (a : vreg) (kb : int) : instr * int M.t * bool =
  let open Ast in
  match op with
  | Add when kb = 0 && not (is_reserved a) ->
      (ICopy (d, a), kill m d, true)
  | Sub when kb = 0 && not (is_reserved a) ->
      (ICopy (d, a), kill m d, true)
  | Mult when kb = 0 ->
      (IConst (d, 0), set_const m d 0, true)
  | Mult when kb = 1 && not (is_reserved a) ->
      (ICopy (d, a), kill m d, true)
  | Div when kb = 1 && not (is_reserved a) ->
      (ICopy (d, a), kill m d, true)
  | Div when kb = 0 ->
      (i, kill m d, false)
  | _ ->
      (i, kill m d, false)

(* Neither operand is a known constant. Only the a=b→0
   pattern for Sub applies. Guard against reserved [a]
   per the plan's Gotcha #4. *)
let simplify_binop_neither (m : int M.t) (i : instr) (d : vreg)
    (op : Ast.binop) (a : vreg) (b : vreg) : instr * int M.t * bool =
  let open Ast in
  match op with
  | Sub when a = b && not (is_reserved a) ->
      (IConst (d, 0), set_const m d 0, true)
  | _ ->
      (i, kill m d, false)

(* Rewrite a single instruction using the current constant map.
   Returns (new_instr, updated_map, changed_flag). *)
let rewrite_instr (m : int M.t) (i : instr) : instr * int M.t * bool =
  match i with
  | IConst (d, k) ->
      (i, set_const m d k, false)

  | ICopy (d, v) ->
      if is_reserved d then
        (* Never rewrite a reserved dest; just make sure it's not tracked. *)
        (i, kill m d, false)
      else begin
        match get m v with
        | Some k ->
            (IConst (d, k), set_const m d k, true)
        | None ->
            (i, kill m d, false)
      end

  | IBinOp (d, op, a, b) ->
      if is_reserved d then
        (* Leave reserved-dest binops strictly alone. *)
        (i, kill m d, false)
      else begin
        let ka = get m a in
        let kb = get m b in
        match ka, kb with
        | Some ka, Some kb -> fold_binop_const m i d op ka kb
        | Some ka, None    -> simplify_binop_left m i d op ka b
        | None, Some kb    -> simplify_binop_right m i d op a kb
        | None, None       -> simplify_binop_neither m i d op a b
      end

  | IArrGet (d, id, idx) ->
      (* When the index resolves to a constant, rewrite to a static get
         so SROA can promote the array. This is the bridge from unrolling
         (which substitutes loop var with IConst) to SROA. *)
      (match get m idx with
       | Some k -> (IArrGetStatic (d, id, k), kill m d, true)
       | None -> (i, kill m d, false))

  | IArrSet (id, idx, v) ->
      (* Same bridge as IArrGet: if the runtime index is a known constant,
         rewrite to IArrSetStatic so SROA can promote static-only arrays. *)
      (match get m idx with
       | Some k -> (IArrSetStatic (id, k, v), m, true)
       | None -> (i, m, false))

  (* Every other instruction is left as-is and only touches the map via
     its def (if any). Call results, static-array reads, dynamic-heap /
     cons / ADT reads (runtime pool indices or NBT values), and closure
     handles / apply results are never statically-knowable ints — kill
     the dest. Def-less instructions (commands, stores, array literals,
     region brackets) pass the map through unchanged. *)
  | _ ->
      (match instr_def i with
       | Some d -> (i, kill m d, false)
       | None -> (i, m, false))

let run (cfg : cfg_func) : bool =
  let changed = ref false in
  Array.iter (fun (b : block) ->
    let m = ref M.empty in
    let new_instrs =
      List.map (fun i ->
        let (i', m', c) = rewrite_instr !m i in
        if c then changed := true;
        m := m';
        i'
      ) b.instrs
    in
    b.instrs <- new_instrs
  ) cfg.blocks;
  !changed
