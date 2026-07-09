(* strength_reduce.ml — M4 follow-up.

   Stage 1 (shipped): basic induction variable detection plus a
   read-only debug dump. The detection identifies, for each
   non-template [cfg_func], the set of basic IVs of the form

     header: ICopy (lv, "param_N")   (* in cfg.entry *)
     latch:  IBinOp (a, Add|Sub, lv, k_const)
             TTail (self, args) with args.(N) = a

   i.e., a parameter slot that is read in the header, updated by a
   constant step in a latch block, and passed back in the same
   position by the self tail call. This is the shape every
   for_lift-generated helper produces and the same shape the
   hand-written tail-recursive loops in test_all/stress_* happen to
   match. Step encoding: positive for Add, negative for Sub. Zero
   step means the arg is threaded unchanged (loop-invariant param);
   those are not IVs.

   Stage 2 (this commit): derived induction variable detection. For
   each function with at least one basic IV, classify every loop-body
   vreg as one of [Inv | IvLin {iv; stride; base}], then surface the
   non-trivial linear forms (those with a stride or base) as
   [derived_iv] records keyed by the destination vreg. The rewrite
   stage will consume these via [analyze] and a [Hashtbl.t] keyed on
   [derived_dest], but in this commit we only build the table and
   thread it through the dump. No CFG mutation.

   The classification handles the four shapes the M1 test programs
   produce:
     - pure mult:    j := iv * s              -- stride only
     - chained:      m := iv * s; j := m + b  -- stride + base
     - bare add:     j := iv + b              -- stride=1, base=b
     - cross add:    t := inv * inv; j := t + iv
                       (e.g. matmul's i*cols + k row index, where i
                        and cols are loop-invariant and k is the IV)
   The cross-add shape falls out of the same `IvLin + Inv` rule once
   `t` is classified [Inv].

   "Loop-invariant" inside a TCO'd self-loop means: any [IConst] in
   the function, plus any [ICopy (d, "param_N")] where param_N is
   threaded unchanged by every self [TTail], plus any expression
   built from those. The header is part of the loop body in TCO'd
   form, so the plan's "definition outside loop.body" formulation
   does not apply directly — invariance here is about *which value*
   the slot holds across iterations, not lexical placement. The IV
   updates produced at the latch (e.g. [t := k + 1] feeding the
   self [TTail]) classify as [IvLin] too, so we filter them out by
   checking the back-edge arg list before reporting.

   Enable the dump with [MCAML_DUMP_IV=1]. *)

open Cfg

type basic_iv = {
  iv_vreg   : vreg;    (* header-local vreg copied from param_N *)
  param_idx : int;     (* N *)
  step      : int;     (* constant increment per back-edge traversal *)
  latches   : label list;
  (* Every self-TTail block that actually advances this IV by [step].
     A basic IV may have several latches (a hand-written loop can have
     more than one back-edge to itself), but every self-TTail latch in
     the function must either advance the param by the SAME constant
     step or pass it through unchanged — see [detect_basic_ivs]. A
     latch that does anything else (e.g. resets the param to an
     unrelated constant, as a nested-loop-in-one-function shape's
     "advance the outer index, reset the inner index" transition does)
     disqualifies the param from being a basic IV at all, rather than
     silently recording only the latches that happened to match. The
     rewrite stage only appends the per-iteration carrier increment at
     [latches], never at every self-tail block in the function — this
     is the fix for a real miscompile where a derived carrier for the
     INNER loop's index kept advancing even across the OUTER loop's
     reset transition, corrupting the derived value into an
     out-of-bounds array index. *)
}

(* Collect [(lv, N)] for every [ICopy (lv, "param_N")] in the function's
   entry block. If the same [lv] is later overwritten by a non-param
   instruction in the entry block, we drop it — a basic IV must be
   stable through the header. *)
let param_copies_in_entry (cfg : cfg_func) : (vreg * int) list =
  let header = cfg.blocks.(cfg.entry) in
  let out : (vreg * int) list ref = ref [] in
  let clobber (v : vreg) =
    out := List.filter (fun (lv, _) -> lv <> v) !out
  in
  List.iter (fun instr ->
    match instr with
    | ICopy (d, s)
      when String.length s >= 6 && String.sub s 0 6 = "param_" ->
        (try
           let n = int_of_string (String.sub s 6 (String.length s - 6)) in
           clobber d;
           out := (d, n) :: !out
         with Failure _ -> ())
    | _ ->
        (match instr_def instr with
         | Some d -> clobber d
         | None -> ())
  ) header.instrs;
  List.rev !out

