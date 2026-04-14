(* cfg.ml — Control-flow graph IR for MCaml (Milestone 2).

   Lowered from knormal.kexpr by cfg_build.ml. Consumed by liveness.ml,
   regalloc_cfg.ml, and codegen_cfg.ml.

   Non-SSA. Join-point vregs are guaranteed shared by knormal's
   normalize_to-dest pattern, which pushes the same dest into both branches
   of a KIf at the leaves. If future passes break that invariant they must
   insert ICopy fix-ups in predecessors.

   Key invariants to preserve across every pass:

   - Reserved vregs ($ret, param_N, $arr_result) are never rewritten.
   - IArrGet has a hidden write to $arr_result via the macro helper it
     expands to at codegen time. No pass may reorder IArrGet with other
     instructions that read or write $arr_result.
   - The guard chain (list of enclosing TBranch conds) attached to a block
     at lowering time is the source of truth for both liveness (which pins
     every guard cond as an implicit use of every instr in the block) and
     codegen (which prefixes every emitted command with execute if/unless
     clauses for each guard chain entry). *)

type label = int
type vreg  = string
type aid   = string

type polarity = Pos | Neg

(* Phase A (dynamic memory): dynamic arrays live in one of two flat-int
   storage pools distinct from the per-aid static array storage. The pool
   tag is [Ast.heap_pool] — defined in ast.ml so codegen_helpers (which
   precedes cfg in the build order) can reference it too. Opaque to every
   existing pass; copy_prop/inline/unroll/regalloc/monomorphize only
   rewrite the vreg operands. *)
type heap_pool = Ast.heap_pool = PoolScratch | PoolPermheap

