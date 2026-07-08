(* knormal.ml *)
open Ast

(* Phase A dynamic-heap pool tag. Shared with [Cfg.heap_pool] via
   [Ast.heap_pool] (defined in ast.ml so the pre-cfg codegen_helpers can
   reference it too). *)
type heap_pool = Ast.heap_pool = PoolScratch | PoolPermheap

type kexpr =
  | KUnit
  | KInt of int
  | KVar of string
  | KStr of string
  | KCommand of string
  | KBinOp of binop * string * string
  | KLet of string * kexpr * kexpr
  | KAssign of string * kexpr  (* NEW: Explicit assignment *)
  | KIf of string * kexpr * kexpr
  | KSeq of kexpr * kexpr
  | KCall of string * string list
  | KLoop of string * string list
  (* --- array / matrix primitives (Milestone 1) --- *)
  (* KArrLitConst(id, [1;2;3]) — allocate storage id with a constant int list *)
  | KArrLitConst of string * int list
  (* KArrLitDyn(id, [t1; t2; t3]) — allocate storage id and initialize from scoreboard temps *)
  | KArrLitDyn of string * string list
  (* KArrGetStatic(dest_score, id, k) — dest = storage[id][k], k compile-time *)
  | KArrGetStatic of string * string * int
  (* KArrGet(dest_score, id, idx_score) — dest = storage[id][idx], idx runtime *)
  | KArrGet of string * string * string
  (* KArrSetStatic(id, k, val_temp) — storage[id][k] := val, k compile-time *)
  | KArrSetStatic of string * int * string
  (* KArrSet(id, idx_temp, val_temp) — storage[id][idx] := val, idx runtime *)
  | KArrSet of string * string * string
  (* --- Phase A dynamic-heap primitives --- *)
  (* KDynAllocConst(base_dest, pool, n) — compile-time known-size sibling
     of KDynAlloc; codegen straight-lines the append sequence. *)
  | KDynAllocConst of string * heap_pool * int
  (* KDynAlloc(base_dest, pool, n_vreg) — runtime-sized variant. *)
  | KDynAlloc of string * heap_pool * string
  (* KHeapGet(dest, pool, base_vreg, idx_vreg) — dest := pool[base+idx] *)
  | KHeapGet of string * heap_pool * string * string
  (* KHeapSet(pool, base_vreg, idx_vreg, val_vreg) — pool[base+idx] := val *)
  | KHeapSet of heap_pool * string * string * string
  (* --- Phase B cons-list primitives --- *)
  (* KCons(d, h_vreg, t_vreg) — d := cons(h, t); objpool append. *)
  | KCons of string * string * string
  (* KHead(d, c_vreg) — d := head(c) *)
  | KHead of string * string
  (* KTail(d, c_vreg) — d := tail(c) *)
  | KTail of string * string
  (* --- Phase C region primitives --- *)
  (* KRegion(body, ret_typ, dest) — lexical arena bracket. cfg_build
     wraps [body] with IRegionEnter/IRegionExit, threading [ret_typ]
     through to the exit op so codegen_cfg picks the right deep-copy
     walker (none for TInt/TBool/TUnit, TList TInt's stash+rebuild
     walker for cons lists). [dest] captures the ambient let-binder
     the region's result flows into — it's needed by the heap-return
     exit path because KSeq's lowering passes [~dest:None] for the
     first argument, which would otherwise erase the destination the
     walker needs to rewrite after truncation. [ret_typ] is filled
     from the shared [typ ref] typing.ml wrote. *)
  | KRegion of kexpr * typ * string option

let counter = ref 0
let new_temp () = incr counter; Printf.sprintf "$t%d" !counter

(* Global counter for array storage IDs. Reset is optional; we use a fresh
   id for every array literal encountered, across all functions in the program. *)
let arr_counter = ref 0
let new_arr_id () = incr arr_counter; Printf.sprintf "arr%d" !arr_counter

(* Helper for coords *)
let str_of_coord p =
  match p with Abs f -> string_of_float f | Rel None -> "~" | Rel (Some f) -> "~" ^ string_of_float f | Local None -> "^" | Local (Some f) -> "^" ^ string_of_float f

