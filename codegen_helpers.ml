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
  | Add -> "+=" | Sub -> "-=" | Mult -> "*=" | Div -> "/="
  | And -> "<"                          (* scoreboard min; valid for 0/1 *)
  | Or  -> ">"                          (* scoreboard max; valid for 0/1 *)
  | _ -> "+="

(* ---- scoreboard ops ---- *)

let cmd_score_set (d : string) (k : int) : string =
  Printf.sprintf "scoreboard players set %s %s %d" d obj_name k

let cmd_score_copy (d : string) (s : string) : string =
  Printf.sprintf "scoreboard players operation %s %s = %s %s" d obj_name s obj_name

(* A non-comparison binop lowers to two commands: dest := v1; dest op= v2.
   The caller must ensure the regalloc has not aliased dest and v2 to the
   same physical slot, or the second command would read a clobbered value.
   Comparison binops lower to a single `execute store success …` command. *)
let cmd_score_binop (d : string) (op : binop) (v1 : string) (v2 : string) : string list =
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
    let copy =
      if d = v1 then []
      else
        [ Printf.sprintf "scoreboard players operation %s %s = %s %s"
            d obj_name v1 obj_name ]
    in
    copy @
    [ Printf.sprintf "scoreboard players operation %s %s %s %s %s"
        d obj_name (op_str op) v2 obj_name ]

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
              Printf.sprintf
                "execute store result storage mcaml:heap %s[%d] int 1 run scoreboard players get %s %s"
                id k t obj_name ])
         temps)
  in
  init :: per_elem

let cmd_arr_get_static (d : string) (id : string) (k : int) : string =
  Printf.sprintf
    "execute store result score %s %s run data get storage mcaml:heap %s[%d] 1"
    d obj_name id k

(* Dynamic array access. 3 commands: copy idx into storage, macro-call the
   per-array getter, copy $arr_result into d. *)
let cmd_arr_get (d : string) (id : string) (idx_score : string) : string list =
  [ Printf.sprintf
      "execute store result storage mcaml:tmp args.idx int 1 run scoreboard players get %s %s"
      idx_score obj_name;
    Printf.sprintf "function mcaml:%s_get with storage mcaml:tmp args" id;
    Printf.sprintf "scoreboard players operation %s %s = $arr_result %s"
      d obj_name obj_name ]

(* Body of a per-array macro getter file, named <id>_get.mcfunction.
   Returns the single macro line (starts with `$`). *)
let macro_helper_body (id : string) : string =
  Printf.sprintf
    "$execute store result score $arr_result vars run data get storage mcaml:heap %s[$(idx)] 1"
    id

(* Static indexed store: single command. *)
let cmd_arr_set_static (id : string) (k : int) (val_score : string) : string =
  Printf.sprintf
    "execute store result storage mcaml:heap %s[%d] int 1 run scoreboard players get %s %s"
    id k val_score obj_name

(* Dynamic indexed store. 3 commands:
     - copy idx into mcaml:tmp args.idx (macro arg)
     - stage the value in the global scratch slot $arr_set_val
     - call the per-array setter macro helper

   The setter macro reads the idx via $(idx) substitution and the value
   from the reserved $arr_set_val scoreboard slot — we can't substitute
   a score through a macro, but a fixed scratch slot is equivalent. *)
let cmd_arr_set (id : string) (idx_score : string) (val_score : string) : string list =
  [ Printf.sprintf
      "execute store result storage mcaml:tmp args.idx int 1 run scoreboard players get %s %s"
      idx_score obj_name;
    Printf.sprintf "scoreboard players operation $arr_set_val %s = %s %s"
      obj_name val_score obj_name;
    Printf.sprintf "function mcaml:%s_set with storage mcaml:tmp args" id ]

(* Body of a per-array macro setter file, named <id>_set.mcfunction.
   Single macro line — $(idx) is substituted by the caller, $arr_set_val
   is a fixed scoreboard slot. *)
let macro_setter_body (id : string) : string =
  Printf.sprintf
    "$execute store result storage mcaml:heap %s[$(idx)] int 1 run scoreboard players get $arr_set_val vars"
    id

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
  Printf.sprintf
    "$execute store result score $arr_result %s run data get storage mcaml:%s cells[$(idx)] 1"
    obj_name (pool_name p)

let pool_set_body (p : Ast.heap_pool) : string =
  Printf.sprintf
    "$execute store result storage mcaml:%s cells[$(idx)] int 1 run scoreboard players get $arr_set_val %s"
    (pool_name p) obj_name