(* Walk [b] once and build two side tables under an A-normal-form
   single-assignment assumption (guaranteed by knormal + cfg_build): a
   vreg aliasing map [d -> s] for [ICopy (d, s)] and a constant map
   [d -> k] for [IConst (d, k)]. These feed [step_from_update] below,
   which decides whether a tail-call argument is a constant-stride
   update of an IV candidate even when knormal inserted an ICopy on
   the operand path. *)
type block_info = {
  alias  : (vreg, vreg) Hashtbl.t;
  consts : (vreg, int)  Hashtbl.t;
}

let scan_block (b : block) : block_info =
  let info = { alias = Hashtbl.create 8; consts = Hashtbl.create 8 } in
  List.iter (fun instr ->
    match instr with
    | ICopy (d, s) -> Hashtbl.replace info.alias d s
    | IConst (d, k) -> Hashtbl.replace info.consts d k
    | _ -> ()
  ) b.instrs;
  info

(* Chase [v] through the alias map until it hits a vreg that was not
   defined by an ICopy. Under ANF there are no cycles. *)
let rec resolve (info : block_info) (v : vreg) : vreg =
  match Hashtbl.find_opt info.alias v with
  | Some s -> resolve info s
  | None -> v

(* If [a] is defined in [b] as [lv + const], [const + lv], or
   [lv - const] — possibly with ICopy aliasing on either operand —
   return the signed step. Otherwise None. Sub only matches when
   [lv] is the left operand; [const - lv] is not a linear update. *)
let step_from_update (b : block) (lv : vreg) (a : vreg) : int option =
  let open Ast in
  let info = scan_block b in
  let as_const v =
    let r = resolve info v in
    Hashtbl.find_opt info.consts r
  in
  let is_lv v = resolve info v = lv in
  let rec scan = function
    | [] -> None
    | IBinOp (d, op, x, y) :: _ when d = a ->
        (match op with
         | Add ->
             if is_lv x then as_const y
             else if is_lv y then as_const x
             else None
         | Sub ->
             if is_lv x then
               (match as_const y with
                | Some k -> Some (-k)
                | None -> None)
             else None
         | _ -> None)
    | _ :: rest -> scan rest
  in
  scan b.instrs

(* Walk every block whose terminator is a self tail call and, for each
   parameter-copy pair surfaced by [param_copies_in_entry], classify
   how that latch treats the param: passed through unchanged (modulo
   ICopy aliasing — resolved the same way [invariant_params] does),
   advanced by a constant step, or "other" (anything else, e.g. reset
   to an unrelated constant or a non-linear update). A param qualifies
   as a basic IV only if EVERY self-tail latch in the function is
   either unchanged or advances it by the SAME constant step; the
   latches where it actually advances are recorded so the rewrite
   stage knows exactly where to append the carrier increment. This
   rejects hand-written multi-latch shapes (a two-level loop flattened
   into one recursive function, where the inner index resets to 0 at
   the outer latch) rather than silently miscompiling them — see the
   [latches] field comment. *)
let detect_basic_ivs (cfg : cfg_func) : basic_iv list =
  if cfg.is_template then []
  else
    let params = param_copies_in_entry cfg in
    let self_tails =
      let acc = ref [] in
      Array.iter (fun (b : block) ->
        match b.term with
        | TTail (f, _) when f = cfg.fname -> acc := b :: !acc
        | _ -> ()
      ) cfg.blocks;
      List.rev !acc
    in
    let out = ref [] in
    List.iter (fun (lv, idx) ->
      let step = ref None in
      let step_latches = ref [] in
      let disqualified = ref false in
      List.iter (fun (b : block) ->
        match b.term with
        | TTail (_, args) ->
            let args_arr = Array.of_list args in
            if idx >= Array.length args_arr then disqualified := true
            else begin
              let a = args_arr.(idx) in
              let info = scan_block b in
              if resolve info a = lv then ()
              else
                match step_from_update b lv a with
                | Some k when k <> 0 ->
                    (match !step with
                     | None -> step := Some k; step_latches := b.label :: !step_latches
                     | Some k0 when k0 = k -> step_latches := b.label :: !step_latches
                     | Some _ -> disqualified := true)
                | _ -> disqualified := true
            end
        | _ -> ()
      ) self_tails;
      match !step, !disqualified with
      | Some k, false when !step_latches <> [] ->
          out := { iv_vreg = lv; param_idx = idx; step = k;
                    latches = List.rev !step_latches } :: !out
      | _ -> ()
    ) params;
    List.rev !out

