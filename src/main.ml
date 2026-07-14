open Ast

(* When MCAML_DUMP_CFG=1, dump each function's post-regalloc CFG + emitted
   commands to stderr after Phase 3. *)
let dump_cfg = try Sys.getenv "MCAML_DUMP_CFG" = "1" with Not_found -> false

(* When MCAML_DUMP_LOOPS=1, run dominator + loop detection over each
   non-template cfg_func and dump the results to stderr. Read-only —
   does not mutate the CFG. Used by the M4 §10 stage 1 verification. *)
let dump_loops = try Sys.getenv "MCAML_DUMP_LOOPS" = "1" with Not_found -> false

(* When MCAML_DUMP_IV=1, run basic induction-variable detection over
   each non-template cfg_func and dump the result to stderr. Read-only;
   part of the SR §1 stage-1 verification. *)
let dump_iv = try Sys.getenv "MCAML_DUMP_IV" = "1" with Not_found -> false

(* When MCAML_DUMP_COSTS=1, after each cfg_func is lowered to files,
   dump the static [Cost.estimate_func] estimate alongside the actual
   command counts of every emitted .mcfunction file. Used to spot-check
   the §1.2 cost model against reality. *)
let dump_costs = try Sys.getenv "MCAML_DUMP_COSTS" = "1" with Not_found -> false

(* When MCAML_NO_TICK_SPLIT=1, skip the §1.4 straight-line splitter so a
   single .mcfunction file can exceed [MCAML_TICK_BUDGET]. Used for A/B
   measurement and for debugging generated output without the
   __cont<N> fan-out obscuring line counts. *)
let no_tick_split = try Sys.getenv "MCAML_NO_TICK_SPLIT" = "1" with Not_found -> false

(* Output directory for emitted .mcfunction files.
     - `-o <dir>` CLI flag takes precedence
     - else MCAML_OUT env var
     - else current working directory (backwards compat for test harness)
   If the chosen directory doesn't exist, we create it (non-recursively). *)
let parse_out_dir () : string =
  let dir = ref None in
  let args = Array.to_list Sys.argv in
  let rec walk = function
    | [] -> ()
    | "-o" :: d :: rest -> dir := Some d; walk rest
    | _ :: rest -> walk rest
  in
  walk (List.tl args);
  match !dir with
  | Some d -> d
  | None ->
      (try Sys.getenv "MCAML_OUT" with Not_found -> ".")

let ensure_dir (d : string) : unit =
  if d = "." || d = "" then ()
  else if Sys.file_exists d then
    (if not (Sys.is_directory d) then
       failwith (Printf.sprintf "mcaml: -o %s: not a directory" d))
  else
    (* mkdir -p handles nested paths and is-already-there races. *)
    let rc = Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote d)) in
    if rc <> 0 then
      failwith (Printf.sprintf "mcaml: cannot create output dir %s" d)

(* M3c-1a: two-phase pipeline.

   Phase 1: parse + for each Fun do alpha -> type -> knormal -> tco ->
            cfg_build. Store the resulting cfg_func in a hashtable keyed
            by function name, preserving source order in a parallel list
            so emission is deterministic.

   Phase 2: Inline.run on the full function table (M3c-1b). A no-op
            placeholder for M3c-1a; wired in once inline.ml lands.

   Phase 3: for each function in source order, run
            Optimize -> Regalloc -> Codegen_cfg, then write files. *)

(* ---- frontend: per-def preparation before Phase 1 ---- *)