(* Phase A: compile-time side-channel for TArrDyn-typed binders. Maps the
   user binder name (alpha-renamed) to the companion length vreg. The base
   handle is carried in an ordinary vreg sharing the binder's name, so all
   downstream passes (regalloc/inline/unroll/...) see the base as a plain
   int vreg. Disjoint from [arr_env] — TArrDyn bindings never touch it, so
   the static path is bit-identical on static-only programs. *)
let dyn_env : (string, string) Hashtbl.t = Hashtbl.create 16

(* Compile-time environment mapping user-level binder names to array storage IDs.
   Arrays are NOT first-class runtime values in Milestone 1: a `let a = [|..|]`
   binds `a` at compile time to a storage id like "arr3". Cleared at entry to
   `normalize` so each top-level function starts fresh. *)
let arr_env : (string, string) Hashtbl.t = Hashtbl.create 16

(* Dimension info for array-bound names. For a 1D array of length n we store
   (n, None); for a matrix of shape (rows, cols) we store (rows, Some cols).
   The column count is needed by Index2 to compute the flat index. *)
let arr_dims : (string, int * int option) Hashtbl.t = Hashtbl.create 16

(* Phase G: globals (top-level `val name = [| ... |]` array literals).
   Distinct from [arr_env] because globals persist across functions:
   they're populated once by the synthesized __globals_init.mcfunction
   at datapack load time, and every function that references a global
   val name reads from the same stable aid `__g_<name>`. [normalize]
   and [normalize_fun] CLEAR arr_env/arr_dims per function but re-seed
   from these tables so the lookup in the App / Index1 / Index2 arms
   finds globals alongside per-function locals. *)
let global_arr_env : (string, string) Hashtbl.t = Hashtbl.create 4
let global_arr_dims : (string, int * int option) Hashtbl.t = Hashtbl.create 4

(* Called by main.ml before Phase 1 starts, once per top-level val
   holding an array literal. Idempotent for the same (name, aid, len)
   triple. Rows-only for v1 (1D arrays). *)
let register_global_array (name : string) (aid : string) (length : int) : unit =
  Hashtbl.replace global_arr_env name aid;
  Hashtbl.replace global_arr_dims name (length, None)

let reseed_globals () : unit =
  Hashtbl.iter (fun n a -> Hashtbl.replace arr_env n a) global_arr_env;
  Hashtbl.iter (fun n d -> Hashtbl.replace arr_dims n d) global_arr_dims

(* Compile-time environment mapping user-level ref binder names to stable
   reserved slot names like "$ref_<alpha_name>". Persisted across top-level
   normalize calls so that a for-loop helper synthesized by for_lift can
   resolve refs defined in its enclosing function by the same stable slot
   name. Alpha-renaming guarantees names are globally unique. *)
let ref_env : (string, string) Hashtbl.t = Hashtbl.create 16

(* Is every element of this expression list a constant Int? *)
let rec all_ints (es : expr list) : int list option =
  match es with
  | [] -> Some []
  | Int k :: rest ->
      (match all_ints rest with
       | Some ks -> Some (k :: ks)
       | None -> None)
  | _ -> None