(* ---- derived IV detection ---- *)

(* A derived IV is a vreg classified as [iv * stride + base] where
   [iv] is one of the basic IVs and both [stride] and [base] are
   loop-invariant. Either side may be absent: [stride = None] means
   stride 1; [base = None] means base 0. The dest vreg must be
   defined by exactly one [IBinOp] inside the loop body and must not
   be the back-edge update of a basic IV. *)
type derived_iv = {
  derived_dest : vreg;
  iv           : vreg;
  stride_vreg  : vreg option;
  base_vreg    : vreg option;
  defining_blk : label;
}

type iv_table = {
  basics   : basic_iv list;
  deriveds : derived_iv list;
}

(* A param index is loop-invariant iff every self [TTail] in the
   function passes its arg in that position back as the same vreg
   the entry block bound to the param (modulo local ICopy aliasing
   in the latch block). Functions with no self tail call have no
   loop, so the answer is vacuously empty. *)
let invariant_params (cfg : cfg_func) (params : (vreg * int) list)
  : (int, unit) Hashtbl.t =
  let inv = Hashtbl.create 4 in
  let has_tail = ref false in
  Array.iter (fun (b : block) ->
    match b.term with
    | TTail (f, _) when f = cfg.fname -> has_tail := true
    | _ -> ()
  ) cfg.blocks;
  if !has_tail then
    List.iter (fun (lv, idx) ->
      let pass_through = ref true in
      Array.iter (fun (b : block) ->
        match b.term with
        | TTail (f, args) when f = cfg.fname ->
            let args_arr = Array.of_list args in
            if idx >= Array.length args_arr then pass_through := false
            else
              let info = scan_block b in
              if resolve info args_arr.(idx) <> lv then pass_through := false
        | _ -> ()
      ) cfg.blocks;
      if !pass_through then Hashtbl.replace inv idx ()
    ) params;
  inv

type cls =
  | Inv
  | IvLin of { iv : vreg; stride : vreg option; base : vreg option }

(* Classify every vreg in [cfg] as either [Inv], a basic IV, or a
   linear function of one. Walks blocks in label order and runs the
   walk twice so that operands defined in a later-numbered block
   that feeds an earlier one (rare but possible after optimization
   reorders) still get picked up. The single-block matmul/sum/dot
   loops we care about converge on the first pass. *)
