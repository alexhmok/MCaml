(* codegen_helpers.ml — pure command-string builders.

   No mutable state, no accumulators. Both the kexpr-based codegen.ml and
   the CFG-based codegen_cfg.ml import from here.

   Callers that need helper-function accumulation (save/restore frames
   around non-tail calls, macro helpers for dynamic array indexing) own
   their own state — this module just produces the strings that go into
   those helpers. *)

open Ast

let obj_name = "vars"

let is_comparison = function
  | Eq | Neq | Lt | Gt | Leq | Geq -> true
  | _ -> false

let cmp_str = function
  | Eq -> "=" | Lt -> "<" | Gt -> ">" | Leq -> "<=" | Geq -> ">="
  | _ -> "="

let op_str = function
  | Add -> "+=" | Sub -> "-=" | Mult -> "*=" | Div -> "/=" | Mod -> "%="
  (* FAdd/FSub are scalar-identical to Add/Sub on Q16.16 encoding — see
     typing.ml's BinOp comment. FMult/FDiv never reach here: they're
     intercepted earlier in cmd_score_binop's dedicated arms. *)
  | FAdd -> "+=" | FSub -> "-="
  | And -> "<"                          (* scoreboard min; valid for 0/1 *)
  | Or  -> ">"                          (* scoreboard max; valid for 0/1 *)
  | _ -> "+="

(* ---- scoreboard ops ---- *)

let cmd_score_set (d : string) (k : int) : string =
  Printf.sprintf "scoreboard players set %s %s %d" d obj_name k

(* Generic two-operand scoreboard operation: `d <op> s`, where [op] is
   the literal operator token ("=", "+=", "/=", ...). Every
   score-to-score line in this module routes through here. *)
let cmd_score_op (d : string) (op : string) (s : string) : string =
  Printf.sprintf "scoreboard players operation %s %s %s %s %s"
    d obj_name op s obj_name

let cmd_score_copy (d : string) (s : string) : string =
  cmd_score_op d "=" s

let cmd_score_add (slot : string) (n : int) : string =
  Printf.sprintf "scoreboard players add %s %s %d" slot obj_name n

(* ---- storage <-> score primitives ---- *)

(* Store a score into an NBT path. *)
let store_score_to_storage (path : string) (v : string) : string =
  Printf.sprintf
    "execute store result storage %s int 1 run scoreboard players get %s %s"
    path v obj_name

(* Read an NBT path into a score. *)
let read_storage_to_score (d : string) (path : string) : string =
  Printf.sprintf
    "execute store result score %s %s run data get storage %s 1"
    d obj_name path

(* ---- macro-helper primitives ---- *)

(* Stage a score into the shared macro-args idx slot
   ([storage mcaml:tmp args.idx] — see the runtime conventions). *)
let stage_idx_arg (v : string) : string =
  store_score_to_storage "mcaml:tmp args.idx" v

(* Dispatch a macro helper with the shared args compound. *)
let call_macro_helper (helper : string) : string =
  Printf.sprintf "function mcaml:%s with storage mcaml:tmp args" helper

(* The 3-command macro-getter call pattern: stage [src] as the idx arg,
   dispatch [helper], read [$arr_result] back into [d]. Shared by
   dynamic array gets, cons head/tail, ADT tag/field gets, and the
   tail of the dyn-heap read. *)
let macro_get (d : string) (src : string) (helper : string) : string list =
  [ stage_idx_arg src;
    call_macro_helper helper;
    cmd_score_copy d "$arr_result" ]

(* Body of a single-line macro getter file: read [path] (which embeds
   the `$(idx)` macro hole) into [dest]. The leading `$` marks the
   line as macro-expanded. *)
let macro_getter_into (dest : string) (path : string) : string =
  Printf.sprintf
    "$execute store result score %s %s run data get storage %s 1"
    dest obj_name path

let macro_getter_of_path (path : string) : string =
  macro_getter_into "$arr_result" path

(* Body of a single-line macro setter file: store the staged
   [$arr_set_val] score into [path] (which embeds the `$(idx)` macro
   hole). *)
let macro_setter_of_path (path : string) : string =
  Printf.sprintf
    "$execute store result storage %s int 1 run scoreboard players get $arr_set_val %s"
    path obj_name

(* `param_i := arg_i` staging for direct calls and tail jumps. *)
let cmd_param_sets (args : string list) : string list =
  List.mapi (fun i a -> cmd_score_copy (Printf.sprintf "param_%d" i) a) args

(* A non-comparison binop lowers to two commands: dest := v1; dest op= v2.
   The caller must ensure the regalloc has not aliased dest and v2 to the
   same physical slot, or the second command would read a clobbered value.
   Comparison binops lower to a single `execute store success …` command. *)
let cmd_score_binop (d : string) (op : binop) (v1 : string) (v2 : string) : string list =
  (* Phase N / N6: Q16.16 fixed-point multiply via pre-shift.
     Sequence (5 cmds, or 4 when regalloc already aliased d = v1):
       $fmul_t = v2
       $fmul_t /= $c256          ; v2 >> 8
       d       = v1              ; elided if d = v1
       d       /= $c256          ; v1 >> 8
       d       *= $fmul_t        ; d = (v1>>8) * (v2>>8) = (v1*v2)/65536
     Precision: the bottom 8 bits of each operand are discarded before
     multiplying — fine for NN activations (O(1) values with ~5 digits
     of precision) but unsuitable for values near 1/256. Intermediate
     (v1>>8)*(v2>>8) fits in int32 whenever the true product is within
     Q16.16 range (|x*y| < 32768), so overflow coincides with
     saturation. Alternative split-half variant (~8 cmds) would
     preserve all 16 fractional bits; switch if a workload demands it.
     Phase N / N7 will add FDiv following the same pattern. *)
  if op = FMult then begin
    let copy_v1 = if d = v1 then [] else [cmd_score_copy d v1] in
    [cmd_score_copy "$fmul_t" v2;
     cmd_score_op "$fmul_t" "/=" "$c256"]
    @ copy_v1 @
    [cmd_score_op d "/=" "$c256";
     cmd_score_op d "*=" "$fmul_t"]
  end else if op = FDiv then begin
    (* Phase N / N7: Q16.16 fixed-point divide via scale-up numerator.
       Derivation: want c_encoded = (a_real / b_real) * 65536
                                  = (a * 65536) / b           (from a = a_real*65536, b = b_real*65536)
       Naive `a * 65536 / b` overflows int32 for |a| > 2^15. We split
       the 65536 scale into 256 * 256 applied around the divide:
           d = v1
           d *= $c256               ; d = a * 256  (saturates if |a_real| > 128)
           d /= v2                  ; d = (a * 256) / b
           d *= $c256               ; d = ((a*256)/b) * 256 = (a*65536)/b
       4 commands (3 if regalloc aliased d = v1). Constraint: the
       dividend's true value must be < 128 or `d *= $c256` overflows
       int32. For NN inference this is satisfied because activations
       are O(1) post-normalization and the dividend is usually the
       smaller quantity. Values beyond 128 need a split-half divide
       (~10 cmds, not implemented). Under §12.2's implicit div budget.
       Divide-by-zero: scoreboard operation `/= 0` is a Minecraft
       error in real MC; sim.py's `/=` arm returns 0 silently. The
       compiler does not guard — caller's responsibility. *)
    let copy_v1 = if d = v1 then [] else [cmd_score_copy d v1] in
    copy_v1 @
    [cmd_score_op d "*=" "$c256";
     cmd_score_op d "/=" v2;
     cmd_score_op d "*=" "$c256"]
  end else
  if is_comparison op then
    match op with
    | Neq ->
        [ Printf.sprintf
            "execute store success score %s %s unless score %s %s = %s %s"
            d obj_name v1 obj_name v2 obj_name ]
    | _ ->
        [ Printf.sprintf
            "execute store success score %s %s if score %s %s %s %s %s"
            d obj_name v1 obj_name (cmp_str op) v2 obj_name ]
  else
    let copy = if d = v1 then [] else [cmd_score_copy d v1] in
    copy @ [cmd_score_op d (op_str op) v2]

(* ---- array / matrix ops ---- *)

(* Initialize storage with a constant int list literal. One command. *)
let cmd_arr_lit_const (id : string) (ints : int list) : string =
  let body = String.concat ", " (List.map string_of_int ints) in
  Printf.sprintf "data modify storage mcaml:heap %s set value [%s]" id body

(* Initialize storage from scoreboard temps. Multi-command: init empty, then
   for each element append-zero and store-the-temp. *)
let cmd_arr_lit_dyn (id : string) (temps : string list) : string list =
  let init = Printf.sprintf "data modify storage mcaml:heap %s set value []" id in
  let per_elem =
    List.concat
      (List.mapi
         (fun k t ->
            [ Printf.sprintf "data modify storage mcaml:heap %s append value 0" id;
              store_score_to_storage
                (Printf.sprintf "mcaml:heap %s[%d]" id k) t ])
         temps)
  in
  init :: per_elem

let cmd_arr_get_static (d : string) (id : string) (k : int) : string =
  read_storage_to_score d (Printf.sprintf "mcaml:heap %s[%d]" id k)

(* Dynamic array access. 3 commands: copy idx into storage, macro-call the
   per-array getter, copy $arr_result into d. *)
let cmd_arr_get (d : string) (id : string) (idx_score : string) : string list =
  macro_get d idx_score (id ^ "_get")

(* Body of a per-array macro getter file, named <id>_get.mcfunction.
   Returns the single macro line (starts with `$`). *)
let macro_helper_body (id : string) : string =
  macro_getter_of_path (Printf.sprintf "mcaml:heap %s[$(idx)]" id)

(* Static indexed store: single command. *)
let cmd_arr_set_static (id : string) (k : int) (val_score : string) : string =
  store_score_to_storage (Printf.sprintf "mcaml:heap %s[%d]" id k) val_score

(* Dynamic indexed store. 3 commands:
     - copy idx into mcaml:tmp args.idx (macro arg)
     - stage the value in the global scratch slot $arr_set_val
     - call the per-array setter macro helper

   The setter macro reads the idx via $(idx) substitution and the value
   from the reserved $arr_set_val scoreboard slot — we can't substitute
   a score through a macro, but a fixed scratch slot is equivalent. *)
let cmd_arr_set (id : string) (idx_score : string) (val_score : string) : string list =
  [ stage_idx_arg idx_score;
    cmd_score_copy "$arr_set_val" val_score;
    call_macro_helper (id ^ "_set") ]

(* Body of a per-array macro setter file, named <id>_set.mcfunction.
   Single macro line — $(idx) is substituted by the caller, $arr_set_val
   is a fixed scoreboard slot. *)
let macro_setter_body (id : string) : string =
  macro_setter_of_path (Printf.sprintf "mcaml:heap %s[$(idx)]" id)

(* ---- dynamic heap ops (Phase A) ---- *)

(* String tag for a [Ast.heap_pool]. Used to assemble pool-specific storage
   paths, bump-counter slot names, and macro-helper filenames. *)
let pool_name (p : Ast.heap_pool) : string =
  match p with
  | Ast.PoolScratch  -> "scratch"
  | Ast.PoolPermheap -> "permheap"

let pool_next_slot (p : Ast.heap_pool) : string =
  Printf.sprintf "$%s_next" (pool_name p)

let pool_storage_path (p : Ast.heap_pool) : string =
  Printf.sprintf "mcaml:%s cells" (pool_name p)

(* Body of the pool's shared dynamic-index getter file. Single macro line.
   Mirrors [macro_helper_body] but over [mcaml:<pool> cells] instead of
   per-aid [mcaml:heap <id>]. Emitted once per program (not per function)
   through a filename-level dedupe in main.ml. *)
let pool_get_body (p : Ast.heap_pool) : string =
  macro_getter_of_path
    (Printf.sprintf "mcaml:%s cells[$(idx)]" (pool_name p))

let pool_set_body (p : Ast.heap_pool) : string =
  macro_setter_of_path
    (Printf.sprintf "mcaml:%s cells[$(idx)]" (pool_name p))

(* Compile-time known-size allocation. Matches DYNMEM_PLAN.md §5.5:
     <base> := $pool_next
     data modify storage mcaml:<pool> cells append value 0   × n
     scoreboard players add $pool_next n
   Total: 2 + n commands. *)
let cmd_heap_alloc_const
    (base : string) (p : Ast.heap_pool) (n : int) : string list =
  let next = pool_next_slot p in
  let path = pool_storage_path p in
  let init = cmd_score_copy base next in
  let append =
    Printf.sprintf "data modify storage %s append value 0" path
  in
  let appends = List.init n (fun _ -> append) in
  let bump = cmd_score_add next n in
  init :: appends @ [bump]

(* Dynamic heap read. §5.3, 5 commands. Uses [$arr_idx] as the composed
   base+idx carrier and the per-pool shared macro helper. *)
let cmd_heap_get
    (d : string) (p : Ast.heap_pool) (base : string) (idx : string)
    : string list =
  [ cmd_score_copy "$arr_idx" base;
    cmd_score_op "$arr_idx" "+=" idx ]
  @ macro_get d "$arr_idx" (pool_name p ^ "_get")

(* Dynamic heap write. §5.4, 5 commands. Re-uses [$arr_set_val] as the
   value-staging slot (same convention as IArrSet). *)
let cmd_heap_set
    (p : Ast.heap_pool) (base : string) (idx : string) (v : string)
    : string list =
  [ cmd_score_copy "$arr_idx" base;
    cmd_score_op "$arr_idx" "+=" idx;
    cmd_score_copy "$arr_set_val" v;
    stage_idx_arg "$arr_idx";
    call_macro_helper (pool_name p ^ "_set") ]

(* ---- Phase B cons ops ---- *)

(* Final two commands of every objpool allocation: hand the fresh
   cell's handle to [d], bump the pool counter. *)
let objpool_alloc_finish (d : string) : string list =
  [ cmd_score_copy d "$objpool_next";
    cmd_score_add "$objpool_next" 1 ]

(* Shared objpool cell allocator: append [lit], store each value into
   cells[-1].<field i>, then hand the handle to [d] and bump the pool
   counter. cmd_adt_alloc and cmd_closure_make differ only in the
   append literal and the field-name scheme. *)
let objpool_alloc_cells (d : string) (lit : string)
    (field : int -> string) (vals : string list) : string list =
  ("data modify storage mcaml:objpool cells append value " ^ lit)
  :: List.mapi
       (fun i v ->
          store_score_to_storage
            (Printf.sprintf "mcaml:objpool cells[-1].%s" (field i)) v)
       vals
  @ objpool_alloc_finish d

(* §5.1 ICons — 5 commands inline, no macro helper. The cells[-1]
   trick: we append a fresh {tag:1,h:0,t:0} compound, then store-result
   into the [-1].h / [-1].t fields. [-1] is a literal NBT path index,
   not a runtime value, so no macro expansion is needed on the write
   side. D4: cells live in the unified objpool and carry Cons's tag
   (= 1, its D3 decl-order ctor index within the builtin list type).
   The tag rides in the append literal because it is a codegen-time
   constant — no separate tag-write command, so ICons stays at 5 cmds
   (§13.5 budgeted 6). D5's generic ADT cells ({tag, f0, f1, ...}) get
   the same treatment since ctor tags are always static. *)
let cmd_cons (d : string) (h : string) (t : string) : string list =
  [ "data modify storage mcaml:objpool cells append value {tag:1,h:0,t:0}";
    store_score_to_storage "mcaml:objpool cells[-1].h" h;
    store_score_to_storage "mcaml:objpool cells[-1].t" t ]
  @ objpool_alloc_finish d

(* §5.2 IHead / ITail — 3 commands each via a per-field macro helper.
   Symmetric, parameterized by field name ("h" or "t"). *)
let cmd_cons_field
    (d : string) (c : string) (field : string) : string list =
  macro_get d c
    ("cons_"
     ^ (match field with "h" -> "head" | "t" -> "tail" | _ -> assert false))

let cmd_cons_head (d : string) (c : string) : string list =
  cmd_cons_field d c "h"

let cmd_cons_tail (d : string) (c : string) : string list =
  cmd_cons_field d c "t"

(* Body of [cons_head.mcfunction] / [cons_tail.mcfunction]. Each is a
   single macro-expanded line reading the field out of objpool[idx]
   into [$arr_result]. Emitted once per program via main.ml's filename
   dedupe (same mechanism as [scratch_get.mcfunction]). Cons cells keep
   their h/t field names inside the tagged objpool cell precisely so
   these stay field-addressed at 3 cmds post-D4. *)
let cons_head_body : string =
  macro_getter_of_path "mcaml:objpool cells[$(idx)].h"

let cons_tail_body : string =
  macro_getter_of_path "mcaml:objpool cells[$(idx)].t"

(* ---- Phase D ADT ops (D5) ---- *)

(* IAdtAlloc — 3 + <#fields> commands inline, mirroring cmd_cons.
   The ctor tag is a codegen-time constant (D3 decl-order index), so it
   rides inside the append literal — no separate tag-write command
   (the D4 precedent that kept ICons at 5). Nullary ctors allocate a
   bare {tag:k} cell (§13.5 allocate-uniformly): 3 commands, and tag
   reads stay uniform across every ctor. *)
let cmd_adt_alloc (d : string) (tag : int) (fields : string list) : string list =
  let lit =
    "{tag:" ^ string_of_int tag
    ^ String.concat ""
        (List.mapi (fun i _ -> Printf.sprintf ",f%d:0" i) fields)
    ^ "}"
  in
  objpool_alloc_cells d lit (Printf.sprintf "f%d") fields

(* ITagGet / IFieldGet — exactly 3 commands each via the §5.2
   macro-getter pattern, parameterized by helper file name. *)
let cmd_obj_get (d : string) (c : string) (helper : string) : string list =
  macro_get d c helper

let cmd_obj_tag_get (d : string) (c : string) : string list =
  cmd_obj_get d c "obj_tag"

let cmd_obj_field_get (d : string) (c : string) (k : int) : string list =
  cmd_obj_get d c (Printf.sprintf "obj_f%d" k)

(* Bodies of [obj_tag.mcfunction] / [obj_f<k>.mcfunction]. Single
   macro-expanded line each, reading the field out of objpool[idx]
   into [$arr_result]. Field getters are per-index files; both kinds
   are deduped by filename in main.ml like cons_head/cons_tail. *)
let obj_tag_body : string =
  macro_getter_of_path "mcaml:objpool cells[$(idx)].tag"

let obj_field_body (k : int) : string =
  macro_getter_of_path
    (Printf.sprintf "mcaml:objpool cells[$(idx)].f%d" k)

(* ---- Phase F closure ops (F5) ---- *)

(* IClosureMake — 3 + <#captures> commands inline, mirrors cmd_adt_alloc
   exactly except the tag is fixed to -2 (§13.12 decision 4) and fields
   are named env_0, env_1, ... instead of f0, f1, .... [code] is this
   lambda helper's dense whole-program closure-shape index, assigned by
   closure_layout.ml (F5 decision: a new global table, lambda-helper name
   -> code, NOT a hash/intern of the name). *)
let cmd_closure_make (d : string) (code : int) (caps : string list) : string list =
  let lit =
    "{tag:-2,code:" ^ string_of_int code
    ^ String.concat ""
        (List.mapi (fun i _ -> Printf.sprintf ",env_%d:0" i) caps)
    ^ "}"
  in
  objpool_alloc_cells d lit (Printf.sprintf "env_%d") caps

(* IApply call-site lowering (F5 decision: one shared [mcaml:apply]
   dispatch function program-wide, not one per call-site shape — see
   [apply_dispatch_body] below). Stages the closure handle into the
   shared macro-args idx slot (same convention as cons_head/obj_f<k>),
   stages each of THIS call site's own (non-captured) arguments into the
   reserved [$apply_arg_<i>] bank, then dispatches to [mcaml:apply].
   Captures are unpacked from the cell by the per-shape
   [apply_dispatch_<code>] trampoline instead of here, because the
   offset those captures land at in the target's param array depends on
   which concrete closure shape [$code] turns out to be at runtime —
   not knowable at this call site. 2 + <#args> commands; the [$ret]
   read-back (when the result is used) is pushed separately by the
   caller, mirroring ICall's own convention. *)
let cmd_apply (cl : string) (args : string list) : string list =
  let arg_stages =
    List.mapi (fun i a ->
      cmd_score_copy (Printf.sprintf "$apply_arg_%d" i) a)
      args
  in
  (stage_idx_arg cl :: arg_stages) @ [ call_macro_helper "apply" ]

(* Body of the shared [apply.mcfunction] (F5 decision 2: ONE dispatch
   chain covering every closure-typed call site program-wide, not one
   synthesized per call-site shape). Reads [$code] out of the closure
   cell via the standard $(idx) macro-getter convention (mirrors
   obj_tag), then chains one guarded dispatch per known shape. Each
   branch uses `return run`, the same TTail idiom codegen_cfg.ml already
   relies on (see its emit_term doc comment) so a matching branch
   terminates this function instead of falling through to test the
   remaining codes. [codes] must be every code value closure_layout.ml
   assigned, in any order (rendered in ascending order here only for
   readable output — dispatch is a flat if-chain, not a jump table, so
   order has no correctness effect). *)
let apply_dispatch_body (codes : int list) : string list =
  let get_code =
    macro_getter_into "$code" "mcaml:objpool cells[$(idx)].code"
  in
  let branches =
    List.map (fun code ->
      Printf.sprintf
        "execute if score $code %s matches %d run return run function mcaml:apply_dispatch_%d with storage mcaml:tmp args"
        obj_name code code)
      (List.sort compare codes)
  in
  get_code :: branches

(* Body of one [apply_dispatch_<code>.mcfunction] trampoline (F5 decision
   3: the env-unpack prelude lives HERE, as a per-shape thin wrapper, not
   duplicated inline inside the shared [apply] dispatcher). Unpacks
   env_0..env_{n_captured-1} from the closure cell (same $(idx) as the
   caller) into param_0..param_{n_captured-1}, copies this call's own
   args out of the [$apply_arg_*] bank into the trailing param slots,
   then tail-dispatches to the concrete lifted lambda helper. Mirrors
   for_lift's own "captures-as-leading-params" convention
   (`helper_params = fv_list @ params`, for_lift.ml) — a direct ICall
   never needs to reconstruct that split because the caller already has
   every argument positioned correctly; the apply boundary is the one
   place a runtime shape lookup stands between the two. n_captured +
   n_args + 1 commands. *)
let apply_dispatch_trampoline_body
    (n_captured : int) (n_args : int) (target : string) : string list =
  let env_reads =
    List.init n_captured (fun i ->
      macro_getter_into (Printf.sprintf "param_%d" i)
        (Printf.sprintf "mcaml:objpool cells[$(idx)].env_%d" i))
  in
  let arg_copies =
    List.init n_args (fun i ->
      cmd_score_copy (Printf.sprintf "param_%d" (n_captured + i))
        (Printf.sprintf "$apply_arg_%d" i))
  in
  env_reads @ arg_copies @ [ Printf.sprintf "return run function mcaml:%s" target ]

(* ---- function calls ---- *)

(* Tail jump (no save/restore): param_i := arg_i for each arg, then
   `function mcaml:<f>`. Same shape used by KLoop and by helper-free
   (slot_count = 0) KCall. *)
let cmd_tail_jump (f : string) (args : string list) : string list =
  cmd_param_sets args @ [Printf.sprintf "function mcaml:%s" f]

(* Body of a save/restore helper function for a non-tail call.
   [slots] is the explicit list of physical slot names that must survive
   the call (i.e., are live across it). The slot list should NOT include
   the call's destination, since the destination's old value is about to
   be overwritten by [$ret] anyway. Field names in the saved frame are
   indexed by the position of the slot in the list — at restore time we
   walk the same list in the same order, so the indices line up.

   When [slots = []] this still produces a valid helper (lazy-init + push
   + zero saves + param_sets + call + zero restores + pop), but in that
   case the caller should prefer to skip the helper entirely and emit a
   direct call. Codegen_cfg does this.

   The helper body sequence is:
     lazy-init storage list
     push empty frame
     save each named slot into frames[-1].fK
     <call_cmds>
     restore each named slot from frames[-1].fK
     pop frame

   Factored as [call_cmds] rather than a fixed "param_i := arg_i; function
   mcaml:<target>" shape so the same save/restore scaffolding can wrap
   IApply's staged-args dispatch too (F5: [cmd_apply_helper_body] below) —
   physical scoreboard slots are a single global namespace, so a call
   through a runtime closure value can clobber a live caller slot exactly
   like an ordinary call can, and needs the identical protection. *)
let cmd_call_helper_body_generic
    ~(slots : string list)
    ~(call_cmds : string list) : string list =
  let init =
    "execute unless data storage mcaml:stk frames run \
     data modify storage mcaml:stk frames set value []"
  in
  let push = "data modify storage mcaml:stk frames append value {}" in
  let saves =
    List.mapi (fun i s ->
      store_score_to_storage
        (Printf.sprintf "mcaml:stk frames[-1].f%d" i) s) slots
  in
  let restores =
    List.mapi (fun i s ->
      read_storage_to_score s
        (Printf.sprintf "mcaml:stk frames[-1].f%d" i)) slots
  in
  let pop = "data remove storage mcaml:stk frames[-1]" in
  [init; push] @ saves @ call_cmds @ restores @ [pop]

let cmd_call_helper_body_narrow
    ~(slots : string list)
    ~(target : string)
    ~(args : string list) : string list =
  let call = Printf.sprintf "function mcaml:%s" target in
  cmd_call_helper_body_generic ~slots
    ~call_cmds:(cmd_param_sets args @ [call])

(* IApply save/restore variant (F5): identical framing to
   [cmd_call_helper_body_narrow], with [cmd_apply]'s idx+$apply_arg-bank
   staging in place of "param_i := arg_i; function mcaml:<target>". *)
let cmd_apply_helper_body
    ~(slots : string list)
    ~(cl : string)
    ~(args : string list) : string list =
  cmd_call_helper_body_generic ~slots ~call_cmds:(cmd_apply cl args)

(* ---- Phase C region enter / exit + truncation helpers ---- *)

(* §5.6 enter: two score ops, one per snapshotted pool. Permheap is
   intentionally NOT snapshotted per §4.4 (permheap persists across
   invocations). *)
let cmd_region_enter (k : int) : string list =
  List.map (fun pool ->
    cmd_score_copy (Printf.sprintf "$region_save_%d_%s" k pool)
      (Printf.sprintf "$%s_next" pool))
    ["scratch"; "objpool"]

(* §5.6 exit, primitive-return path. Two helper dispatches; counter
   restore happens inline with each truncation helper loop. *)
let cmd_region_exit_primitive (k : int) : string list =
  [
    Printf.sprintf "function mcaml:region_truncate_%d_scratch" k;
    Printf.sprintf "function mcaml:region_truncate_%d_objpool" k;
  ]

(* §5.6 exit, TList TInt-return path (Strategy B). Given the child-
   region root handle in [ret], dispatches the stash walker (reads
   every reachable cell from mcaml:objpool into mcaml:region_tmp
   objpool, preserving forward order), runs both truncation helpers
   (zeros scratch, pops objpool back to saved), initializes
   [$wr_prev] to -1, then dispatches the rebuild walker (drains
   region_tmp by popping from the tail, re-appending each cell to
   objpool with [t := $wr_prev], so the iteration order reverses
   twice and the final chain ends up in the original order). The
   new head handle lands in [$wr_prev] at the end, and the caller's
   final [ret := $wr_prev] rewrites the user vreg to the parent-
   region handle. *)
let cmd_region_exit_list_int (k : int) (ret : string) : string list =
  [
    (* 1. Seed the stash walker with the child root handle. *)
    cmd_score_copy "$wr_h" ret;
    (* 2. Stash walker: fills region_tmp objpool from the child chain. *)
    "function mcaml:region_walker_list_stash";
  ]
  (* 3. Truncation helpers: pop region-allocated cells out of the
        primary pools back to the saved marks. *)
  @ cmd_region_exit_primitive k
  @ [
    (* 4. Seed the rebuild walker with nil tail. *)
    cmd_score_set "$wr_prev" (-1);
    (* 5. Rebuild walker: drains region_tmp, re-appends cells to
          objpool so the final list is at parent-region handles. *)
    "function mcaml:region_walker_list_rebuild";
    (* 6. Rewrite ret to the new parent-region head handle. *)
    cmd_score_copy ret "$wr_prev";
  ]

(* Stash walker body. Level-independent (no save-slot references).
   Reads the current child handle from [$wr_h] and terminates when
   it hits -1 (nil). Each iteration reads cell[$wr_h]'s h and t
   fields via the existing cons_head / cons_tail macro helpers
   (which write to $arr_result), then appends a fresh
   {tag:1, h: ..., t:0} to region_tmp objpool. The rebuild walker
   fills in the t-field later during its own pass; until then every
   stashed cell carries t:0 and nothing reads it. The tag MUST be
   preserved through the stash/rebuild round-trip (a rebuilt cell
   without its tag would corrupt every post-region match once D5
   lands); this walker only ever traverses TList cells, whose tag is
   statically 1, so preserving it costs nothing — it rides in the
   append literals here and in the rebuild body below. *)
let region_walker_list_stash_body : string list =
  [
    Printf.sprintf
      "execute if score $wr_h %s matches -1 run return 0" obj_name;
    stage_idx_arg "$wr_h";
    call_macro_helper "cons_head";
    cmd_score_copy "$wr_cache_h" "$arr_result";
    stage_idx_arg "$wr_h";
    call_macro_helper "cons_tail";
    cmd_score_copy "$wr_h" "$arr_result";
    "data modify storage mcaml:region_tmp objpool append value {tag:1,h:0,t:0}";
    store_score_to_storage "mcaml:region_tmp objpool[-1].h" "$wr_cache_h";
    "function mcaml:region_walker_list_stash";
  ]

(* Rebuild walker body. Drains mcaml:region_tmp objpool from the
   tail. Each iteration pops region_tmp[-1], appends a fresh cell to
   mcaml:objpool with h = the popped value and t = [$wr_prev] (the
   previous iteration's new handle, initially -1 for the first cell
   which becomes the nil-terminated end of the new list). [$wr_prev]
   is then advanced to the new cell's handle, so the final value of
   [$wr_prev] after the walker empties region_tmp is the head of the
   rebuilt parent-region list. Because region_tmp was filled front-
   to-back by the stash walker and we drain it back-to-front here,
   the iteration order reverses twice — the final chain is in the
   original order. *)
let region_walker_list_rebuild_body : string list =
  [
    "execute unless data storage mcaml:region_tmp objpool[0] run return 0";
    read_storage_to_score "$wr_tmp_h" "mcaml:region_tmp objpool[-1].h";
    "data remove storage mcaml:region_tmp objpool[-1]";
    "data modify storage mcaml:objpool cells append value {tag:1,h:0,t:0}";
    store_score_to_storage "mcaml:objpool cells[-1].h" "$wr_tmp_h";
    store_score_to_storage "mcaml:objpool cells[-1].t" "$wr_prev";
  ]
  @ objpool_alloc_finish "$wr_prev"
  @ [ "function mcaml:region_walker_list_rebuild" ]

(* Body of region_truncate_<k>_scratch.mcfunction. Three guarded
   commands per iteration: pop the tail cell, decrement the bump
   counter, self-recurse while counter > saved. v1 limitation: no
   tick_guard-style slicing because the helper is called synchronously
   from the region-containing function and the caller depends on
   completion — yielding mid-helper would return partial work and the
   caller would continue past the region exit with a dangling pool
   state. Documented in §12 as a future-work item; v1's regions must
   stay under ~20k cells per pool to fit maxCommandChainLength. *)
let region_truncate_body (pool : string) (k : int) : string list =
  let guard =
    Printf.sprintf
      "execute if score $%s_next %s > $region_save_%d_%s %s run"
      pool obj_name k pool obj_name
  in
  [
    Printf.sprintf "%s data remove storage mcaml:%s cells[-1]" guard pool;
    Printf.sprintf "%s scoreboard players remove $%s_next %s 1"
      guard pool obj_name;
    Printf.sprintf "%s function mcaml:region_truncate_%d_%s" guard k pool;
  ]

let region_truncate_scratch_body (k : int) : string list =
  region_truncate_body "scratch" k

let region_truncate_objpool_body (k : int) : string list =
  region_truncate_body "objpool" k