(* Normalize an expression, writing the result to 'dest' if provided *)
let rec normalize_to (dest : string option) (e : expr) : kexpr =
  match e with
  | Float f ->
      (* Phase N / N4: Q16.16 encoding. The literal x compiles to
         round(x * 65536) as an int. §12.2: Q16.16 range is
         [-32768, 32768), which after scaling fits exactly in int32.
         Compile-time reject out-of-range literals (silent clamp
         would hide a user error on a value they typed by hand). *)
      let scaled = Float.round (f *. 65536.0) in
      if scaled < -2147483648.0 || scaled > 2147483647.0 then
        failwith
          (Printf.sprintf
             "Phase N: float literal %g out of Q16.16 range \
              (representable range is approximately [-32768, 32768))"
             f);
      let i = int_of_float scaled in
      (match dest with Some d -> KLet(d, KInt i, KUnit) | None -> KUnit)
  | Int i ->
      (match dest with Some d -> KLet(d, KInt i, KUnit) | None -> KUnit)
      
  | Bool b -> 
      let i = if b then 1 else 0 in
      (match dest with Some d -> KLet(d, KInt i, KUnit) | None -> KUnit)

  | Var x ->
      (* Phase D stub: a bare nullary ctor (`Point`) parses as Var. *)
      if Typing.is_constructor x then
        failwith ("constructor " ^ x ^ ": lowering lands in D5");
      (match dest with Some d -> KLet(d, KVar x, KUnit) | None -> KUnit)

  | Str s | Selector s -> 
      (match dest with Some d -> KLet(d, KStr s, KUnit) | None -> KUnit)

  | Coord(x, y, z) -> 
      let s = Printf.sprintf "%s %s %s" (str_of_coord x) (str_of_coord y) (str_of_coord z) in
      (match dest with Some d -> KLet(d, KStr s, KUnit) | None -> KUnit)

  | Command c -> KCommand c (* Commands never return values *)

  | BinOp (op, e1, e2) ->
      let t1 = new_temp () in 
      let t2 = new_temp () in
      let op_instr = match dest with
        | Some d -> KLet(d, KBinOp(op, t1, t2), KUnit)
        | None -> KUnit 
      in
      normalize_to (Some t1) e1 |> fun k1 ->
      KLet(t1, KUnit, (* Dummy let to sequence k1 *)
        KSeq(k1, 
          normalize_to (Some t2) e2 |> fun k2 ->
          KSeq(k2, op_instr)
        )
      )

  | Unit ->
      (match dest with Some d -> KLet(d, KInt 0, KUnit) | None -> KUnit)

  | Let (x, App ("array_make", [n_expr; v_expr]), e2) ->
      (* Phase A dynamic-heap allocation.
         v1 scope: requires v_expr = Int 0 (non-zero init needs a runtime
         fill loop, deferred to a later session). *)
      (match v_expr with
       | Int 0 -> ()
       | _ -> failwith "array_make: v1 only supports initializer 0");
      let len_slot = "$dyn_len_" ^ x in
      Hashtbl.replace dyn_env x len_slot;
      let k_body = normalize_to dest e2 in
      (match n_expr with
       | Int k ->
           (* Const-n path: straight-line append in codegen. The length slot
              is still materialized as a vreg so downstream users (none in
              A4/A5, but future cross-function helpers) can read it. *)
           let alloc = KDynAllocConst(x, PoolScratch, k) in
           KLet(len_slot, KInt k, KSeq(alloc, k_body))
       | _ ->
           let t_n = new_temp () in
           let k_n = normalize_to (Some t_n) n_expr in
           let alloc = KDynAlloc(x, PoolScratch, t_n) in
           KLet(t_n, KUnit,
             KSeq(k_n,
               KLet(len_slot, KVar t_n,
                 KSeq(alloc, k_body)))))

  | Let (x, Ref e1, e2) ->
      (* Allocate a stable ref slot for x. The slot name uses the alpha-
         renamed binder so it is globally unique across the program. *)
      let slot = "$ref_" ^ x in
      Hashtbl.replace ref_env x slot;
      let k1 = normalize_to (Some slot) e1 in
      let k2 = normalize_to dest e2 in
      KSeq(k1, k2)

  | Ref _ ->
      failwith "ref literal must be bound with let: let r = ref e in ..."

  | Deref (Var r) ->
      let slot =
        try Hashtbl.find ref_env r
        with Not_found -> failwith ("!" ^ r ^ ": not a ref-bound variable")
      in
      (match dest with
       | Some d -> KLet(d, KVar slot, KUnit)
       | None -> KUnit)

  | Deref _ -> failwith "!: operand must be a ref-bound variable"

  | RefSet (Var r, v) ->
      let slot =
        try Hashtbl.find ref_env r
        with Not_found -> failwith (r ^ " := ...: not a ref-bound variable")
      in
      (* Compute v into the slot. Ignore ambient dest — RefSet is unit. *)
      normalize_to (Some slot) v

  | RefSet _ -> failwith ":= : lhs must be a ref-bound variable"

  | For _ ->
      failwith "for: must be lifted by for_lift before knormal"

  | Let (x, Array elems, e2) ->
      (* Array-literal-bound-to-name: `let x = [| .. |] in e2`.
         x becomes a compile-time alias for a fresh storage id. No runtime
         scoreboard slot is allocated for x. *)
      let id = new_arr_id () in
      (* Detect matrix literal shape: outer Array of inner Arrays.
         Flatten row-major. 3D+ is unsupported. *)
      let is_matrix =
        match elems with
        | Array _ :: _ -> true
        | _ -> false
      in
      let init_kexpr =
        if is_matrix then begin
          (* Matrix literal: each element of `elems` must itself be Array _. *)
          let rows =
            List.map
              (fun row -> match row with
                 | Array row_elems ->
                     (* Reject 3D+: row elements must not themselves be Array. *)
                     List.iter
                       (fun el -> match el with
                          | Array _ ->
                              failwith "nested arrays beyond 2D not supported"
                          | _ -> ())
                       row_elems;
                     row_elems
                 | _ ->
                     (* Mixed matrix/array rows: fall back to treating as 1D
                        by wrapping — but the plan says outer being Array of
                        Arrays is the matrix signal. If a non-Array sneaks in,
                        that's a type error upstream. *)
                     failwith "matrix literal: all rows must be array literals")
              elems
          in
          let n_rows = List.length rows in
          let n_cols = match rows with [] -> 0 | r :: _ -> List.length r in
          Hashtbl.replace arr_dims x (n_rows, Some n_cols);
          let flat = List.concat rows in
          (match all_ints flat with
           | Some ks -> KArrLitConst(id, ks)
           | None ->
               (* Normalize each element to a fresh temp and chain them. *)
               let temps = List.map (fun _ -> new_temp ()) flat in
               let lit = KArrLitDyn(id, temps) in
               List.fold_right2
                 (fun el t acc ->
                    let k_el = normalize_to (Some t) el in
                    KSeq(k_el, acc))
                 flat temps lit)
        end else begin
          let n = List.length elems in
          Hashtbl.replace arr_dims x (n, None);
          (match all_ints elems with
           | Some ks -> KArrLitConst(id, ks)
           | None ->
               let temps = List.map (fun _ -> new_temp ()) elems in
               let lit = KArrLitDyn(id, temps) in
               List.fold_right2
                 (fun el t acc ->
                    let k_el = normalize_to (Some t) el in
                    KSeq(k_el, acc))
                 elems temps lit)
        end
      in
      Hashtbl.replace arr_env x id;
      let k_body = normalize_to dest e2 in
      (* Wrap init as a statement via a dummy KLet like the BinOp pattern. *)
      KLet(id, KUnit, KSeq(init_kexpr, k_body))

  | Let (x, e1, e2) ->
      (* 1. Compute e1 and write to x *)
      let k1 = normalize_to (Some x) e1 in
      (* 2. Compute e2 (writing to original dest) *)
      let k2 = normalize_to dest e2 in
      KSeq(k1, k2)

  | If (cond, e1, e2) ->
      let t = new_temp () in
      let k_cond = normalize_to (Some t) cond in
      (* Push 'dest' into the branches! *)
      let k_then = normalize_to dest e1 in
      let k_else = normalize_to dest e2 in
      KSeq(k_cond, KIf(t, k_then, k_else))

  | Seq (e1, e2) ->
      KSeq(normalize_to None e1, normalize_to dest e2)

  | Array _ ->
      (* Bare array literal used as an expression (not `let x = [|..|]`).
         Not supported in Milestone 1 — arrays aren't first-class. *)
      failwith "bare array literal must be bound with let"

  | Index1 (base, idx) ->
      let name = match base with
        | Var n -> n
        | _ -> failwith "Index1: base must be an array-bound variable"
      in
      let id =
        try Hashtbl.find arr_env name
        with Not_found ->
          failwith ("Index1: base must be an array-bound variable: " ^ name)
      in
      (match dest with
       | None ->
           (* Pure read with discarded result — no-op. *)
           KUnit
       | Some d ->
           (match idx with
            | Int k -> KLet(d, KUnit, KArrGetStatic(d, id, k))
            | _ ->
                let t_idx = new_temp () in
                let k_idx = normalize_to (Some t_idx) idx in
                KLet(t_idx, KUnit,
                  KSeq(k_idx, KLet(d, KUnit, KArrGet(d, id, t_idx))))))

  | Index2 (base, i, j) ->
      let name = match base with
        | Var n -> n
        | _ -> failwith "Index2: base must be an array-bound variable"
      in
      let id =
        try Hashtbl.find arr_env name
        with Not_found ->
          failwith ("Index2: base must be an array-bound variable: " ^ name)
      in
      let cols =
        match Hashtbl.find_opt arr_dims name with
        | Some (_, Some c) -> c
        | _ -> failwith ("Index2: " ^ name ^ " is not a matrix")
      in
      (match dest with
       | None -> KUnit
       | Some d ->
           (match i, j with
            | Int ki, Int kj ->
                let flat = ki * cols + kj in
                KLet(d, KUnit, KArrGetStatic(d, id, flat))
            | _ ->
                (* Normalize i and j to temps, then compute flat = i*cols + j. *)
                let t_i = new_temp () in
                let t_j = new_temp () in
                let t_cols = new_temp () in
                let t_mul = new_temp () in
                let t_flat = new_temp () in
                let k_i = normalize_to (Some t_i) i in
                let k_j = normalize_to (Some t_j) j in
                KLet(t_i, KUnit,
                  KSeq(k_i,
                    KLet(t_j, KUnit,
                      KSeq(k_j,
                        KLet(t_cols, KInt cols,
                          KLet(t_mul, KBinOp(Mult, t_i, t_cols),
                            KLet(t_flat, KBinOp(Add, t_mul, t_j),
                              KLet(d, KUnit, KArrGet(d, id, t_flat)))))))))))

  | IndexSet1 (base, idx, v) ->
      let name = match base with
        | Var n -> n
        | _ -> failwith "IndexSet1: base must be an array-bound variable"
      in
      let id =
        try Hashtbl.find arr_env name
        with Not_found ->
          failwith ("IndexSet1: base must be an array-bound variable: " ^ name)
      in
      (* IndexSet is unit-typed; ambient dest is ignored for the write,
         but if a dest is provided we still bind it to unit (=0). *)
      let assign =
        match idx with
        | Int k ->
            let tv = new_temp () in
            let kv = normalize_to (Some tv) v in
            KLet(tv, KUnit, KSeq(kv, KArrSetStatic(id, k, tv)))
        | _ ->
            let t_idx = new_temp () in
            let tv = new_temp () in
            let k_idx = normalize_to (Some t_idx) idx in
            let kv = normalize_to (Some tv) v in
            KLet(t_idx, KUnit,
              KSeq(k_idx,
                KLet(tv, KUnit,
                  KSeq(kv, KArrSet(id, t_idx, tv)))))
      in
      (match dest with
       | None -> assign
       | Some d -> KSeq(assign, KLet(d, KInt 0, KUnit)))

  | IndexSet2 (base, i, j, v) ->
      let name = match base with
        | Var n -> n
        | _ -> failwith "IndexSet2: base must be an array-bound variable"
      in
      let id =
        try Hashtbl.find arr_env name
        with Not_found ->
          failwith ("IndexSet2: base must be an array-bound variable: " ^ name)
      in
      let cols =
        match Hashtbl.find_opt arr_dims name with
        | Some (_, Some c) -> c
        | _ -> failwith ("IndexSet2: " ^ name ^ " is not a matrix")
      in
      let assign =
        match i, j with
        | Int ki, Int kj ->
            let flat = ki * cols + kj in
            let tv = new_temp () in
            let kv = normalize_to (Some tv) v in
            KLet(tv, KUnit, KSeq(kv, KArrSetStatic(id, flat, tv)))
        | _ ->
            let t_i = new_temp () in
            let t_j = new_temp () in
            let t_cols = new_temp () in
            let t_mul = new_temp () in
            let t_flat = new_temp () in
            let tv = new_temp () in
            let k_i = normalize_to (Some t_i) i in
            let k_j = normalize_to (Some t_j) j in
            let kv = normalize_to (Some tv) v in
            KLet(t_i, KUnit,
              KSeq(k_i,
                KLet(t_j, KUnit,
                  KSeq(k_j,
                    KLet(t_cols, KInt cols,
                      KLet(t_mul, KBinOp(Mult, t_i, t_cols),
                        KLet(t_flat, KBinOp(Add, t_mul, t_j),
                          KLet(tv, KUnit,
                            KSeq(kv, KArrSet(id, t_flat, tv))))))))))
      in
      (match dest with
       | None -> assign
       | Some d -> KSeq(assign, KLet(d, KInt 0, KUnit)))

  | App ("array_get", [Var a; i_expr]) when Hashtbl.mem dyn_env a ->
      (* Phase A dyn-array read. Base handle lives in the vreg named [a];
         length slot exists in dyn_env but isn't needed for the read. *)
      (match dest with
       | None -> KUnit
       | Some d ->
           let t_i = new_temp () in
           let k_i = normalize_to (Some t_i) i_expr in
           KLet(t_i, KUnit,
             KSeq(k_i,
               KLet(d, KUnit, KHeapGet(d, PoolScratch, a, t_i)))))

  | App ("array_set", [Var a; i_expr; v_expr]) when Hashtbl.mem dyn_env a ->
      (* Phase A dyn-array write. Unit-typed, side-effecting. *)
      let t_i = new_temp () in
      let t_v = new_temp () in
      let k_i = normalize_to (Some t_i) i_expr in
      let k_v = normalize_to (Some t_v) v_expr in
      let assign =
        KLet(t_i, KUnit,
          KSeq(k_i,
            KLet(t_v, KUnit,
              KSeq(k_v, KHeapSet(PoolScratch, a, t_i, t_v)))))
      in
      (match dest with
       | None -> assign
       | Some d -> KSeq(assign, KLet(d, KInt 0, KUnit)))

  | App ("array_make", _) ->
      failwith "array_make must appear as the rhs of a let binding"

  | Match _ ->
      (* Phase D stub, same convention as B4/C1: the frontend (D1–D3)
         accepts and types `match`, but decision-tree lowering is D5.
         Fail fast rather than silently miscompiling. *)
      failwith "Match: lowering lands in D5"

  | Region (tr, body) ->
      (* Phase C / C3+C5. Normalize the body with the same [dest] so
         the body's final value still lands in [d]. For primitive
         returns the scoreboard write survives NBT truncation directly.
         For TList TInt returns the deep-copy walker in codegen_cfg
         reads [d] as the child-region root handle and overwrites it
         with the new parent-region handle before truncation fires.
         The return type is read from the [tr] ref that typing.ml
         wrote into during its infer pass on this function's body.
         [dest] is captured on the KRegion constructor so cfg_build's
         lowering can emit IRegionExit with the right destination
         even when an enclosing KSeq passes [~dest:None]. *)
      KRegion (normalize_to dest body, !tr, dest)

  | Nil ->
      (* Empty list sentinel: -1, per §4.2. *)
      (match dest with
       | None -> KUnit
       | Some d -> KLet(d, KInt (-1), KUnit))

  | Cons (h, t) ->
      (* Evaluate both operands into temps regardless of dest, mirroring
         the BinOp pattern — if dest is None we still evaluate sub-
         expressions (for any nested side effects) and drop the cons
         allocation itself (pure expression; regions reclaim). *)
      let t_h = new_temp () in
      let t_t = new_temp () in
      let k_h = normalize_to (Some t_h) h in
      let k_t = normalize_to (Some t_t) t in
      (match dest with
       | None ->
           KLet(t_h, KUnit,
             KSeq(k_h,
               KLet(t_t, KUnit, k_t)))
       | Some d ->
           KLet(t_h, KUnit,
             KSeq(k_h,
               KLet(t_t, KUnit,
                 KSeq(k_t,
                   KLet(d, KUnit, KCons(d, t_h, t_t)))))))

  | App ("head", [arg]) ->
      let t_l = new_temp () in
      let k_l = normalize_to (Some t_l) arg in
      (match dest with
       | None -> KLet(t_l, KUnit, k_l)
       | Some d ->
           KLet(t_l, KUnit,
             KSeq(k_l,
               KLet(d, KUnit, KHead(d, t_l)))))

  | App ("tail", [arg]) ->
      let t_l = new_temp () in
      let k_l = normalize_to (Some t_l) arg in
      (match dest with
       | None -> KLet(t_l, KUnit, k_l)
       | Some d ->
           KLet(t_l, KUnit,
             KSeq(k_l,
               KLet(d, KUnit, KTail(d, t_l)))))

  (* Phase N / N5: Q16.16 builtins. fmul/fdiv normalize both operands
     to temps and emit KBinOp with the dedicated FMult/FDiv variants.
     neg_f desugars to `0 - a` using a fresh zero temp. *)
  | App ("fmul", [a; b]) ->
      let t1 = new_temp () in
      let t2 = new_temp () in
      let k1 = normalize_to (Some t1) a in
      let k2 = normalize_to (Some t2) b in
      let op_instr = match dest with
        | Some d -> KLet(d, KBinOp(FMult, t1, t2), KUnit)
        | None -> KUnit in
      KLet(t1, KUnit,
        KSeq(k1,
          KLet(t2, KUnit,
            KSeq(k2, op_instr))))
  | App ("fdiv", [a; b]) ->
      let t1 = new_temp () in
      let t2 = new_temp () in
      let k1 = normalize_to (Some t1) a in
      let k2 = normalize_to (Some t2) b in
      let op_instr = match dest with
        | Some d -> KLet(d, KBinOp(FDiv, t1, t2), KUnit)
        | None -> KUnit in
      KLet(t1, KUnit,
        KSeq(k1,
          KLet(t2, KUnit,
            KSeq(k2, op_instr))))
  | App ("neg_f", [a]) ->
      let t_zero = new_temp () in
      let t_a = new_temp () in
      let k_a = normalize_to (Some t_a) a in
      let op_instr = match dest with
        | Some d -> KLet(d, KBinOp(Sub, t_zero, t_a), KUnit)
        | None -> KUnit in
      KLet(t_zero, KInt 0,
        KLet(t_a, KUnit,
          KSeq(k_a, op_instr)))

  (* Phase N / N11: int<->float conversions. to_float(a) = a * 65536;
     to_int(a) = a / 65536 (truncates fractional part). Both lower to
     a regular int IBinOp against a fresh $c65536 temp; codegen uses
     the existing Mult/Div helpers so no new lowering. Constraint:
     to_float(a) overflows int32 for |a| >= 32768 — caller's
     responsibility since we don't emit a runtime check. *)
  | App ("to_float", [a]) ->
      let t_a = new_temp () in
      let t_scale = new_temp () in
      let k_a = normalize_to (Some t_a) a in
      let op_instr = match dest with
        | Some d -> KLet(d, KBinOp(Mult, t_a, t_scale), KUnit)
        | None -> KUnit in
      KLet(t_a, KUnit,
        KSeq(k_a,
          KLet(t_scale, KInt 65536, op_instr)))
  | App ("to_int", [a]) ->
      let t_a = new_temp () in
      let t_scale = new_temp () in
      let k_a = normalize_to (Some t_a) a in
      let op_instr = match dest with
        | Some d -> KLet(d, KBinOp(Div, t_a, t_scale), KUnit)
        | None -> KUnit in
      KLet(t_a, KUnit,
        KSeq(k_a,
          KLet(t_scale, KInt 65536, op_instr)))

  (* Phase N §12.1 + Phase Math: identity bit-reinterpretation. Both
     directions lower to the same code as the inner expression — the
     coercion is purely in typing. No codegen changes needed. *)
  | App ("raw_of_float", [a]) | App ("float_of_raw", [a]) ->
      normalize_to dest a

  | App ("is_nil", [arg]) ->
      (* Desugar to equality against the -1 sentinel. KBinOp Eq already
         lowers to the standard boolean-as-int compile. *)
      let t_l = new_temp () in
      let k_l = normalize_to (Some t_l) arg in
      (match dest with
       | None -> KLet(t_l, KUnit, k_l)
       | Some d ->
           let t_neg = new_temp () in
           KLet(t_l, KUnit,
             KSeq(k_l,
               KLet(t_neg, KInt (-1),
                 KLet(d, KBinOp(Eq, t_l, t_neg), KUnit)))))

  | App (f, args) ->
      (* Phase D stub: constructor application parses as App. Without
         this a well-typed ctor-but-no-match program would silently
         emit a KCall to a nonexistent function. *)
      if Typing.is_constructor f then
        failwith ("constructor " ^ f ^ ": lowering lands in D5");
      let rec bind_args args acc = match args with
        | [] ->
            let call = KCall(f, List.rev acc) in
            (match dest with
             | Some d -> KSeq(call, KLet(d, KVar "$ret", KUnit))
             | None -> call)
        | Var name :: t when Hashtbl.mem arr_env name ->
            (* Passing an array-bound name to a function: emit a pseudo
               "#arr:<aid>" token instead of a runtime vreg. Monomorphize
               consumes these and rewrites the call to a specialized clone. *)
            let aid = Hashtbl.find arr_env name in
            let pseudo = "#arr:" ^ aid in
            bind_args t (pseudo :: acc)
        | h :: t ->
            let tmp = new_temp () in
            KSeq(normalize_to (Some tmp) h, bind_args t (tmp :: acc))
      in
      bind_args args []

let normalize e =
  Hashtbl.clear arr_env;
  Hashtbl.clear arr_dims;
  Hashtbl.clear dyn_env;
  (* Phase G: seed globals after clearing so per-function locals still
     have a fresh slate but global val names resolve. *)
  reseed_globals ();
  (* ref_env is NOT cleared — ref slot bindings persist across definitions
     so that for-loop helpers can see refs defined in their enclosing
     function. Alpha-renaming keeps binder names globally unique. *)
  normalize_to (Some "$ret") e

(* Variant used when lowering a function body whose parameters may include
   array or ref types. Seeds arr_env/arr_dims/ref_env with sentinel storage
   IDs for array params (replaced at monomorphization time) and stable
   ref slot names for ref params. *)
let normalize_fun (params : (string * Ast.typ) list) (body : expr) : kexpr =
  Hashtbl.clear arr_env;
  Hashtbl.clear arr_dims;
  Hashtbl.clear dyn_env;
  (* Phase G: seed globals so `fun f () = global_lut[i]` resolves. *)
  reseed_globals ();
  List.iteri (fun i (name, ty) ->
    match ty with
    | TArrStatic (_, n) ->
        let sentinel = Printf.sprintf "#param%d" i in
        Hashtbl.replace arr_env name sentinel;
        Hashtbl.replace arr_dims name (n, None)
    | TMat (_, rows, cols) ->
        let sentinel = Printf.sprintf "#param%d" i in
        Hashtbl.replace arr_env name sentinel;
        Hashtbl.replace arr_dims name (rows, Some cols)
    | TArrDyn _ ->
        (* Phase A deferred follow-up: the handle itself is a scalar
           int that cfg_build lowers with a normal `ICopy(name,
           param_i)` prelude (the `_` arm in [of_kexpr]); the only
           extra state knormal needs is a [dyn_env] entry so
           [array_get]/[array_set] inside this body route to
           KHeapGet/KHeapSet instead of failing the fallthrough. The
           length slot is unused for per-op lowering in v1 — no
           length() primitive yet — but we still mint a stable name
           so any future consumer (bounds check, for-loop upper
           bound) has something to look up. *)
        let _ = i in
        Hashtbl.replace dyn_env name ("$dyn_len_param_" ^ name)
    | _ -> ()
  ) params;
  normalize_to (Some "$ret") body