let classify (cfg : cfg_func) (basics : basic_iv list)
  : (vreg, cls) Hashtbl.t * derived_iv list =
  let cls : (vreg, cls) Hashtbl.t = Hashtbl.create 32 in
  let params = param_copies_in_entry cfg in
  let inv_params = invariant_params cfg params in
  List.iter (fun (lv, idx) ->
    if Hashtbl.mem inv_params idx then Hashtbl.replace cls lv Inv
  ) params;
  List.iter (fun iv ->
    Hashtbl.replace cls iv.iv_vreg
      (IvLin { iv = iv.iv_vreg; stride = None; base = None })
  ) basics;
  let derived = ref [] in
  let recorded : (vreg, unit) Hashtbl.t = Hashtbl.create 16 in
  let record d iv stride base blk =
    if not (Hashtbl.mem recorded d) then begin
      Hashtbl.add recorded d ();
      derived := { derived_dest = d; iv;
                   stride_vreg = stride; base_vreg = base;
                   defining_blk = blk } :: !derived
    end
  in
  let step_instr blk_label instr =
    match instr with
    | IConst (d, _) ->
        if not (Hashtbl.mem cls d) then Hashtbl.replace cls d Inv
    | ICopy (d, s) ->
        if not (Hashtbl.mem cls d) then
          (match Hashtbl.find_opt cls s with
           | Some c -> Hashtbl.replace cls d c
           | None -> ())
    | IBinOp (d, op, x, y) ->
        if not (Hashtbl.mem cls d) then begin
          let cx = Hashtbl.find_opt cls x in
          let cy = Hashtbl.find_opt cls y in
          let result : cls option =
            let open Ast in
            match op with
            | Mult ->
                (match cx, cy with
                 | Some Inv, Some Inv -> Some Inv
                 | Some (IvLin { iv; stride = None; base = None }),
                   Some Inv ->
                     Some (IvLin { iv; stride = Some y; base = None })
                 | Some Inv,
                   Some (IvLin { iv; stride = None; base = None }) ->
                     Some (IvLin { iv; stride = Some x; base = None })
                 | _ -> None)
            | Add ->
                (match cx, cy with
                 | Some Inv, Some Inv -> Some Inv
                 | Some (IvLin { iv; stride; base = None }), Some Inv ->
                     Some (IvLin { iv; stride; base = Some y })
                 | Some Inv, Some (IvLin { iv; stride; base = None }) ->
                     Some (IvLin { iv; stride; base = Some x })
                 | _ -> None)
            | Sub ->
                (match cx, cy with
                 | Some Inv, Some Inv -> Some Inv
                 | _ -> None)
            | _ ->
                (match cx, cy with
                 | Some Inv, Some Inv -> Some Inv
                 | _ -> None)
          in
          (match result with
           | Some c ->
               Hashtbl.replace cls d c;
               (match c with
                | IvLin { iv; stride; base }
                  when stride <> None || base <> None ->
                    record d iv stride base blk_label
                | _ -> ())
           | None -> ())
        end
    | _ -> ()
  in
  for _ = 1 to 2 do
    Array.iter (fun (b : block) ->
      List.iter (step_instr b.label) b.instrs
    ) cfg.blocks
  done;
  (cls, List.rev !derived)

(* Build the back-edge dest set: any vreg that appears as a TTail arg
   in the position of a basic IV. These are the IV updates we filter
   out before reporting derived IVs. *)
let backedge_iv_dests (cfg : cfg_func) (basics : basic_iv list)
  : (vreg, unit) Hashtbl.t =
  let s = Hashtbl.create 4 in
  List.iter (fun iv ->
    Array.iter (fun (b : block) ->
      match b.term with
      | TTail (f, args) when f = cfg.fname ->
          let args_arr = Array.of_list args in
          if iv.param_idx < Array.length args_arr then
            Hashtbl.replace s args_arr.(iv.param_idx) ()
      | _ -> ()
    ) cfg.blocks
  ) basics;
  s

let detect_derived_ivs (cfg : cfg_func) (basics : basic_iv list)
  : derived_iv list =
  if cfg.is_template || basics = [] then []
  else
    let _, deriveds = classify cfg basics in
    let bedge = backedge_iv_dests cfg basics in
    List.filter
      (fun d -> not (Hashtbl.mem bedge d.derived_dest))
      deriveds

let analyze (cfg : cfg_func) : iv_table =
  let basics = detect_basic_ivs cfg in
  let deriveds = detect_derived_ivs cfg basics in
  { basics; deriveds }

(* ---- rewrite (Stage 3) ---- *)

