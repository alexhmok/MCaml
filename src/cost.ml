(* cost.ml — static cost model for CFG instructions.

   Estimates the number of .mcfunction lines a single [Cfg.instr] will
   contribute to its containing function's main body when [codegen_cfg]
   lowers it. The plan in
   [/Users/alexmok/.claude/plans/mcaml-microgpt-inference.md] §1.2 calls
   this the "tick scheduler cost model"; tick_split.ml and tick_guard.ml
   (via main.ml) consume the per-block / per-function summaries to
   decide where to insert tick-split points so a single function
   invocation stays under [maxCommandChainLength].

   This file is pure model + summary helpers. No analyzer driver, no
   split-point insertion. *)

open Cfg

(* Phase F / F5: whole-program constant for the IApply cost formula
   (§13.12 decision 5: "4 + 2 * K_max_captured"). Set once by main.ml
   right after closure_layout.ml computes it (which itself runs right
   after Closure_spec.run, before the Phase 3 loop that consults this
   module) — every [estimate]/[estimate_block]/[estimate_func] call
   during Phase 3 then sees the correct value. Stays 0 (the pre-F5
   placeholder) for any program with no closures at all, matching the
   old hardcoded constant on every canary. This is the one piece of
   mutable state in an otherwise pure cost model; a program-wide
   constant computed once before Phase 3 and read (never rewritten)
   for the rest of the run is the same shape as [Cfg.o0]/[pass_disabled]
   already use elsewhere, just local to this module because nothing
   else needs it. *)
let k_max_captured = ref 0

(* Same predicate the lowering itself uses — the cost model must agree
   with codegen_helpers on which binops take the 1-command path. *)
let is_comparison = Codegen_helpers.is_comparison

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
  (* Phase D ADT ops: IAdtAlloc mirrors ICons (append + one store per
     field + two counter ops = 3 + #fields); ITagGet/IFieldGet are the
     3-command macro-getter sequence, same as IHead/ITail. *)
  | IAdtAlloc (_, _, args)      -> 3 + List.length args
  | ITagGet _                   -> 3
  | IFieldGet _                 -> 3
  (* Phase C region brackets. Enter is two score ops (save scratch +
     objpool). Exit for primitive return is: call region_truncate_<k>
     helper (1 cmd) + restore two bump counters (2 cmds). Heap returns
     add the walker cost but that lands with C5 — primitive-return
     placeholder estimate here is 3 for the exit. *)
  | IRegionEnter _              -> 2
  | IRegionExit _               -> 3
  (* Phase F closure ops (F5). IClosureMake now has a real, exactly-known
     lowering (cmd_closure_make) whenever an instance survives to
     codegen — priced identically to IAdtAlloc just above (3 + #fields),
     since a closure cell IS an objpool alloc, just with env_<k> fields
     instead of f<k> and a fixed tag. Whether an instance survives at
     all is closure_spec.ml's call (Known instances get rewritten away
     before this model ever runs on them, same as before F5); this arm
     only prices what's actually left in the block. IApply's decision-5
     price is "4 + 2 * K_max_captured", a single whole-program constant
     over every Escaping closure's *capture count* (invisible at an
     individual IApply site — captures live inside the closure cell,
     not in this op's own arg list, so args here are ordinary call
     arguments and must not be conflated with captures). K_max_captured
     is set once by main.ml (via [k_max_captured] above) right after
     closure_layout.ml enumerates every surviving Escaping closure
     shape. *)
  | IClosureMake (_, _, caps)    -> 3 + List.length caps
  | IApply _                     -> 4 + 2 * !k_max_captured

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