type instr =
  | IConst        of vreg * int
  | ICopy         of vreg * vreg
  | ICommand      of string
  | IBinOp        of vreg * Ast.binop * vreg * vreg
  | ICall         of vreg option * string * vreg list
  | IArrLitConst  of aid * int list
  | IArrLitDyn    of aid * vreg list
  | IArrGetStatic of vreg * aid * int
  | IArrGet       of vreg * aid * vreg
  | IArrSetStatic of aid * int * vreg      (* storage[aid][k] := val, side-effecting *)
  | IArrSet       of aid * vreg * vreg     (* storage[aid][idx] := val, side-effecting *)
  (* Phase A dynamic heap ops. Side-effecting (bump counter / NBT write);
     DCE and CSE must leave them alone. IHeapGet reads NBT, mirrors IArrGet.
     [IHeapAllocConst] is the compile-time-known-size sibling of [IHeapAlloc];
     codegen straight-lines the append sequence. The vreg-form [IHeapAlloc]
     is still reached for runtime-n allocations but codegen_cfg fails on it
     until a TCO'd allocator helper lands. *)
  | IHeapAllocConst of vreg * heap_pool * int          (* d = pool_next; pool_next += n (const) *)
  | IHeapAlloc      of vreg * heap_pool * vreg         (* d = pool_next; pool_next += <n_vreg> *)
  | IHeapGet        of vreg * heap_pool * vreg * vreg  (* d := pool[base + idx] *)
  | IHeapSet        of heap_pool * vreg * vreg * vreg  (* pool[base + idx] := v, side-effecting *)
  (* Phase B cons-list ops. Conspool is its own pool (compound cells
     {h, t}), separate from scratch/permheap. ICons bumps $conspool_next
     and writes NBT (side-effecting). IHead/ITail read via per-field
     macro helpers (mirror IArrGet's hidden $arr_result write). *)
  | ICons           of vreg * vreg * vreg              (* d := cons(h, t), side-effecting *)
  | IHead           of vreg * vreg                     (* d := head(c) *)
  | ITail           of vreg * vreg                     (* d := tail(c) *)
  (* Phase C region brackets. [IRegionEnter k] snapshots $scratch_next/
     $conspool_next into $region_save_<k>_* ; [IRegionExit (k, ret, typ)]
     copies the return value into the parent arena (via a per-[typ]
     deep-copy walker, if the type carries heap handles), truncates the
     two pools back to their saved marks, and restores the bump counters.
     Both are side-effecting. [IRegionExit] reads [ret] (if [Some]) but
     the slot is also written in place — after the walker runs and the
     truncation renumbers surviving cells, the exit rewrites [ret] to
     the shifted handle. Level [k] is capped at 3 (4-level ceiling per
     §4.1). Every existing pass treats these as opaque side-effecting
     instructions with at most one read operand — same treatment as
     IArrSet/ICons. *)
  | IRegionEnter    of int                                       (* level k *)
  | IRegionExit     of int * vreg option * Ast.typ               (* k, return vreg, return type *)

type terminator =
  | TRet
  | TJump   of label
  | TBranch of vreg * label * label * label  (* cond, then, else, join *)
  | TTail   of string * vreg list            (* self tail call, new params *)
  | TUnreachable                             (* defensive: unreachable block *)

type block = {
  label          : label;
  mutable instrs : instr list;       (* forward order after seal *)
  mutable term   : terminator;
  mutable preds  : label list;       (* populated by a post-pass *)
  mutable guards : (vreg * polarity) list;
    (* guard chain from enclosing branches, outermost first *)
}

type cfg_func = {
  fname              : string;
  params             : (string * Ast.typ) list; (* debug provenance only *)
  entry              : label;
  mutable blocks     : block array;  (* blocks.(i).label = i *)
  mutable slot_count : int;          (* filled by regalloc *)
  mutable preheader_instrs : instr list;
    (* M4 §2 LICM: instructions hoisted out of a self-tail-call loop.
       When non-empty, codegen emits two files: a wrapper file
       [<fname>.mcfunction] containing these instructions followed by
       a [function mcaml:<fname>__body] dispatch, and a body file
       [<fname>__body.mcfunction] containing the rest of the function.
       Self-tail-call [TTail (fname, _)] terminators inside the body
       are retargeted to [<fname>__body] so the back-edge skips the
       hoisted preheader code. Empty for every function until LICM
       runs and finds something to hoist. *)
  mutable is_template : bool;
    (* True when this function has array/matrix parameters that haven't
       been monomorphized yet. Templates are never emitted directly;
       they only survive until Phase 2b, which clones them per call
       site and rewrites [#paramN] sentinel aids with concrete storage
       ids. *)
}

(* ---- small helpers ---- *)

let make_block (label : label) : block = {
  label;
  instrs = [];
  term = TUnreachable;
  preds = [];
  guards = [];
}

let add_instr (b : block) (i : instr) : unit =
  b.instrs <- i :: b.instrs

(* Call this after a block has finished accepting instructions to flip
   [instrs] into forward order. cfg_build.ml seals the block at the same
   time it sets the terminator; we avoid doing the reversal there and keep
   it as a single post-lowering walk over all blocks. *)
let finalize_block (b : block) : unit =
  b.instrs <- List.rev b.instrs

let block_is_sealed (b : block) : bool =
  match b.term with TUnreachable -> false | _ -> true

(* Read-only successors of a block's terminator. *)
let succs (t : terminator) : label list =
  match t with
  | TRet | TUnreachable -> []
  | TJump l -> [l]
  | TBranch (_, lt, le, _) -> [lt; le]  (* merge is not a successor of this block *)
  | TTail (_, _) -> []                  (* tail jump leaves the CFG via function call *)

(* Vregs used by a terminator. *)
let term_uses (t : terminator) : vreg list =
  match t with
  | TRet | TJump _ | TUnreachable -> []
  | TBranch (c, _, _, _) -> [c]
  | TTail (_, args) -> args

(* Vregs defined by an instruction. Returns the at-most-one destination. *)
let instr_def (i : instr) : vreg option =
  match i with
  | IConst (d, _)           -> Some d
  | ICopy (d, _)            -> Some d
  | ICommand _              -> None
  | IBinOp (d, _, _, _)     -> Some d
  | ICall (d_opt, _, _)     -> d_opt
  | IArrLitConst _          -> None
  | IArrLitDyn _            -> None
  | IArrGetStatic (d, _, _) -> Some d
  | IArrGet (d, _, _)       -> Some d
  | IArrSetStatic _         -> None
  | IArrSet _               -> None
  | IHeapAllocConst (d, _, _) -> Some d
  | IHeapAlloc (d, _, _)    -> Some d
  | IHeapGet (d, _, _, _)   -> Some d
  | IHeapSet _              -> None
  | ICons (d, _, _)         -> Some d
  | IHead (d, _)            -> Some d
  | ITail (d, _)            -> Some d
  | IRegionEnter _          -> None
  | IRegionExit _           -> None

(* Vregs read by an instruction. Does NOT include guard-chain pinning —
   that's applied by liveness as an augmentation, not an instruction
   property. Does NOT include the implicit $arr_result write by IArrGet
   (reserved slot, never in a liveness set). *)
let instr_uses (i : instr) : vreg list =
  match i with
  | IConst _                -> []
  | ICopy (_, v)            -> [v]
  | ICommand _              -> []
  | IBinOp (_, _, a, b)     -> [a; b]
  | ICall (_, _, args)      -> args
  | IArrLitConst _          -> []
  | IArrLitDyn (_, temps)   -> temps
  | IArrGetStatic _         -> []
  | IArrGet (_, _, idx)     -> [idx]
  | IArrSetStatic (_, _, v) -> [v]
  | IArrSet (_, idx, v)     -> [idx; v]
  | IHeapAllocConst _       -> []
  | IHeapAlloc (_, _, n)    -> [n]
  | IHeapGet (_, _, b, i)   -> [b; i]
  | IHeapSet (_, b, i, v)   -> [b; i; v]
  | ICons (_, h, t)         -> [h; t]
  | IHead (_, c)            -> [c]
  | ITail (_, c)            -> [c]
  | IRegionEnter _          -> []
  | IRegionExit (_, None, _)   -> []
  | IRegionExit (_, Some r, _) -> [r]

(* ---- debug dump ---- *)

let string_of_binop op =
  let open Ast in
  match op with
  | Add -> "+" | Sub -> "-" | Mult -> "*" | Div -> "/"
  | Eq -> "=" | Neq -> "!=" | Lt -> "<" | Gt -> ">" | Leq -> "<=" | Geq -> ">="
  | And -> "&&" | Or -> "||"

let string_of_instr (i : instr) : string =
  match i with
  | IConst (d, k) -> Printf.sprintf "%s := %d" d k
  | ICopy (d, v) -> Printf.sprintf "%s := %s" d v
  | ICommand s -> Printf.sprintf "cmd \"%s\"" s
  | IBinOp (d, op, a, b) ->
      Printf.sprintf "%s := %s %s %s" d a (string_of_binop op) b
  | ICall (Some d, f, args) ->
      Printf.sprintf "%s := call %s(%s)" d f (String.concat ", " args)
  | ICall (None, f, args) ->
      Printf.sprintf "call %s(%s)" f (String.concat ", " args)
  | IArrLitConst (id, ints) ->
      Printf.sprintf "%s := [|%s|]" id
        (String.concat "; " (List.map string_of_int ints))
  | IArrLitDyn (id, temps) ->
      Printf.sprintf "%s := [|%s|]" id (String.concat "; " temps)
  | IArrGetStatic (d, id, k) -> Printf.sprintf "%s := %s[%d]" d id k
  | IArrGet (d, id, idx) -> Printf.sprintf "%s := %s[%s]" d id idx
  | IArrSetStatic (id, k, v) -> Printf.sprintf "%s[%d] := %s" id k v
  | IArrSet (id, idx, v) -> Printf.sprintf "%s[%s] := %s" id idx v
  | IHeapAllocConst (d, p, n) ->
      Printf.sprintf "%s := halloc[%s](%d)" d
        (match p with PoolScratch -> "scratch" | PoolPermheap -> "permheap") n
  | IHeapAlloc (d, p, n) ->
      Printf.sprintf "%s := halloc[%s](%s)" d
        (match p with PoolScratch -> "scratch" | PoolPermheap -> "permheap") n
  | IHeapGet (d, p, b, i) ->
      Printf.sprintf "%s := hget[%s](%s + %s)" d
        (match p with PoolScratch -> "scratch" | PoolPermheap -> "permheap") b i
  | IHeapSet (p, b, i, v) ->
      Printf.sprintf "hset[%s](%s + %s) := %s"
        (match p with PoolScratch -> "scratch" | PoolPermheap -> "permheap") b i v
  | ICons (d, h, t) -> Printf.sprintf "%s := cons(%s, %s)" d h t
  | IHead (d, c)    -> Printf.sprintf "%s := head(%s)" d c
  | ITail (d, c)    -> Printf.sprintf "%s := tail(%s)" d c
  | IRegionEnter k  -> Printf.sprintf "region_enter[%d]" k
  | IRegionExit (k, None, _) -> Printf.sprintf "region_exit[%d] ()" k
  | IRegionExit (k, Some r, _) -> Printf.sprintf "region_exit[%d] %s" k r

let string_of_term (t : terminator) : string =
  match t with
  | TRet -> "ret"
  | TJump l -> Printf.sprintf "jump L%d" l
  | TBranch (c, lt, le, lj) ->
      Printf.sprintf "branch %s ? L%d : L%d (join L%d)" c lt le lj
  | TTail (f, args) ->
      Printf.sprintf "tail %s(%s)" f (String.concat ", " args)
  | TUnreachable -> "unreachable"

let string_of_guards (gs : (vreg * polarity) list) : string =
  if gs = [] then ""
  else
    "  guards: [" ^
    String.concat ", "
      (List.map (fun (v, p) ->
         v ^ (match p with Pos -> "=1" | Neg -> "=0")) gs)
    ^ "]"

let dump_block (buf : Buffer.t) (b : block) : unit =
  Buffer.add_string buf (Printf.sprintf "L%d:" b.label);
  if b.guards <> [] then
    Buffer.add_string buf (string_of_guards b.guards);
  Buffer.add_char buf '\n';
  if b.preds <> [] then begin
    Buffer.add_string buf "  preds: ";
    Buffer.add_string buf
      (String.concat ", " (List.map (fun l -> Printf.sprintf "L%d" l) b.preds));
    Buffer.add_char buf '\n'
  end;
  List.iter (fun i ->
    Buffer.add_string buf "  ";
    Buffer.add_string buf (string_of_instr i);
    Buffer.add_char buf '\n') b.instrs;
  Buffer.add_string buf "  ";
  Buffer.add_string buf (string_of_term b.term);
  Buffer.add_char buf '\n'

let dump_func (f : cfg_func) : string =
  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "fun %s (entry=L%d, slots=%d) {\n" f.fname f.entry f.slot_count);
  Array.iter (dump_block buf) f.blocks;
  Buffer.add_string buf "}\n";
  Buffer.contents buf