(* The rewrite turns each derived IV [j = iv*s + b] into a running
   carrier that lives in a reserved [$ref_sr_<n>] scoreboard slot.
   Per derived IV we:
     1. Mint a fresh carrier name.
     2. Materialize [stride] and [base] in [cfg.preheader_instrs] —
        the values are loop-invariant by classification, but their
        defining instructions live inside the loop body so we
        reconstruct them from constants and direct reads of the
        invariant [param_N] slots. The init line is
            $ref_sr_n := param_<iv_idx> * stride + base
        evaluated in the wrapper file (which runs once at the
        function entry, before [__body]).
     3. Replace the derived IV's defining [IBinOp] in its block with
        an [ICopy(derived_dest, $ref_sr_n)]. Other readers of
        [derived_dest] keep their existing operand name; copy_prop
        does NOT fold a [$ref_*] source into non-ref users (verified
        in [copy_prop.ml]), so the [ICopy] stays and each downstream
        use becomes one extra `scoreboard players operation` — fine.
     4. Append [$ref_sr_n += stride] before the [TTail] of every
        latch block, so the carrier advances in lockstep with the
        basic IV.

   The carrier is a [$ref_*] slot which every reserved-vreg predicate
   in the toolchain (regalloc, copy_prop, dce, inline, unroll,
   liveness) already skips. The freshly emitted [$t_sr_*] temps used
   inside the preheader live ONLY in [cfg.preheader_instrs], which
   regalloc does not walk; codegen prints them as literal scoreboard
   slots in the wrapper file. They never appear in [cfg.blocks], so
   they cannot collide with regalloc-assigned [$rN] slots.

   v1 scope, mirroring the analysis:
     - Only basic IVs with [step = +1]. Other steps would need the
       back-edge increment to be [stride * step] rather than just
       [stride]; the analysis already records the step so the
       generalization is mechanical, but v1 declines.
     - Only single-defining-block derived IVs (already enforced by
       the classifier walking each instruction in source order).
     - Only IVs whose defining function is not a template.
     - Skip a derived IV if any of [stride], [base], or the iv's
       basic-IV record cannot be resolved. *)

type rewrite_state = {
  defs        : (vreg, instr) Hashtbl.t;
  param_of    : (vreg, int) Hashtbl.t;   (* lv -> N for ICopy(lv, "param_N") in entry *)
  emitted     : (vreg, vreg) Hashtbl.t;  (* memoize materialize results *)
  mutable pre : instr list;              (* preheader instrs accumulated, reversed *)
}

(* Use the [$ref_*] prefix for materialized preheader temps so every
   reserved-vreg predicate (regalloc, copy_prop, dce, liveness,
   inline, unroll) treats them as literal scoreboard slots. They
   live only in [cfg.preheader_instrs], but the back-edge increment
   reads them from inside a body block — without the [$ref_] prefix
   regalloc would assign the body read a fresh [$rN] slot while the
   preheader keeps writing to the un-renamed name, dropping the
   stride on the floor. *)
