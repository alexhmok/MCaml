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
  (* --- Phase D ADT primitives (D5) --- *)
  (* KAdtAlloc(d, tag, fields) — d := handle of a fresh objpool cell
     {tag: <tag>, f0: fields[0], f1: fields[1], ...}. The tag is a
     codegen-time constant (D3 decl-order ctor index), so it rides
     inside the append literal — 3 + <#fields> commands, no separate
     tag write (the D4 ICons precedent). Nullary ctors allocate a
     bare {tag: k} cell uniformly (§13.5): 3 cmds per mention, and
     tag reads stay uniform across every ctor of every type. *)
  | KAdtAlloc of string * int * string list
  (* KTagGet(d, c) — d := objpool cells[c].tag, via the obj_tag macro
     getter (3 cmds, hidden $arr_result write like IArrGet). *)
  | KTagGet of string * string
  (* KFieldGet(d, c, k) — d := objpool cells[c].f<k>, via the per-index
     obj_f<k> macro getter (3 cmds, hidden $arr_result write). *)
  | KFieldGet of string * string * int

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

  | Var x when Typing.is_constructor x ->
      (* Phase D / D5: a bare nullary ctor (`Point`) parses as Var.
         Allocate-uniformly (§13.5): a bare {tag: k} cell, 3 cmds.
         Typing already rejected bare mentions of non-nullary ctors,
         but check defensively — a silent zero-field cell for `Circle`
         would corrupt every downstream field read. *)
      let (_, fields, tag) = Hashtbl.find Typing.ctor_info x in
      if fields <> [] then
        failwith ("constructor " ^ x ^ " expects arguments (knormal)");
      (match dest with
       | Some d -> KLet(d, KUnit, KAdtAlloc(d, tag, []))
       | None -> KUnit)

  | Var x ->
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

  | Match (scrut, arms) ->
      (* Phase D / D5: decision-tree pattern compilation (Maranget).
         The scrutinee handle is normalized into one temp, and each
         occurrence's tag/field is read at most ONCE per decision-tree
         path (never once per arm) — see [compile_match]. Typing (D3)
         already proved every match exhaustive and irredundant, so the
         tree needs no failure leaf: on a complete ctor column the
         LAST ctor's subtree becomes the untested else-branch
         (defensive fallthrough — a tag outside the tested set is
         impossible by construction, and eliding the final test saves
         two commands per match vs. a trap arm). *)
      let t_s = new_temp () in
      let k_s = normalize_to (Some t_s) scrut in
      let rows = List.map (fun (p, body) -> ([p], [], body)) arms in
      KLet (t_s, KUnit, KSeq (k_s, compile_match dest [t_s] rows))

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

  | Tuple es ->
      (* D7: a tuple is a single-ctor ADT cell {tag:0, f0...} — same
         allocation as a ctor application, with the fixed tag 0 (the
         tag is never read: tuple matches dispatch on the complete
         single-ctor signature with zero tag tests). With no ambient
         dest the allocation is dropped but element sub-expressions
         still evaluate (Cons/ctor precedent). *)
      let temps = List.map (fun _ -> new_temp ()) es in
      let ks = List.map2 (fun a t -> normalize_to (Some t) a) es temps in
      let seq body = List.fold_right (fun k acc -> KSeq (k, acc)) ks body in
      (match dest with
       | None -> seq KUnit
       | Some d -> seq (KLet (d, KUnit, KAdtAlloc (d, 0, temps))))

  | Record fields ->
      (* D8: same {tag:0, f0...} cell as a tuple. Fields evaluate in
         SOURCE order (the literal's order), then the allocation takes
         the temps in DECL order so f<k> always means decl field k. *)
      let owner =
        match fields with
        | (f0, _) :: _ ->
            let (o, _, _) = Hashtbl.find Typing.record_fields f0 in o
        | [] -> failwith "knormal: empty record literal survived typing"
      in
      let decl = Hashtbl.find Typing.record_decls owner in
      let with_temps = List.map (fun (f, e) -> (f, new_temp (), e)) fields in
      let ks =
        List.map (fun (_, t, e) -> normalize_to (Some t) e) with_temps in
      let seq body = List.fold_right (fun k acc -> KSeq (k, acc)) ks body in
      let ordered =
        List.map (fun (f, _) ->
          let (_, t, _) =
            List.find (fun (f', _, _) -> f' = f) with_temps in
          t) decl
      in
      (match dest with
       | None -> seq KUnit
       | Some d -> seq (KLet (d, KUnit, KAdtAlloc (d, 0, ordered))))

  | Field (e, f) ->
      (* D8: r.x — single-field read through the obj_f<k> macro getter
         (3 cmds), mirroring the head/tail arms. With no ambient dest
         the read is skipped (KFieldGet is never DCE'd, so emitting it
         would cost 3 dead commands). *)
      let (_, idx, _) = Hashtbl.find Typing.record_fields f in
      let t_r = new_temp () in
      let k_r = normalize_to (Some t_r) e in
      (match dest with
       | None -> KLet (t_r, KUnit, k_r)
       | Some d ->
           KLet (t_r, KUnit,
             KSeq (k_r,
               KLet (d, KUnit, KFieldGet (d, t_r, idx)))))

  | App (f, args) when Typing.is_constructor f ->
      (* Phase D / D5: constructor application. Normalize every field
         into a temp, then allocate one tagged objpool cell. With no
         ambient dest the allocation is dropped (pure expression;
         regions reclaim) but field sub-expressions still evaluate,
         mirroring the Cons arm. *)
      let (_, _, tag) = Hashtbl.find Typing.ctor_info f in
      let temps = List.map (fun _ -> new_temp ()) args in
      let ks = List.map2 (fun a t -> normalize_to (Some t) a) args temps in
      let seq body = List.fold_right (fun k acc -> KSeq (k, acc)) ks body in
      (match dest with
       | None -> seq KUnit
       | Some d -> seq (KLet (d, KUnit, KAdtAlloc (d, tag, temps))))

  | App (f, args) ->
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

(* ---- Phase D / D5: pattern-matrix compilation (Maranget) ----------

   A row is (patterns, bindings, body): [patterns] is aligned
   position-for-position with the [occs] occurrence-vreg list,
   [bindings] accumulates (binder, occ_vreg) pairs discharged when a
   PVar is consumed by specialization, and [body] is the arm's source
   expression, normalized only at the leaf.

   Invariants inherited from typing (D3, full Maranget usefulness):
   the matrix is exhaustive and irredundant. Consequences used here:
   - the matrix is never empty at a leaf ([] is a hard internal error);
   - an int column always has an irrefutable default row;
   - on a complete ctor column the default matrix may be empty (all
     rows refutable) — the last ctor's subtree is the else-branch.

   Wildcard/var rows are duplicated into every specialization (standard
   decision-tree behavior), so an arm body can be normalized more than
   once. Each normalization mints fresh temps, and duplicated paths are
   mutually exclusive at runtime, so this is a code-size cost only.

   Tag dispatch emits [t_tag == <k>] as an IConst + IBinOp Eq feeding
   KIf — scoreboard-only, one storage read per occurrence via KTagGet.
   The 1-cmd [execute if score ... matches <k>] form is the same
   future peephole B7 documented for is_nil. *)
and compile_match (dest : string option) (occs : string list)
    (rows : (Ast.pattern list * (string * string) list * Ast.expr) list)
    : kexpr =
  let is_irrefutable = function
    | Ast.PWild | Ast.PVar _ -> true
    (* PTuple is "refutable" for column-selection purposes even though
       the tuple ctor always matches — selecting the column unfolds the
       components (and discharges their binders) without emitting any
       test. *)
    | Ast.PInt _ | Ast.PCtor _ | Ast.PNil | Ast.PCons _
    | Ast.PTuple _ | Ast.PRecord _ -> false
  in
  match rows with
  | [] ->
      failwith
        "match lowering: empty pattern matrix — typing exhaustiveness \
         invariant broken"
  | (ps, binds, body) :: _ when List.for_all is_irrefutable ps ->
      (* First row matches unconditionally: discharge its binders
         against the occurrence vregs and emit the arm body. *)
      let binds =
        List.fold_left2
          (fun acc p o ->
             match p with Ast.PVar x -> (x, o) :: acc | _ -> acc)
          binds ps occs
      in
      let k_body = normalize_to dest body in
      List.fold_left
        (fun acc (x, o) -> KSeq (KLet (x, KVar o, KUnit), acc))
        k_body binds
  | (first_ps, _, _) :: _ ->
      (* Pick the leftmost column where the first row is refutable —
         guarantees progress (the first row is not all-irrefutable). *)
      let col =
        let rec find i = function
          | [] ->
              failwith "match lowering: no refutable column (unreachable)"
          | p :: rest -> if is_irrefutable p then find (i + 1) rest else i
        in
        find 0 first_ps
      in
      let occ = List.nth occs col in
      let occs_rest = List.filteri (fun i _ -> i <> col) occs in
      let split_row (ps, binds, body) =
        (List.nth ps col, List.filteri (fun i _ -> i <> col) ps, binds, body)
      in
      (* Default matrix: rows whose column pattern is irrefutable. *)
      let default_rows =
        List.filter_map
          (fun row ->
             let (p, rest, binds, body) = split_row row in
             match p with
             | Ast.PWild -> Some (rest, binds, body)
             | Ast.PVar x -> Some (rest, (x, occ) :: binds, body)
             | _ -> None)
          rows
      in
      let first_refutable =
        let (p, _, _, _) =
          split_row
            (List.find (fun r -> let (p, _, _, _) = split_row r in
                                  not (is_irrefutable p)) rows)
        in p
      in
      (match first_refutable with
       | Ast.PInt _ ->
           (* Int column: compare the occurrence against each literal.
              Ints never complete their signature, so exhaustiveness
              guarantees a default row exists. *)
           let lits =
             List.fold_left
               (fun acc row ->
                  let (p, _, _, _) = split_row row in
                  match p with
                  | Ast.PInt k when not (List.mem k acc) -> acc @ [k]
                  | _ -> acc)
               [] rows
           in
           let specialize_int k =
             List.filter_map
               (fun row ->
                  let (p, rest, binds, body) = split_row row in
                  match p with
                  | Ast.PInt i when i = k -> Some (rest, binds, body)
                  | Ast.PWild -> Some (rest, binds, body)
                  | Ast.PVar x -> Some (rest, (x, occ) :: binds, body)
                  | _ -> None)
               rows
           in
           if default_rows = [] then
             failwith
               "match lowering: int column without a default row — \
                typing exhaustiveness invariant broken";
           let else_k = compile_match dest occs_rest default_rows in
           List.fold_right
             (fun lit acc ->
                let t_c = new_temp () in
                let t_b = new_temp () in
                KLet (t_c, KInt lit,
                  KLet (t_b, KBinOp (Ast.Eq, occ, t_c),
                    KIf (t_b,
                         compile_match dest occs_rest (specialize_int lit),
                         acc))))
             lits else_k
       | Ast.PCtor (c0, _) ->
           (* ADT column: read the tag ONCE, then an Eq-chain over the
              ctors present. Complete signature → last ctor's subtree
              is the untested else-branch (defensive fallthrough). *)
           let heads =
             List.fold_left
               (fun acc row ->
                  let (p, _, _, _) = split_row row in
                  match p with
                  | Ast.PCtor (c, _) when not (List.mem c acc) -> acc @ [c]
                  | _ -> acc)
               [] rows
           in
           let (owner, _, _) = Hashtbl.find Typing.ctor_info c0 in
           let all_ctors = Hashtbl.find Typing.adt_decls owner in
           let complete =
             List.for_all (fun (cn, _) -> List.mem cn heads) all_ctors
           in
           let branch_for c =
             let (_, fields, _) = Hashtbl.find Typing.ctor_info c in
             let ar = List.length fields in
             let f_temps = List.init ar (fun _ -> new_temp ()) in
             let spec_rows =
               List.filter_map
                 (fun row ->
                    let (p, rest, binds, body) = split_row row in
                    match p with
                    | Ast.PCtor (c', subs) when c' = c ->
                        Some (subs @ rest, binds, body)
                    | Ast.PWild ->
                        Some (List.init ar (fun _ -> Ast.PWild) @ rest,
                              binds, body)
                    | Ast.PVar x ->
                        Some (List.init ar (fun _ -> Ast.PWild) @ rest,
                              (x, occ) :: binds, body)
                    | _ -> None)
                 rows
             in
             (* Read only the fields some sub-pattern inspects or binds
                — IFieldGet is never DCE'd (hidden $arr_result write),
                so an unused read would cost 3 dead commands. *)
             let used = Array.make (max ar 1) false in
             List.iter
               (fun (ps, _, _) ->
                  List.iteri
                    (fun i p ->
                       if i < ar && p <> Ast.PWild then used.(i) <- true)
                    ps)
               spec_rows;
             let sub = compile_match dest (f_temps @ occs_rest) spec_rows in
             let rec add_reads i acc =
               if i < 0 then acc
               else
                 add_reads (i - 1)
                   (if used.(i)
                    then KSeq (KFieldGet (List.nth f_temps i, occ, i), acc)
                    else acc)
             in
             add_reads (ar - 1) sub
           in
           let tests, else_k =
             if complete then
               match List.rev heads with
               | last :: rev_init -> (List.rev rev_init, branch_for last)
               | [] -> assert false
             else begin
               if default_rows = [] then
                 failwith
                   "match lowering: incomplete ctor column without a \
                    default row — typing exhaustiveness invariant broken";
               (heads, compile_match dest occs_rest default_rows)
             end
           in
           if tests = [] then
             (* Single-ctor complete signature: no tag read needed. *)
             else_k
           else begin
             let t_tag = new_temp () in
             let chain =
               List.fold_right
                 (fun c acc ->
                    let (_, _, tag) = Hashtbl.find Typing.ctor_info c in
                    let t_c = new_temp () in
                    let t_b = new_temp () in
                    KLet (t_c, KInt tag,
                      KLet (t_b, KBinOp (Ast.Eq, t_tag, t_c),
                        KIf (t_b, branch_for c, acc))))
                 tests else_k
             in
             KLet (t_tag, KUnit, KSeq (KTagGet (t_tag, occ), chain))
           end
       | Ast.PTuple ps0 ->
           (* D7: tuple column — an always-complete single-ctor
              signature, so NO test is emitted (the D5 single-ctor rule
              with zero tag reads). Components unfold in place; the
              used-fields filter keeps `_` components from emitting an
              obj_f<k> read. *)
           let ar = List.length ps0 in
           let f_temps = List.init ar (fun _ -> new_temp ()) in
           let spec_rows =
             List.filter_map
               (fun row ->
                  let (p, rest, binds, body) = split_row row in
                  match p with
                  | Ast.PTuple subs -> Some (subs @ rest, binds, body)
                  | Ast.PWild ->
                      Some (List.init ar (fun _ -> Ast.PWild) @ rest,
                            binds, body)
                  | Ast.PVar x ->
                      Some (List.init ar (fun _ -> Ast.PWild) @ rest,
                            (x, occ) :: binds, body)
                  | _ -> None)
               rows
           in
           let used = Array.make (max ar 1) false in
           List.iter
             (fun (ps, _, _) ->
                List.iteri
                  (fun i p ->
                     if i < ar && p <> Ast.PWild then used.(i) <- true)
                  ps)
             spec_rows;
           let sub = compile_match dest (f_temps @ occs_rest) spec_rows in
           let rec add_reads i acc =
             if i < 0 then acc
             else
               add_reads (i - 1)
                 (if used.(i)
                  then KSeq (KFieldGet (List.nth f_temps i, occ, i), acc)
                  else acc)
           in
           add_reads (ar - 1) sub
       | Ast.PRecord fields0 ->
           (* D8: record column. Rows normalize to decl-order sub-
              pattern vectors (missing fields = PWild), after which
              this is exactly the tuple case: always-complete single-
              ctor signature, no test, used-fields filter (an omitted
              or `_` field emits NO obj_f<k> read). *)
           let owner =
             match fields0 with
             | (f0, _) :: _ ->
                 let (o, _, _) = Hashtbl.find Typing.record_fields f0 in
                 o
             | [] ->
                 failwith
                   "match lowering: empty record pattern survived typing"
           in
           let decl = Hashtbl.find Typing.record_decls owner in
           let ar = List.length decl in
           let to_vec fields =
             List.map (fun (f, _) ->
               match List.assoc_opt f fields with
               | Some p -> p
               | None -> Ast.PWild) decl
           in
           let f_temps = List.init ar (fun _ -> new_temp ()) in
           let spec_rows =
             List.filter_map
               (fun row ->
                  let (p, rest, binds, body) = split_row row in
                  match p with
                  | Ast.PRecord fields ->
                      Some (to_vec fields @ rest, binds, body)
                  | Ast.PWild ->
                      Some (List.init ar (fun _ -> Ast.PWild) @ rest,
                            binds, body)
                  | Ast.PVar x ->
                      Some (List.init ar (fun _ -> Ast.PWild) @ rest,
                            (x, occ) :: binds, body)
                  | _ -> None)
               rows
           in
           let used = Array.make (max ar 1) false in
           List.iter
             (fun (ps, _, _) ->
                List.iteri
                  (fun i p ->
                     if i < ar && p <> Ast.PWild then used.(i) <- true)
                  ps)
             spec_rows;
           let sub = compile_match dest (f_temps @ occs_rest) spec_rows in
           let rec add_reads i acc =
             if i < 0 then acc
             else
               add_reads (i - 1)
                 (if used.(i)
                  then KSeq (KFieldGet (List.nth f_temps i, occ, i), acc)
                  else acc)
           in
           add_reads (ar - 1) sub
       | Ast.PNil | Ast.PCons _ ->
           (* D6: TList column. The two-ctor signature {[], ::} is
              discriminated by a single Eq-against--1 compare on the
              HANDLE — no tag read, ever (§13.5 D6 note): a non-nil
              TList handle always points at a tag-1 cell. Same 2-cmd
              IConst+Eq sequence is_nil desugars to.
              Shape: [if occ == -1 then <nil rows> else <cons rows>].
              The nil specialization keeps default rows, so when no
              PNil head appears it degenerates to the default matrix;
              exhaustiveness guarantees it is then non-empty. *)
           let has_cons =
             List.exists
               (fun row ->
                  let (p, _, _, _) = split_row row in
                  match p with Ast.PCons _ -> true | _ -> false)
               rows
           in
           let nil_rows =
             List.filter_map
               (fun row ->
                  let (p, rest, binds, body) = split_row row in
                  match p with
                  | Ast.PNil -> Some (rest, binds, body)
                  | Ast.PWild -> Some (rest, binds, body)
                  | Ast.PVar x -> Some (rest, (x, occ) :: binds, body)
                  | _ -> None)
               rows
           in
           if nil_rows = [] then
             failwith
               "match lowering: list column without a [] or default \
                row — typing exhaustiveness invariant broken";
           let then_k = compile_match dest occs_rest nil_rows in
           let else_k =
             if has_cons then begin
               (* Cons branch: sub-occurrences read through the
                  existing KHead/KTail (they ARE the field getters,
                  3 cmds each), and only when some sub-pattern
                  inspects or binds — same used-fields filter as
                  KFieldGet (both are never DCE'd). *)
               let t_h = new_temp () in
               let t_t = new_temp () in
               let spec_rows =
                 List.filter_map
                   (fun row ->
                      let (p, rest, binds, body) = split_row row in
                      match p with
                      | Ast.PCons (ph, pt) ->
                          Some (ph :: pt :: rest, binds, body)
                      | Ast.PWild ->
                          Some (Ast.PWild :: Ast.PWild :: rest,
                                binds, body)
                      | Ast.PVar x ->
                          Some (Ast.PWild :: Ast.PWild :: rest,
                                (x, occ) :: binds, body)
                      | _ -> None)
                   rows
               in
               let used_h =
                 List.exists
                   (fun (ps, _, _) -> List.nth ps 0 <> Ast.PWild)
                   spec_rows
               and used_t =
                 List.exists
                   (fun (ps, _, _) -> List.nth ps 1 <> Ast.PWild)
                   spec_rows
               in
               let sub =
                 compile_match dest (t_h :: t_t :: occs_rest) spec_rows
               in
               let sub =
                 if used_t then KSeq (KTail (t_t, occ), sub) else sub
               in
               if used_h then KSeq (KHead (t_h, occ), sub) else sub
             end
             else begin
               if default_rows = [] then
                 failwith
                   "match lowering: list column without a :: or \
                    default row — typing exhaustiveness invariant \
                    broken";
               compile_match dest occs_rest default_rows
             end
           in
           let t_c = new_temp () in
           let t_b = new_temp () in
           KLet (t_c, KInt (-1),
             KLet (t_b, KBinOp (Ast.Eq, occ, t_c),
               KIf (t_b, then_k, else_k)))
       | Ast.PWild | Ast.PVar _ -> assert false)

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