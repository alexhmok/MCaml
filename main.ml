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
    let globals : (string * int list) list =
      List.filter_map (fun d ->
        match d with
        | Val (name, Array elems) ->
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
            Some (name, ints)
        | Val (name, _) ->
            failwith
              (Printf.sprintf
                 "mcaml: global val %s: RHS must be an array literal \
                  `[| ... |]` in v1" name)
        | Fun _ -> None
      ) program
    in
    List.iter (fun (name, ints) ->
      let aid = "__g_" ^ name in
      let length = List.length ints in
      (* Typing: expose the val to every function as TArrStatic TInt n
         — the surface does not distinguish int-encoded and float-
         encoded arrays at this layer (both are 32-bit scoreboard ints
         per §12.1), so TArrStatic TInt is the honest type. *)
      Typing.register_global_val name (TArrStatic (TInt, length));
      (* knormal: register the stable aid so Index1/Index2 on the val
         lower through the existing static-array machinery with the
         global aid. *)
      Knormal.register_global_array name aid length
    ) globals;

    (* Phase 1: lower every Fun to a cfg_func. *)
    let fn_table : (string, Cfg.cfg_func) Hashtbl.t = Hashtbl.create 16 in
    let fn_order : string list ref = ref [] in
    List.iter (fun def ->
      match def with
      | Val _ -> ()
      | Fun (name, params, _, body) ->
          if not (For_lift.is_synthetic_name name) then begin
            let type_env = List.map (fun (n, t) -> (n, t)) params in
            let _ = Typing.infer type_env body in ()
          end;
          (match Codegen.compile_def_to_cfg def with
           | None -> ()
           | Some cfg ->
               Hashtbl.replace fn_table name cfg;
               fn_order := name :: !fn_order)
    ) program;
    let fn_order = List.rev !fn_order in

    (* Phase 2a: leaf inliner. Disable with MCAML_NO_INLINE=1 for A/B measurement. *)
    let no_inline = try Sys.getenv "MCAML_NO_INLINE" = "1" with Not_found -> false in
    if not no_inline then Inline.run fn_table;

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
                conspool), so a cons-only program still needs the
                end-of-invocation arena reset. *)
             | Cfg.ICons _ | Cfg.IHead _ | Cfg.ITail _ ->
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
      "data modify storage mcaml:conspool pairs set value []";
      "scoreboard players set $conspool_next vars 0";
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
    let guarded_funs : string list ref = ref [] in
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
      let files = Codegen.compile_cfg_to_files ~fn_table cfg in
      let files =
        if !any_dyn_heap_use && is_public_entry name
        then append_reset name files
        else files
      in
      if has_self_tail cfg then guarded_funs := name :: !guarded_funs;
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
         List.map (fun (name, ints) ->
           Codegen_helpers.cmd_arr_lit_const ("__g_" ^ name) ints
         ) globals
       in
       all_files := !all_files @ [("__globals_init", cmds)]);

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