(* Global counter for preheader temps, paralleling [global_carrier].
   Must be global (not per-function) because the generated names are
   global scoreboard slots — if an inner loop's wrapper overwrites
   [$ref_sr_t0] while an outer loop's body still needs it for its
   per-iteration increment, the outer loop's stride is corrupted. *)
let global_tmp = ref 0

let fresh_tmp (_st : rewrite_state) : vreg =
  let n = !global_tmp in
  incr global_tmp;
  Printf.sprintf "$ref_sr_t%d" n

(* Recursively reconstruct an [Inv] vreg's value in the preheader.
   Walks the original definition: param-copies turn into direct
   [param_N] reads, [IConst]s emit a fresh preheader [IConst], and
   [IBinOp] of two materializable operands emits a fresh preheader
   [IBinOp]. Anything else (e.g. an array load, an unknown shape)
   returns [None] and the caller bails. *)
let rec materialize (st : rewrite_state) (v : vreg) : vreg option =
  match Hashtbl.find_opt st.emitted v with
  | Some r -> Some r
  | None ->
      match Hashtbl.find_opt st.param_of v with
      | Some n ->
          let r = Printf.sprintf "param_%d" n in
          Hashtbl.add st.emitted v r;
          Some r
      | None ->
          (match Hashtbl.find_opt st.defs v with
           | None -> None
           | Some instr ->
               (match instr with
                | IConst (_, k) ->
                    let t = fresh_tmp st in
                    st.pre <- IConst (t, k) :: st.pre;
                    Hashtbl.add st.emitted v t;
                    Some t
                | ICopy (_, s) ->
                    (match materialize st s with
                     | Some r -> Hashtbl.add st.emitted v r; Some r
                     | None -> None)
                | IBinOp (_, op, x, y) ->
                    (match materialize st x, materialize st y with
                     | Some x', Some y' ->
                         let t = fresh_tmp st in
                         st.pre <- IBinOp (t, op, x', y') :: st.pre;
                         Hashtbl.add st.emitted v t;
                         Some t
                     | _ -> None)
                | _ -> None))

let mk_state (cfg : cfg_func) : rewrite_state =
  let defs : (vreg, instr) Hashtbl.t = Hashtbl.create 64 in
  Array.iter (fun (b : block) ->
    List.iter (fun i ->
      match instr_def i with
      | Some d -> Hashtbl.replace defs d i
      | None -> ()
    ) b.instrs
  ) cfg.blocks;
  let param_of : (vreg, int) Hashtbl.t = Hashtbl.create 4 in
  let header = cfg.blocks.(cfg.entry) in
  List.iter (fun instr ->
    match instr with
    | ICopy (d, s)
      when String.length s >= 6 && String.sub s 0 6 = "param_" ->
        (try
           let n = int_of_string
             (String.sub s 6 (String.length s - 6)) in
           Hashtbl.replace param_of d n
         with Failure _ -> ())
    | _ -> ()
  ) header.instrs;
  { defs; param_of;
    emitted = Hashtbl.create 16; pre = [] }

let no_sr = Cfg.pass_disabled "MCAML_NO_SR"

let carrier_name (n : int) : vreg = Printf.sprintf "$ref_sr_%d" n

(* Module-global counter so two functions sharing the same compilation
   unit don't fight over [$ref_sr_0]; each SR'd loop gets a unique
   carrier slot. The cost is one Minecraft scoreboard slot per
   carrier, which is fine at the tens-of-IVs scale we expect. *)
let global_carrier = ref 0

let mint_carrier () : vreg =
  let n = !global_carrier in
  incr global_carrier;
  carrier_name n

(* Drop derived IVs whose only consumers are *other* derived IVs
   we're about to rewrite away. Without this filter the matmul
   k*cols intermediate gets its own carrier even though after
   the outer k*cols+j is rewritten the inner has no remaining
   use — DCE eliminates the dead [ICopy] but cannot touch the
   per-iteration `+= stride` in the latch (the carrier is
   reserved). The filter is one query over the derived set. *)
let useful_deriveds_of (cfg : cfg_func) (deriveds : derived_iv list)
  : derived_iv list =
  let candidate_set : (vreg, unit) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun (d : derived_iv) ->
    Hashtbl.replace candidate_set d.derived_dest ()
  ) deriveds;
  List.filter (fun (d : derived_iv) ->
    let used = ref false in
    Array.iter (fun (b : block) ->
      List.iter (fun i ->
        let consumer_is_derived =
          match instr_def i with
          | Some def -> Hashtbl.mem candidate_set def
          | None -> false
        in
        if not consumer_is_derived
           && List.mem d.derived_dest (instr_uses i)
        then used := true
      ) b.instrs;
      if List.mem d.derived_dest (term_uses b.term) then
        used := true
    ) cfg.blocks;
    !used
  ) deriveds

(* Materialize stride; None means stride=1, emitted as a
   fresh IConst so the multiply has a real operand. *)
let materialize_stride (st : rewrite_state) (d : derived_iv)
  : vreg option =
  match d.stride_vreg with
  | None ->
      let t = fresh_tmp st in
      st.pre <- IConst (t, 1) :: st.pre;
      Some t
  | Some v -> materialize st v