(* Reserve names the datapack packager synthesizes (tools/pack_datapack.py).
   `init.mcfunction` is minted at packaging time and wired to
   #minecraft:load; a user-defined `init` would silently clobber it. *)
let check_reserved_names program =
  List.iter (function
    | Fun ("init", _, _, _) ->
        failwith "mcaml: function name 'init' is reserved by the datapack packager"
    | _ -> ()
  ) program

(* Phase D: register type declarations in source order BEFORE
   for_lift runs — for_lift's walk consults Typing.infer for Let
   RHS types, which needs the ctor environment populated. Source
   order means a type must be declared before first use (no
   forward references between type declarations in v1). *)
let register_type_decls program =
  List.iter (function
    | TypeDecl (name, params, ctors) ->
        Typing.register_type_decl name params ctors
    | RecordDecl (name, fields) -> Typing.register_record_decl name fields
    | _ -> ()
  ) program

(* Phase G: collect top-level `val` definitions as globals. v1 scope:
   each val's RHS must be an `Array [...]` literal with int-constant
   elements (no runtime computation). The val's stable aid is
   `__g_<name>`; typing and knormal are seeded with the binding
   before Phase 1 runs so every function body that references the
   name resolves through the global env. The concatenated init
   commands are emitted as a synthetic `__globals_init.mcfunction`
   that real Minecraft runs at datapack load (wired by
   tools/pack_datapack.py), and that sim test harnesses must run
   explicitly before the function under test. *)
let collect_globals program : (string * typ * int list) list =
  let globals : (string * typ * int list) list =
    List.filter_map (fun d ->
      match d with
      | Val (name, Array elems) ->
          (* Infer element type from the literals: if any element is
             a Float literal, the val is TArrStatic(TFloat, n);
             otherwise TArrStatic(TInt, n). The runtime representation
             is identical per §12.1 — 32-bit ints in storage — but
             the declared element type matters for typing downstream,
             because TFloat subscripts return TFloat which can flow
             into fmul/fdiv/etc. without an explicit coercion. *)
          let has_float = List.exists (fun e ->
            match e with Float _ -> true | _ -> false) elems
          in
          let elt_ty = if has_float then TFloat else TInt in
          let ints = List.map (fun e ->
            match e with
            | Int i -> i
            | Float f ->
                (* Apply the same Q16.16 encoding knormal uses for
                   float literals so a `val lut = [| 1.5; 2.5 |]`
                   produces the expected encoded ints in storage. *)
                let scaled = Float.round (f *. 65536.0) in
                if scaled < -2147483648.0 || scaled > 2147483647.0 then
                  failwith
                    (Printf.sprintf
                       "mcaml: global val %s: float literal %g out of \
                        Q16.16 range" name f);
                int_of_float scaled
            | _ ->
                failwith
                  (Printf.sprintf
                     "mcaml: global val %s: element is not an int/float \
                      literal (v1 supports constant literals only)" name)
          ) elems in
          Some (name, TArrStatic (elt_ty, List.length ints), ints)
      | Val (name, _) ->
          failwith
            (Printf.sprintf
               "mcaml: global val %s: RHS must be an array literal \
                `[| ... |]` in v1" name)
      | Fun _ | TypeDecl _ | RecordDecl _ -> None
    ) program
  in
  List.iter (fun (name, ty, ints) ->
    let aid = "__g_" ^ name in
    let length = List.length ints in
    Typing.register_global_val name ty;
    Knormal.register_global_array name aid length
  ) globals;
  globals

(* Phase 1a (E4): type every user-written Fun in source order —
   check bodies against declared/omitted return types and
   generalize signatures. Synthetic __for helpers are skipped as
   before (they reference enclosing locals); the tvar refs their
   params share with the enclosing def get constrained through
   their call sites during this pass. *)
let type_user_funs program =
  List.iter (function
    | Fun (name, params, ret, body)
      when not (For_lift.is_synthetic_name name) ->
        Typing.type_fun_def name params ret body
    | _ -> ()
  ) program

(* Phase 1b (E6): zonk every def — residual tvars are bound to TInt
   (§13.10 decision 5) — so knormal and everything below see fully
   resolved, concrete typs. All typing (including for_lift's oracle)
   is complete by this point, so the destructive default cannot
   constrain anything retroactively. *)
let zonk_program program =
  List.map (function
    | Fun (name, params, ret, body) ->
        Fun (name,
             List.map (fun (n, t) -> (n, Typing.zonk_default t)) params,
             Typing.zonk_default ret, body)
    | d -> d) program

(* ---- Phase 1c: lower every Fun to a cfg_func ---- *)

let build_fn_table program
  : (string, Cfg.cfg_func) Hashtbl.t * string list =
  (* Pre-seed ref slots for the WHOLE program before any def is
     normalized: for_lift emits an inner loop's helper before the outer
     helper whose body binds the ref, so knormal's normalize-time
     registration alone misses refs read from a nested lifted loop. *)
  Knormal.seed_ref_env program;
  let fn_table : (string, Cfg.cfg_func) Hashtbl.t = Hashtbl.create 16 in
  let fn_order : string list ref = ref [] in
  List.iter (fun def ->
    match def with
    | Val _ | TypeDecl _ | RecordDecl _ -> ()
    | Fun (name, _, _, _) ->
        (match Codegen.compile_def_to_cfg def with
         | None -> ()
         | Some cfg ->
             Hashtbl.replace fn_table name cfg;
             fn_order := name :: !fn_order)
  ) program;
  (fn_table, List.rev !fn_order)

(* ---- Phase 2: whole-program passes over the function table ---- *)

let run_whole_program_passes fn_table =
  (* Phase 2a: leaf inliner. Disable with MCAML_NO_INLINE=1 (or the
     MCAML_O0=1 umbrella) for A/B measurement. *)
  let no_inline = Cfg.pass_disabled "MCAML_NO_INLINE" in
  if not no_inline then Inline.run fn_table;

  (* Phase F3+F4: closure escape analysis + specialization. Sits
     between Inline.run and Monomorphize.run per §13.12 decision 3 —
     needs the same post-inline whole-program visibility the inliner
     itself needs. Mutates fn_table in place (may add clones); any
     new entries are picked up by the same extra_names diff in
     [extend_fn_order] that already generically covers Monomorphize's
     own clones, so no separate fn_order plumbing is needed here. *)
  let no_closure_spec = Cfg.pass_disabled "MCAML_NO_CLOSURE_SPEC" in
  if not no_closure_spec then Closure_spec.run fn_table;

  (* Phase 2b: monomorphize array-parameterized templates. After this
     the table still contains the templates but they're marked
     is_template=true and skipped during emit. *)
  Monomorphize.run fn_table;

  (* Phase F5: whole-program closure-shape table. Computed right after
     Closure_spec.run per §13.12 decision 5's own framing ("after F3's
     whole-program escape analysis has enumerated every Escaping
     closure shape") — every IClosureMake still in fn_table at this
     point is either genuinely Escaping or budget-exceeded; Known
     instances were already rewritten away above. Empty (zero codes)
     on any program with no closures at all — every downstream
     consumer treats that as a no-op, so canary programs are
     unaffected.

     MUST run AFTER Monomorphize.run, not before (this used to run
     before, on the stated belief that "monomorphize never touches
     TFun/closure machinery" made the ordering immaterial — that
     belief was wrong and caused a real bug: [Closure_layout.compute]
     skips [is_template] functions when scanning for [IClosureMake],
     but [is_template] is set purely from a function's OWN params
     having an array/matrix type, independent of whether a closure is
     lexically constructed inside its body. A function that merely
     takes an array parameter AND happens to also build an unrelated
     closure (one that captures no array at all) was a template at
     the old pre-Monomorphize call site, so its [IClosureMake] was
     invisible to the shape table — then Monomorphize cloned it into
     concrete, non-template copies whose inherited [IClosureMake] was
     never registered, and codegen_cfg's [Closure_layout.code_of]
     crashed with "has no assigned code" on every such clone. Running
     this after Monomorphize means every surviving non-template
     function (originals AND clones) gets scanned, so no
     array-parameterized function can hide a closure from this table
     again. Still safely before Phase 3 (regalloc/codegen/DCE), so
     the existing "deliberately NOT computed post-DCE" reasoning
     below is unaffected by this move — that concern is entirely
     about Optimize.run's placement, a different pass. *)
  let closure_layout = Closure_layout.compute fn_table in
  Cost.k_max_captured := closure_layout.Closure_layout.k_max_captured;

  (* Deliberately NOT computed post-DCE (a tempting-looking refinement
     that would let a program whose lambdas are all Known emit zero
     apply/apply_dispatch_<N> files instead of a few harmless dead
     ones): DCE only happens per-function inside Optimize.run, which
     main.ml's Phase 3 loop runs interleaved with regalloc/codegen one
     function at a time via Codegen.compile_cfg_to_files. Pulling
     Optimize.run out into a separate whole-table pre-pass (so this
     table could be computed from a post-DCE snapshot) was tried and
     reverted — it changed unroll.ml's cross-function caller-constant
     resolution timing enough to make scripts/test_arr_set.mcaml (one
     of the five canaries) unroll differently, a real behavior change
     for a program that doesn't even use closures. Per §13's own
     escalation trigger ("an existing test changes its output or
     command count"), that risk isn't worth taking for a purely
     cosmetic win. The accepted cost: a handful of dead
     (unreachable-but-emitted) apply_dispatch_<N> files can appear for
     an all-Known-lambda program — harmless, since the actual compiled
     function bodies still contain zero apply-dispatch references
     either way (F3+F4's zero-cost claim is about what a Known
     closure's OWN call sites compile to, not about whether some other,
     unrelated Escaping shape elsewhere in the same program leaves a
     same-named dead file behind). *)
  closure_layout

(* Extend fn_order with any clones that monomorphize added. *)
let extend_fn_order fn_table fn_order =
  let extra_names =
    Hashtbl.fold (fun k _ acc ->
      if List.mem k fn_order then acc else k :: acc) fn_table []
  in
  fn_order @ List.rev extra_names

(* ---- read-only dump hooks ---- *)

(* M4 §10 stage 1: optional read-only dump of dominators + loops
   per non-template cfg, before any Phase 3 mutation. *)
let run_dump_hooks fn_table fn_order =
  if dump_loops then
    List.iter (fun name ->
      let cfg = Hashtbl.find fn_table name in
      if cfg.Cfg.is_template then () else begin
        let idom = Dominators.compute cfg in
        let loops = Loop_detect.find_loops cfg idom in
        Printf.eprintf "=== loops in %s ===\n" name;
        Printf.eprintf "%s" (Dominators.dump cfg idom);
        Printf.eprintf "%s%!" (Loop_detect.dump_loops loops)
      end
    ) fn_order;

  if dump_iv then
    List.iter (fun name ->
      let cfg = Hashtbl.find fn_table name in
      if cfg.Cfg.is_template then () else begin
        let table = Strength_reduce.analyze cfg in
        Printf.eprintf "%s%!" (Strength_reduce.dump cfg table)
      end
    ) fn_order

(* ---- Phase A: entry-point + dynamic-heap analysis ---- *)

(* KNOWN, CONFIRMED, UNFIXED HAZARD (documented rather than rejected
   — see below for why a compiler-enforced check isn't safe to ship):
   a public entry P that makes an ordinary (non-tail) ICall — directly
   or transitively through other helper functions — into a function
   G with a self-tail loop is unsafe the moment G's loop actually
   needs to yield mid-run. Minecraft's `function` command returns
   control to the IMMEDIATE caller the instant the callee finishes
   OR executes an explicit `return`, and tick_guard's per-iteration
   budget guard does exactly that (`schedule ... 1t; return 0`) on
   every yield — NOT "the whole call chain unwinds," just one level.
   So P resumes immediately after its `function mcaml:G` line,
   reaches its own §4.4 end-of-invocation reset (appended
   unconditionally after P's last command, since P — not G, which
   `called_by_other` correctly marks non-public — is the one
   [is_public_entry] fires for), and wipes `mcaml:scratch`/
   `mcaml:objpool` while G's scheduled continuation is still
   mid-flight and depends on that exact state next tick. Confirmed
   by direct repro (2026-07-08): a wrapper plain-calling a self-tail
   darr-loop under a low MCAML_LOOP_ITER_LIMIT gets its heap wiped
   after the loop's FIRST partial run, then crashes resuming the
   scheduled continuation next tick.

   This is the exact hazard scripts/stress_test.mcaml's S8 comment
   documents finding and works around by making the self-tail loop
   itself the sole public entry (folding any one-time setup into an
   `i = 1` guard inside the loop) rather than introducing a
   wrapper — but that was only ever a per-test workaround, never a
   compiler guarantee.

   A compile-time rejection of "any public entry that can reach a
   self-tail function via ICall" was tried and reverted: EVERY
   self-tail loop gets tick_guard's yield machinery woven in
   unconditionally, regardless of whether it will ever actually
   iterate past the budget for realistic inputs (e.g.
   mc_test_suite.mcaml's `sum_list`, called from `run_all`, over
   lists far shorter than the default 1024-iteration budget) — so a
   blanket static rejection has no way to distinguish "structurally
   has a self-tail loop" from "will actually span multiple ticks
   for this program's real inputs" (a runtime-data-dependent
   question with no static bound anywhere in this compiler) and
   broke large amounts of legitimate, already-working code the
   moment it was tried.

   A runtime fix (a global "$tick_yielded" flag, set by tick_guard
   right before its yield and checked by the wrapper's reset) was
   also sketched and rejected: it correctly SKIPS the wrapper's
   premature reset on a yield, but then nothing ever fires the
   reset once G's OWN scheduled continuation later truly
   completes — that continuation re-enters via a direct scheduled
   call to G, never back through P, and G itself is not a public
   entry (something else calls it) so it carries no reset of its
   own either. The pool would simply never get reclaimed for that
   invocation rather than being corrupted — better than a crash,
   but still wrong, and building the "G must inherit a reset ITS
   OWN true-completion path fires, once it's known to be
   reachable from a heap-using public entry" plumbing needed to
   close that gap is a real multi-file architecture change, not a
   proportionate scope for a bug-hunting pass.

   Net: no compiler-level fix ships for this in v1. Follow
   stress_test.mcaml's S8 pattern — fold any one-time setup into
   the self-tail function itself (guarded on the first iteration)
   so it is the sole public entry — for any program where the
   self-tail loop might realistically span more than one tick's
   iteration budget. *)

(* Phase A / A9: compute the public-entry set and the any-dyn-heap
   flag before Phase 3 fires. A non-template function is "public"
   iff no other non-template function calls it via ICall. The flag
   gates reset emission so static-only programs stay byte-identical
   against the pre-Phase-A baseline — reset is a no-op when no
   IHeap* ever fires. Returns (any_dyn_heap_use, is_public_entry). *)
let compute_entry_info fn_table closure_layout
  : bool * (string -> bool) =
  let called_by_other : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let any_dyn_heap_use = ref false in
  Hashtbl.iter (fun _ (cfg : Cfg.cfg_func) ->
    if not cfg.Cfg.is_template then
      Array.iter (fun (b : Cfg.block) ->
        List.iter (fun instr ->
          (match instr with
           | Cfg.ICall (_, f, _) -> Hashtbl.replace called_by_other f ()
           | Cfg.IHeapAllocConst _ | Cfg.IHeapAlloc _
           | Cfg.IHeapGet _ | Cfg.IHeapSet _
           (* Phase B: cons ops also consume dynamic memory (the
              objpool), so a cons-only program still needs the
              end-of-invocation arena reset. *)
           | Cfg.ICons _ | Cfg.IHead _ | Cfg.ITail _
           (* Phase D: ADT cells also live in the objpool, so an
              ADT-only program still needs the end-of-invocation
              arena reset. *)
           | Cfg.IAdtAlloc _ | Cfg.ITagGet _ | Cfg.IFieldGet _ ->
               any_dyn_heap_use := true
           | _ -> ())
        ) b.Cfg.instrs
      ) cfg.Cfg.blocks
  ) fn_table;
  let is_public_entry (name : string) : bool =
    match Hashtbl.find_opt fn_table name with
    | Some cfg when not cfg.Cfg.is_template ->
        (* A lambda-lifted helper reachable only via the closure
           apply-dispatch trampoline (F5) is invoked through
           `IApply` -> `mcaml:apply` -> `apply_dispatch_N` ->
           `return run function mcaml:<helper>`, a call edge that
           lives in generated command STRINGS, not in any `ICall`
           the `called_by_other` walk above can see. Without this
           exclusion such a helper is (wrongly) treated as an
           orphan public entry and gets the §4.4 reset epilogue
           appended, wiping mcaml:objpool/scratch mid-invocation
           the moment the SAME closure (or any other live heap
           handle) is used again after that call returns. Mirrors
           the existing reasoning for TFun-typed functions never
           being externally invocable (F3+F4): a closure helper is
           a genuine public entry only if nothing in the program
           ever constructs a closure over it. *)
        not (Hashtbl.mem called_by_other name)
        && not (Hashtbl.mem closure_layout.Closure_layout.shapes name)
    | _ -> false
  in
  (* Phase C decision #5. Region save slots [$region_save_<k>_*] are
     global scoreboard, indexed by lexical depth. Two region-containing
     functions on the same call chain would both bump their own k=0,
     clobbering each other's saved bump-counter values — the enclosing
     function's region exit would then truncate back to the callee's
     save mark instead of its own, leaking memory. v1 sidesteps this
     by requiring that any function containing a region block is a
     public entry point: public entries are by definition not reachable
     from another function's body, so save-slot collisions can't arise.
     Lift path: save/restore region save slots across non-leaf calls
     via mcaml:stk frames; not worth it for v1. *)
  Hashtbl.iter (fun name (cfg : Cfg.cfg_func) ->
    if not cfg.Cfg.is_template then begin
      let contains_region =
        Array.exists (fun (b : Cfg.block) ->
          List.exists (fun i ->
            match i with
            | Cfg.IRegionEnter _ | Cfg.IRegionExit _ -> true
            | _ -> false) b.Cfg.instrs) cfg.Cfg.blocks
      in
      if contains_region && Hashtbl.mem called_by_other name then
        failwith
          (Printf.sprintf
             "mcaml: function %s contains a region block but is called \
              by another function; regions are only permitted in \
              public-entry-point functions in v1 (DYNMEM_PLAN §C5)"
             name)
    end) fn_table;
  (!any_dyn_heap_use, is_public_entry)

(* Reset block from DYNMEM_PLAN.md §4.4. permheap is intentionally
   excluded — it persists across invocations by design. *)
let reset_cmds = [
  "data modify storage mcaml:scratch cells set value []";
  "scoreboard players set $scratch_next vars 0";
  "data modify storage mcaml:objpool cells set value []";
  "scoreboard players set $objpool_next vars 0";
]

(* Target: the body file if LICM split fired (else the main file).
   Append must happen before tick_split so reset commands ride into
   the terminal __cont slice naturally. *)
let append_reset (name : string)
    (files : (string * string list) list)
    : (string * string list) list =
  let target = Tick_guard.entry_file_name files name in
  List.map (fun (f, cmds) ->
    if f = target then (f, cmds @ reset_cmds) else (f, cmds)
  ) files

(* ---- Phase 3: optimize, regalloc, codegen ---- *)

(* Only count reachable blocks: the unroller replaces a
   TTail-terminated body with cloned per-iteration blocks and
   redirects the header to the first iteration, but leaves the
   original body block in place with its TTail terminator intact
   and an empty preds list. Scanning every block would see that
   stale TTail and mark the function as "still a self-loop",
   causing tick_guard to prepend a budget guard to a function that
   has no runtime self-recursion at all. The result: every call to
   the unrolled helper bumps $tick_iters and can yield via
   `schedule ... 1t ; return 0`, corrupting any caller that
   depended on the unrolled body running to completion.
   [Cfg.block_is_reachable] is codegen_cfg's emission gate. *)
let has_self_tail (cfg : Cfg.cfg_func) : bool =
  Array.exists
    (fun b ->
      Cfg.block_is_reachable cfg b
      && (match b.Cfg.term with
          | Cfg.TTail (f, _) when f = cfg.Cfg.fname -> true
          | _ -> false))
    cfg.Cfg.blocks

(* MCAML_DUMP_COSTS reporting for one function's emitted files. *)
let report_costs name (cfg : Cfg.cfg_func)
    (files : (string * string list) list) : unit =
  let est = Cost.estimate_func cfg in
  let body_name = name ^ "__body" in
  let own_actual =
    List.fold_left (fun acc (fname, cmds) ->
      if fname = name || fname = body_name
      then acc + List.length cmds else acc) 0 files
  in
  let drift =
    if own_actual = 0 then 0.0
    else
      float_of_int (est - own_actual)
      /. float_of_int own_actual *. 100.0
  in
  Printf.eprintf
    "[cost] %s: estimate=%d own_actual=%d drift=%+.1f%%\n"
    name est own_actual drift;
  List.iter (fun (fname, cmds) ->
    let tag =
      if fname = name || fname = body_name then "main "
      else "help " in
    Printf.eprintf "[cost]   %s%s.mcfunction: %d lines\n"
      tag fname (List.length cmds)
  ) files

(* MCAML_DUMP_CFG reporting for one function's post-regalloc CFG. *)
let report_cfg name (cfg : Cfg.cfg_func)
    (files : (string * string list) list) : unit =
  Printf.eprintf "--- CFG dump for %s (post-regalloc) ---\n" name;
  Printf.eprintf "%s" (Cfg.dump_func cfg);
  List.iter (fun (fname, cmds) ->
    Printf.eprintf "=== %s.mcfunction ===\n" fname;
    List.iter (fun c -> Printf.eprintf "  %s\n" c) cmds) files;
  Printf.eprintf "---\n%!"

(* Phase 3: optimize, regalloc, codegen. Accumulate files first so
   Phase 4 (tick-split) can see the full program before anything
   hits disk. Alongside the files, collect the names of every
   function that is its own self-tail-call target — those need a
   tick guard prepended in Phase 5. Returns (all_files, guarded_funs)
   in emission order. *)
let emit_functions ~fn_table ~closure_layout ~fn_order
    ~any_dyn_heap_use ~is_public_entry
  : (string * string list) list * (string * int) list =
  let all_files : (string * string list) list ref = ref [] in
  (* Each entry is (function_name, per_iter_body_cost_in_commands).
     Tick_guard uses the cost to compute a per-loop iteration limit
     so the generated chain stays under MCAML_TICK_COMMANDS per tick. *)
  let guarded_funs : (string * int) list ref = ref [] in
  List.iter (fun name ->
    let cfg = Hashtbl.find fn_table name in
    if cfg.Cfg.is_template then () else
    let files = Codegen.compile_cfg_to_files ~fn_table ~closure_layout cfg in
    let files =
      if any_dyn_heap_use && is_public_entry name
      then append_reset name files
      else files
    in
    let files =
      if has_self_tail cfg then begin
        (* Per-iter cost = the body of the loop as lowered to commands,
           i.e. the reachable blocks of the CFG plus their terminator.
           Excludes the LICM preheader (which runs once at entry, not
           per iteration) and the wrapper's dispatch line. Matches
           what Tick_guard's [entry_file_name] targets. *)
        let body_cost =
          Array.fold_left (fun acc b ->
            if Cfg.block_is_reachable cfg b then acc + Cost.estimate_block b
            else acc)
            0 cfg.Cfg.blocks
        in
        guarded_funs := (name, body_cost) :: !guarded_funs;
        (* Stale-counter fix: append the $tick_iters reset to the tail
           of the guarded entry file so it fires exactly once, on the
           natural-exit frame (iterations leave early via `return run`,
           yields via `return 0`). Appended pre-tick_split, like
           [append_reset], so it rides into the terminal __cont slice.
           Skipped when tick_guard itself is disabled — no guard, no
           counter to reset. *)
        if Tick_guard.disabled () then files
        else begin
          let target = Tick_guard.entry_file_name files name in
          let reset = Tick_guard.reset_cmd ~target_fname:target in
          List.map (fun (f, cmds) ->
            if f = target then (f, cmds @ [reset]) else (f, cmds)) files
        end
      end else files
    in
    if dump_costs then report_costs name cfg files;
    if dump_cfg then report_cfg name cfg files;
    all_files := !all_files @ files
  ) fn_order;
  (!all_files, List.rev !guarded_funs)

(* ---- runtime-file synthesis ---- *)

(* Phase G: synthesize __globals_init.mcfunction with one
   `data modify storage mcaml:heap __g_<name> set value [...]` line
   per global val. Only emitted when the program has at least one
   val, so canary byte-diffs on programs without globals are
   unaffected. *)
let globals_init_files globals : (string * string list) list =
  if globals = [] then []
  else
    let cmds =
      List.map (fun (name, _ty, ints) ->
        Codegen_helpers.cmd_arr_lit_const ("__g_" ^ name) ints
      ) globals
    in
    [("__globals_init", cmds)]

(* Phase F5: shared apply-dispatch runtime. Emitted once per program
   (not per function) iff at least one closure shape survived
   Closure_spec.run — programs with no closures get zero new files,
   so canary byte-diffs are unaffected. [apply.mcfunction] is the
   whole-program $code dispatch chain (§13.12 decision 2: one shared
   function, not one per call-site shape); each
   [apply_dispatch_<code>.mcfunction] is that shape's env-unpack
   trampoline (decision 3). *)
let apply_dispatch_files closure_layout : (string * string list) list =
  if Array.length closure_layout.Closure_layout.by_code = 0 then []
  else begin
    let shapes = Array.to_list closure_layout.Closure_layout.by_code in
    let codes = List.map (fun s -> s.Closure_layout.code) shapes in
    let apply_file = ("apply", Codegen_helpers.apply_dispatch_body codes) in
    let trampolines =
      List.map (fun s ->
        (Printf.sprintf "apply_dispatch_%d" s.Closure_layout.code,
         Codegen_helpers.apply_dispatch_trampoline_body
           s.Closure_layout.n_captured s.Closure_layout.n_args
           s.Closure_layout.fname))
        shapes
    in
    apply_file :: trampolines
  end

(* ---- Phase 4/5 post-passes + write ---- *)

(* Phase 4: tick-split straight-line overflows into __cont<N> chains
   (plan §1.4). Helper files (_call<N>, _get) are preserved
   unchanged — see tick_split.ml for the safety argument.

   Phase 5: tick-guard insertion (plan §1.6). Prepends a per-iteration
   tick budget guard to the entry file of every TCO'd self-recursive
   function. Runs after the splitter so the guard's commands don't get
   counted against the straight-line budget. *)
let split_and_guard all_files guarded_funs
  : (string * string list) list =
  let split_files =
    if no_tick_split then all_files
    else Tick_split.run all_files
  in
  Tick_guard.run ~guarded:guarded_funs split_files

(* Phase A: dedupe by filename (keep first occurrence). Shared dyn-heap
   macro helpers (scratch_get, scratch_set, …) are appended by every
   codegen_cfg.emit call that uses them, so a program with N functions
   touching the dyn heap would otherwise produce N byte-identical
   copies. Existing helper files (_call<N>, <aid>_get) already have
   function-unique names so this is a no-op on the static path. *)
let dedupe_files final_files : (string * string list) list =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  List.filter (fun (fname, _) ->
    if Hashtbl.mem seen fname then false
    else (Hashtbl.add seen fname (); true)
  ) final_files

let write_files out_dir final_files : unit =
  List.iter (fun (fname, cmds) ->
    let filename = Filename.concat out_dir (fname ^ ".mcfunction") in
    let oc = open_out filename in
    List.iter (fun c -> Printf.fprintf oc "%s\n" c) cmds;
    close_out oc;
    Printf.printf "Generated %s\n" filename
  ) final_files

(* ---- driver ---- *)

let () =
  let out_dir = parse_out_dir () in
  ensure_dir out_dir;
  try
    (* Pre-lex include splicing (`include "path"` lines). Inside the
       try so a missing include file exits 2 via the Failure arm like
       every other rejection. Relative paths resolve against the cwd
       for the stdin program itself, then against each including
       file's own directory below. *)
    let source = Source_include.expand (In_channel.input_all stdin) in
    let lexbuf = Lexing.from_string source in
    let program = Parser.prog Lexer.read lexbuf in
    check_reserved_names program;

    (* Alpha-rename once up front so for_lift sees globally-unique binders. *)
    let program = List.map (Alpha.h Alpha.M.empty) program in
    register_type_decls program;

    (* Desugar explicit partial application (`let g = add(1)`) into
       let-temps + a lambda BEFORE for_lift, which closure-converts
       the synthesized Lambda like any user-written one. *)
    let program = Partial_app.run program in

    (* Hoist every `for` loop into its own top-level tail-recursive helper. *)
    let program = For_lift.run program in

    (* Build the global function-signature table for typing's App rule. *)
    Typing.build_sigs program;

    let globals = collect_globals program in
    type_user_funs program;
    let program = zonk_program program in

    let fn_table, fn_order = build_fn_table program in
    let closure_layout = run_whole_program_passes fn_table in
    let fn_order = extend_fn_order fn_table fn_order in
    run_dump_hooks fn_table fn_order;

    (* Dead-val elimination (TODO.md): post-inline/monomorphize (so
       clones' concrete aids are visible), pre-Phase 3. Drops
       unreferenced vals from __globals_init and static-only vals'
       over-emitted `__g_<name>_get` macro files. MCAML_NO_DEADVAL=1
       (or the MCAML_O0 umbrella) keeps every val, e.g. for manual
       in-game LUT inspection. *)
    let no_deadval = Cfg.pass_disabled "MCAML_NO_DEADVAL" in
    let globals, dead_get_filter =
      if no_deadval then globals, (fun files -> files)
      else begin
        let referenced, dyn_read = Deadval.collect_refs fn_table in
        (Deadval.filter_globals referenced globals,
         Deadval.drop_dead_get_files dyn_read)
      end
    in

    let any_dyn_heap_use, is_public_entry =
      compute_entry_info fn_table closure_layout in
    let all_files, guarded_funs =
      emit_functions ~fn_table ~closure_layout ~fn_order
        ~any_dyn_heap_use ~is_public_entry
    in
    let all_files = dead_get_filter all_files in

    (* F6a: per-lambda specialize/escape report, once every function has
       been through Phase 3 (so [Closure_spec.check_hot_loop]'s hot-loop
       annotations, filled in per-function above, are complete). Always
       on; a lambda-free program never populates the report table, so
       this prints nothing. *)
    Closure_spec.print_report ();

    let all_files = all_files @ globals_init_files globals in
    let all_files = all_files @ apply_dispatch_files closure_layout in

    let final_files = split_and_guard all_files guarded_funs in
    let final_files = dedupe_files final_files in
    write_files out_dir final_files
  with
  | Lexer.SyntaxError m -> Printf.eprintf "Lexer: %s\n" m; exit 2
  | Typing.Error m -> Printf.eprintf "Type Error: %s\n" m; exit 2
  | Parser.Error -> Printf.eprintf "Parser Error\n"; exit 2
  (* Internal pipeline errors (reserved names, unsupported v1 shapes,
     codegen invariant violations) are raised with [failwith]. Without
     this arm they still exit nonzero (OCaml's uncaught-exception exit
     is 2) but print a "Fatal error: exception Failure(...)" backtrace
     line; catch them for a clean one-line message and the same code. *)
  | Failure m -> Printf.eprintf "%s\n" m; exit 2
