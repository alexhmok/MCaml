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

let () =
  let out_dir = parse_out_dir () in
  ensure_dir out_dir;
  let lexbuf = Lexing.from_channel stdin in
  try
    let program = Parser.prog Lexer.read lexbuf in

    (* Reserve names the datapack packager synthesizes (tools/pack_datapack.py).
       `init.mcfunction` is minted at packaging time and wired to
       #minecraft:load; a user-defined `init` would silently clobber it. *)
    List.iter (function
      | Fun ("init", _, _, _) ->
          failwith "mcaml: function name 'init' is reserved by the datapack packager"
      | _ -> ()
    ) program;

    (* Alpha-rename once up front so for_lift sees globally-unique binders. *)
    let program = List.map (Alpha.h Alpha.M.empty) program in

    (* Phase D: register type declarations in source order BEFORE
       for_lift runs — for_lift's walk consults Typing.infer for Let
       RHS types, which needs the ctor environment populated. Source
       order means a type must be declared before first use (no
       forward references between type declarations in v1). *)
    List.iter (function
      | TypeDecl (name, params, ctors) ->
          Typing.register_type_decl name params ctors
      | RecordDecl (name, fields) -> Typing.register_record_decl name fields
      | _ -> ()
    ) program;

    (* Hoist every `for` loop into its own top-level tail-recursive helper. *)
    let program = For_lift.run program in

    (* Build the global function-signature table for typing's App rule. *)
    Typing.build_sigs program;

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

    (* Phase 1a (E4): type every user-written Fun in source order —
       check bodies against declared/omitted return types and
       generalize signatures. Synthetic __for helpers are skipped as
       before (they reference enclosing locals); the tvar refs their
       params share with the enclosing def get constrained through
       their call sites during this pass. *)
    List.iter (function
      | Fun (name, params, ret, body)
        when not (For_lift.is_synthetic_name name) ->
          Typing.type_fun_def name params ret body
      | _ -> ()
    ) program;

    (* Phase 1b (E6): zonk every def — residual tvars are bound to TInt
       (§13.10 decision 5) — so knormal and everything below see fully
       resolved, concrete typs. All typing (including for_lift's oracle)
       is complete by this point, so the destructive default cannot
       constrain anything retroactively. *)
    let program =
      List.map (function
        | Fun (name, params, ret, body) ->
            Fun (name,
                 List.map (fun (n, t) -> (n, Typing.zonk_default t)) params,
                 Typing.zonk_default ret, body)
        | d -> d) program
    in

    (* Phase 1c: lower every Fun to a cfg_func. *)
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
    let fn_order = List.rev !fn_order in

    (* Phase 2a: leaf inliner. Disable with MCAML_NO_INLINE=1 (or the
       MCAML_O0=1 umbrella) for A/B measurement. *)
    let no_inline = Cfg.pass_disabled "MCAML_NO_INLINE" in
    if not no_inline then Inline.run fn_table;

    (* Phase F3+F4: closure escape analysis + specialization. Sits
       between Inline.run and Monomorphize.run per §13.12 decision 3 —
       needs the same post-inline whole-program visibility the inliner
       itself needs. Mutates fn_table in place (may add clones); any
       new entries are picked up by the same extra_names diff below
       that already generically covers Monomorphize's own clones, so
       no separate fn_order plumbing is needed here. *)
    let no_closure_spec = Cfg.pass_disabled "MCAML_NO_CLOSURE_SPEC" in
    if not no_closure_spec then Closure_spec.run fn_table;

    (* Phase F5: whole-program closure-shape table. Computed right after
       Closure_spec.run per §13.12 decision 5's own framing ("after F3's
       whole-program escape analysis has enumerated every Escaping
       closure shape") — every IClosureMake still in fn_table at this
       point is either genuinely Escaping or budget-exceeded; Known
       instances were already rewritten away above. Ordering relative to
       Monomorphize.run below doesn't matter (monomorphize never touches
       TFun/closure machinery, decision 3). Empty (zero codes) on any
       program with no closures at all — every downstream consumer treats
       that as a no-op, so canary programs are unaffected.

       Deliberately NOT computed post-DCE (a tempting-looking refinement
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
    let closure_layout = Closure_layout.compute fn_table in
    Cost.k_max_captured := closure_layout.Closure_layout.k_max_captured;

    (* Phase 2b: monomorphize array-parameterized templates. After this
       the table still contains the templates but they're marked
       is_template=true and skipped during emit. *)
    Monomorphize.run fn_table;

    (* Extend fn_order with any clones that monomorphize added. *)
    let extra_names =
      Hashtbl.fold (fun k _ acc ->
        if List.mem k fn_order then acc else k :: acc) fn_table []
    in
    let fn_order = fn_order @ List.rev extra_names in

    (* M4 §10 stage 1: optional read-only dump of dominators + loops
       per non-template cfg, before any Phase 3 mutation. *)
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
      ) fn_order;

    (* Phase A / A9: compute the public-entry set and the any-dyn-heap
       flag before Phase 3 fires. A non-template function is "public"
       iff no other non-template function calls it via ICall. The flag
       gates reset emission so static-only programs stay byte-identical
       against the pre-Phase-A baseline — reset is a no-op when no
       IHeap* ever fires. *)
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
          not (Hashtbl.mem called_by_other name)
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
    (* Reset block from DYNMEM_PLAN.md §4.4. permheap is intentionally
       excluded — it persists across invocations by design. *)
    let reset_cmds = [
      "data modify storage mcaml:scratch cells set value []";
      "scoreboard players set $scratch_next vars 0";
      "data modify storage mcaml:objpool cells set value []";
      "scoreboard players set $objpool_next vars 0";
    ] in
    (* Target: the body file if LICM split fired (else the main file).
       Append must happen before tick_split so reset commands ride into
       the terminal __cont slice naturally. *)
    let append_reset (name : string)
        (files : (string * string list) list)
        : (string * string list) list =
      let body_name = name ^ "__body" in
      let has_body = List.exists (fun (f, _) -> f = body_name) files in
      let target = if has_body then body_name else name in
      List.map (fun (f, cmds) ->
        if f = target then (f, cmds @ reset_cmds) else (f, cmds)
      ) files
    in

    (* Phase 3: optimize, regalloc, codegen. Accumulate files first so
       Phase 4 (tick-split) can see the full program before anything
       hits disk. Alongside the files, collect the names of every
       function that is its own self-tail-call target — those need a
       tick guard prepended in Phase 5. *)
    let all_files : (string * string list) list ref = ref [] in
    (* Each entry is (function_name, per_iter_body_cost_in_commands).
       Tick_guard uses the cost to compute a per-loop iteration limit
       so the generated chain stays under MCAML_TICK_COMMANDS per tick. *)
    let guarded_funs : (string * int) list ref = ref [] in
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
       [block_is_reachable] mirrors codegen_cfg.ml's emission gate. *)
    let block_is_reachable (cfg : Cfg.cfg_func) (b : Cfg.block) : bool =
      b.Cfg.label = cfg.Cfg.entry || b.Cfg.preds <> []
    in
    let has_self_tail (cfg : Cfg.cfg_func) : bool =
      Array.exists
        (fun b ->
          block_is_reachable cfg b
          && (match b.Cfg.term with
              | Cfg.TTail (f, _) when f = cfg.Cfg.fname -> true
              | _ -> false))
        cfg.Cfg.blocks
    in
    List.iter (fun name ->
      let cfg = Hashtbl.find fn_table name in
      if cfg.Cfg.is_template then () else
      let files = Codegen.compile_cfg_to_files ~fn_table ~closure_layout cfg in
      let files =
        if !any_dyn_heap_use && is_public_entry name
        then append_reset name files
        else files
      in
      if has_self_tail cfg then begin
        (* Per-iter cost = the body of the loop as lowered to commands,
           i.e. the reachable blocks of the CFG plus their terminator.
           Excludes the LICM preheader (which runs once at entry, not
           per iteration) and the wrapper's dispatch line. Matches
           what Tick_guard's [entry_file_name] targets. *)
        let body_cost =
          Array.fold_left (fun acc b ->
            if block_is_reachable cfg b then acc + Cost.estimate_block b
            else acc)
            0 cfg.Cfg.blocks
        in
        guarded_funs := (name, body_cost) :: !guarded_funs
      end;
      if dump_costs then begin
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
      end;
      if dump_cfg then begin
        Printf.eprintf "--- CFG dump for %s (post-regalloc) ---\n" name;
        Printf.eprintf "%s" (Cfg.dump_func cfg);
        List.iter (fun (fname, cmds) ->
          Printf.eprintf "=== %s.mcfunction ===\n" fname;
          List.iter (fun c -> Printf.eprintf "  %s\n" c) cmds) files;
        Printf.eprintf "---\n%!"
      end;
      all_files := !all_files @ files
    ) fn_order;

    (* Phase G: synthesize __globals_init.mcfunction with one
       `data modify storage mcaml:heap __g_<name> set value [...]` line
       per global val. Only emitted when the program has at least one
       val, so canary byte-diffs on programs without globals are
       unaffected. *)
    (if globals <> [] then
       let cmds =
         List.map (fun (name, _ty, ints) ->
           Codegen_helpers.cmd_arr_lit_const ("__g_" ^ name) ints
         ) globals
       in
       all_files := !all_files @ [("__globals_init", cmds)]);

    (* Phase F5: shared apply-dispatch runtime. Emitted once per program
       (not per function) iff at least one closure shape survived
       Closure_spec.run — programs with no closures get zero new files,
       so canary byte-diffs are unaffected. [apply.mcfunction] is the
       whole-program $code dispatch chain (§13.12 decision 2: one shared
       function, not one per call-site shape); each
       [apply_dispatch_<code>.mcfunction] is that shape's env-unpack
       trampoline (decision 3). *)
    (if Array.length closure_layout.Closure_layout.by_code > 0 then begin
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
       all_files := !all_files @ (apply_file :: trampolines)
     end);

    (* Phase 4: tick-split straight-line overflows into __cont<N> chains
       (plan §1.4). Helper files (_call<N>, _get) are preserved
       unchanged — see tick_split.ml for the safety argument.

       Phase 5: tick-guard insertion (plan §1.6). Prepends a per-iteration
       tick budget guard to the entry file of every TCO'd self-recursive
       function. Runs after the splitter so the guard's commands don't get
       counted against the straight-line budget. *)
    let split_files =
      if no_tick_split then !all_files
      else Tick_split.run !all_files
    in
    let final_files =
      Tick_guard.run ~guarded:(List.rev !guarded_funs) split_files
    in

    (* Phase A: dedupe by filename (keep first occurrence). Shared dyn-heap
       macro helpers (scratch_get, scratch_set, …) are appended by every
       codegen_cfg.emit call that uses them, so a program with N functions
       touching the dyn heap would otherwise produce N byte-identical
       copies. Existing helper files (_call<N>, <aid>_get) already have
       function-unique names so this is a no-op on the static path. *)
    let final_files =
      let seen : (string, unit) Hashtbl.t = Hashtbl.create 32 in
      List.filter (fun (fname, _) ->
        if Hashtbl.mem seen fname then false
        else (Hashtbl.add seen fname (); true)
      ) final_files
    in
    List.iter (fun (fname, cmds) ->
      let filename = Filename.concat out_dir (fname ^ ".mcfunction") in
      let oc = open_out filename in
      List.iter (fun c -> Printf.fprintf oc "%s\n" c) cmds;
      close_out oc;
      Printf.printf "Generated %s\n" filename
    ) final_files
  with
  | Lexer.SyntaxError m -> Printf.eprintf "Lexer: %s\n" m
  | Typing.Error m -> Printf.eprintf "Type Error: %s\n" m
  | Parser.Error -> Printf.eprintf "Parser Error\n"