let materialize_base (st : rewrite_state) (d : derived_iv)
  : [ `NoBase | `Have of vreg | `Fail ] =
  match d.base_vreg with
  | None -> `NoBase
  | Some v ->
      (match materialize st v with
       | Some r -> `Have r
       | None -> `Fail)

(* Init: carrier := param_<iv_idx> * stride + base. Mints the carrier,
   accumulates the init instrs into [st.pre], returns the carrier. *)
let emit_carrier_init (st : rewrite_state) (bi : basic_iv)
    (stride_v : vreg) (base_kind : [ `NoBase | `Have of vreg | `Fail ])
  : vreg =
  let lo = Printf.sprintf "param_%d" bi.param_idx in
  let carrier = mint_carrier () in
  let mul_dest = fresh_tmp st in
  st.pre <-
    IBinOp (mul_dest, Ast.Mult, lo, stride_v) :: st.pre;
  (match base_kind with
   | `NoBase ->
       st.pre <- ICopy (carrier, mul_dest) :: st.pre
   | `Have base_v ->
       st.pre <-
         IBinOp (carrier, Ast.Add, mul_dest, base_v)
         :: st.pre
   | `Fail -> assert false);
  carrier

(* Replace defining instr in defining_blk. Returns whether the
   replacement actually fired. *)
let replace_defining_instr (cfg : cfg_func) (d : derived_iv)
    (carrier : vreg) : bool =
  let blk = cfg.blocks.(d.defining_blk) in
  let replaced = ref false in
  blk.instrs <- List.map (fun i ->
    if (not !replaced) && instr_def i = Some d.derived_dest
    then begin
      replaced := true;
      ICopy (d.derived_dest, carrier)
    end else i
  ) blk.instrs;
  !replaced

(* Append increment ONLY at the latches [bi] itself
   advances at (never every self-tail block in the
   function — see the [latches] field comment: a
   latch that resets this IV rather than stepping
   it must not also bump the derived carrier). Once
   per carrier×latch pair. *)
let append_latch_increments (cfg : cfg_func)
    (appended_increments : (vreg * label, unit) Hashtbl.t)
    (bi : basic_iv) (carrier : vreg) (stride_v : vreg) : unit =
  List.iter (fun (latch_label : label) ->
    let latch = cfg.blocks.(latch_label) in
    let key = (carrier, latch.label) in
    if not (Hashtbl.mem appended_increments key) then begin
      Hashtbl.add appended_increments key ();
      latch.instrs <-
        latch.instrs @
        [IBinOp (carrier, Ast.Add, carrier, stride_v)]
    end
  ) bi.latches

let run (cfg : cfg_func) : bool =
  if no_sr || cfg.is_template then false
  else
    let table = analyze cfg in
    if table.deriveds = [] then false
    else begin
      let basics_by_iv : (vreg, basic_iv) Hashtbl.t = Hashtbl.create 4 in
      List.iter (fun b -> Hashtbl.replace basics_by_iv b.iv_vreg b)
        table.basics;
      let useful_deriveds = useful_deriveds_of cfg table.deriveds in
      let st = mk_state cfg in
      let changed = ref false in
      let appended_increments : (vreg * label, unit) Hashtbl.t =
        Hashtbl.create 8 in
      List.iter (fun (d : derived_iv) ->
        match Hashtbl.find_opt basics_by_iv d.iv with
        | None -> ()
        | Some bi when bi.step <> 1 -> ()  (* v1: step=1 only *)
        | Some _ when not (List.exists
              (fun (u : derived_iv) ->
                 u.derived_dest = d.derived_dest)
              useful_deriveds) -> ()
        | Some bi ->
            let stride_vreg_opt = materialize_stride st d in
            let base_attempt = materialize_base st d in
            (match stride_vreg_opt, base_attempt with
             | None, _ | _, `Fail -> ()
             | Some stride_v, base_kind ->
                 let carrier = emit_carrier_init st bi stride_v base_kind in
                 if replace_defining_instr cfg d carrier then begin
                   changed := true;
                   append_latch_increments cfg appended_increments
                     bi carrier stride_v
                 end)
      ) table.deriveds;
      if !changed then
        cfg.preheader_instrs <-
          cfg.preheader_instrs @ List.rev st.pre;
      !changed
    end

(* ---- debug dump ---- *)

let dump (cfg : cfg_func) (table : iv_table) : string =
  let buf = Buffer.create 64 in
  Buffer.add_string buf (Printf.sprintf "=== IVs in %s ===\n" cfg.fname);
  if table.basics = [] then
    Buffer.add_string buf "  (no basic IVs)\n"
  else
    List.iter (fun iv ->
      let latches_str =
        String.concat "," (List.map (Printf.sprintf "L%d") iv.latches) in
      Buffer.add_string buf
        (Printf.sprintf "  basic IV %s = param_%d, step=%+d, latches=%s\n"
           iv.iv_vreg iv.param_idx iv.step latches_str)
    ) table.basics;
  if table.deriveds = [] then begin
    if table.basics <> [] then
      Buffer.add_string buf "  (no derived IVs)\n"
  end else
    List.iter (fun d ->
      let stride_str = match d.stride_vreg with
        | Some s -> s | None -> "1" in
      let base_str = match d.base_vreg with
        | Some b -> b | None -> "0" in
      Buffer.add_string buf
        (Printf.sprintf "  derived IV %s = %s * %s + %s (blk L%d)\n"
           d.derived_dest d.iv stride_str base_str d.defining_blk)
    ) table.deriveds;
  Buffer.contents buf