(* Compile-time known-size allocation. Matches DYNMEM_PLAN.md §5.5:
     <base> := $pool_next
     data modify storage mcaml:<pool> cells append value 0   × n
     scoreboard players add $pool_next n
   Total: 2 + n commands. *)
let cmd_heap_alloc_const
    (base : string) (p : Ast.heap_pool) (n : int) : string list =
  let next = pool_next_slot p in
  let path = pool_storage_path p in
  let init =
    Printf.sprintf "scoreboard players operation %s %s = %s %s"
      base obj_name next obj_name
  in
  let append =
    Printf.sprintf "data modify storage %s append value 0" path
  in
  let appends = List.init n (fun _ -> append) in
  let bump =
    Printf.sprintf "scoreboard players add %s %s %d" next obj_name n
  in
  init :: appends @ [bump]

(* Dynamic heap read. §5.3, 5 commands. Uses [$arr_idx] as the composed
   base+idx carrier and the per-pool shared macro helper. *)
let cmd_heap_get
    (d : string) (p : Ast.heap_pool) (base : string) (idx : string)
    : string list =
  [ Printf.sprintf "scoreboard players operation $arr_idx %s = %s %s"
      obj_name base obj_name;
    Printf.sprintf "scoreboard players operation $arr_idx %s += %s %s"
      obj_name idx obj_name;
    Printf.sprintf
      "execute store result storage mcaml:tmp args.idx int 1 run scoreboard players get $arr_idx %s"
      obj_name;
    Printf.sprintf "function mcaml:%s_get with storage mcaml:tmp args"
      (pool_name p);
    Printf.sprintf "scoreboard players operation %s %s = $arr_result %s"
      d obj_name obj_name ]

(* Dynamic heap write. §5.4, 5 commands. Re-uses [$arr_set_val] as the
   value-staging slot (same convention as IArrSet). *)
let cmd_heap_set
    (p : Ast.heap_pool) (base : string) (idx : string) (v : string)
    : string list =
  [ Printf.sprintf "scoreboard players operation $arr_idx %s = %s %s"
      obj_name base obj_name;
    Printf.sprintf "scoreboard players operation $arr_idx %s += %s %s"
      obj_name idx obj_name;
    Printf.sprintf "scoreboard players operation $arr_set_val %s = %s %s"
      obj_name v obj_name;
    Printf.sprintf
      "execute store result storage mcaml:tmp args.idx int 1 run scoreboard players get $arr_idx %s"
      obj_name;
    Printf.sprintf "function mcaml:%s_set with storage mcaml:tmp args"
      (pool_name p) ]

(* ---- function calls ---- *)

(* Tail jump (no save/restore): param_i := arg_i for each arg, then
   `function mcaml:<f>`. Same shape used by KLoop and by helper-free
   (slot_count = 0) KCall. *)
let cmd_tail_jump (f : string) (args : string list) : string list =
  let param_sets =
    List.mapi (fun i a ->
      Printf.sprintf "scoreboard players operation param_%d %s = %s %s"
        i obj_name a obj_name) args
  in
  param_sets @ [Printf.sprintf "function mcaml:%s" f]

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
     param_i := arg_i
     function mcaml:<target>
     restore each named slot from frames[-1].fK
     pop frame                                                    *)
let cmd_call_helper_body_narrow
    ~(slots : string list)
    ~(target : string)
    ~(args : string list) : string list =
  let init =
    "execute unless data storage mcaml:stk frames run \
     data modify storage mcaml:stk frames set value []"
  in
  let push = "data modify storage mcaml:stk frames append value {}" in
  let saves =
    List.mapi (fun i s ->
      Printf.sprintf
        "execute store result storage mcaml:stk frames[-1].f%d int 1 \
         run scoreboard players get %s %s"
        i s obj_name) slots
  in
  let param_sets =
    List.mapi (fun i a ->
      Printf.sprintf "scoreboard players operation param_%d %s = %s %s"
        i obj_name a obj_name) args
  in
  let call = Printf.sprintf "function mcaml:%s" target in
  let restores =
    List.mapi (fun i s ->
      Printf.sprintf
        "execute store result score %s %s run \
         data get storage mcaml:stk frames[-1].f%d 1"
        s obj_name i) slots
  in
  let pop = "data remove storage mcaml:stk frames[-1]" in
  [init; push] @ saves @ param_sets @ [call] @ restores @ [pop]
