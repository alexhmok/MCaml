(* cost.ml — static cost model for CFG instructions.

   Estimates the number of .mcfunction lines a single [Cfg.instr] will
   contribute to its containing function's main body when [codegen_cfg]
   lowers it. The plan in
   [/Users/alexmok/.claude/plans/mcaml-microgpt-inference.md] §1.2 calls
   this the "tick scheduler cost model"; later passes (cost_analysis,
   tick_split) consume the per-block / per-function summaries to decide
   where to insert tick-split points so a single function invocation
   stays under [maxCommandChainLength].

   This file is the §4 stage 1 deliverable: pure model + summary helpers.
   No analyzer driver, no split-point insertion. *)

open Cfg

let is_comparison (op : Ast.binop) : bool =
  let open Ast in
  match op with
  | Eq | Neq | Lt | Gt | Leq | Geq -> true
  | _ -> false

(* Per-instruction cost. Mirrors the actual lowering rules in
   [codegen_helpers.ml]:
   - [ICopy(d,d)] is elided by codegen_cfg, so it costs 0.
   - Comparison binops emit a single [execute store success] line.
   - Non-comparison binops emit a [d := v1] copy + an in-place op,
     except codegen elides the copy when [d = v1].
   - [ICall] is modeled as the *direct* (no-helper) lowering: param
     sets + function call + optional return copy. The save/restore
     helper, when generated, is a separate .mcfunction file with its
     own line count and is therefore not charged here.
   - [IArrLitDyn] emits one init line plus two lines per element.
   - [IArrGet] (dynamic) is the canonical 3-command sequence
     (set arg / call macro getter / read $arr_result). *)
let estimate (i : instr) : int =
  match i with
  | IConst _                    -> 1
  | ICopy (d, s) when d = s     -> 0
  | ICopy _                     -> 1
  | ICommand _                  -> 1
  | IBinOp (_, op, _, _) when is_comparison op -> 1
  | IBinOp (d, _, v1, _) when d = v1 -> 1
  | IBinOp _                    -> 2
  | ICall (None, _, args)       -> List.length args + 1
  | ICall (Some d, _, args)     ->
      List.length args + 1 + (if d = "$ret" then 0 else 1)
  | IArrLitConst _              -> 1
  | IArrLitDyn (_, temps)       -> 1 + 2 * List.length temps
  | IArrGetStatic _             -> 1
  | IArrGet _                   -> 3
  | IArrSetStatic _             -> 1
  | IArrSet _                   -> 3
  (* Dynamic-heap ops per §5.3–5.5. Sizes for constant-n alloc depend
     on n (n append lines); this is the conservative per-iteration cost. *)
  | IHeapAllocConst (_, _, n)   -> 2 + n
  | IHeapAlloc _                -> 3
  | IHeapGet _                  -> 5
  | IHeapSet _                  -> 6
  (* Phase B cons ops per §5.1–5.2: ICons is the 5-command inline
     sequence; IHead/ITail each lower to 3 commands via a per-field
     macro helper. *)
  | ICons _                     -> 5
  | IHead _                     -> 3
  | ITail _                     -> 3

(* Terminator cost. [TTail] lowers to [len(args)] param renames plus
   one [function mcaml:<f>] dispatch. The other terminators are
   structural and emit nothing in [codegen_cfg]. *)
let estimate_term (t : terminator) : int =
  match t with
  | TRet | TJump _ | TBranch _ | TUnreachable -> 0
  | TTail (_, args) -> List.length args + 1

(* Sum of instruction costs plus the terminator cost for a single block.
   Guard chains do NOT add separate lines: codegen composes them into
   the [execute if/unless ... run] prefix on each emitted command, so
   they only lengthen existing lines. *)
let estimate_block (b : block) : int =
  List.fold_left (fun acc i -> acc + estimate i) 0 b.instrs
  + estimate_term b.term

(* A block emits commands iff codegen_cfg considers it reachable: it is
   the entry block, or some predecessor lists it. Unreachable join
   blocks left over from KIf-with-tail-call branches contribute zero. *)
let block_is_reachable (cfg : cfg_func) (b : block) : bool =
  b.label = cfg.entry || b.preds <> []

(* Whole-function estimate. Sums every reachable block, plus the
   M4-LICM preheader instructions (which codegen lifts into a wrapper
   .mcfunction) and the wrapper's single dispatch line to [<fname>__body]
   when the preheader is non-empty. Helper save/restore files for
   non-tail calls are NOT included; they live in their own files and
   are charged separately by [estimate] callers that walk the
   [Codegen_cfg.emit] output list. *)
let estimate_func (cfg : cfg_func) : int =
  let body =
    Array.fold_left (fun acc b ->
      if block_is_reachable cfg b then acc + estimate_block b else acc)
      0 cfg.blocks
  in
  let pre =
    List.fold_left (fun acc i -> acc + estimate i) 0 cfg.preheader_instrs
  in
  let dispatch = if cfg.preheader_instrs = [] then 0 else 1 in
  body + pre + dispatch
