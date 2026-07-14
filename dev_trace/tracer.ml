(* tracer.ml — pipeline X-ray. Mirrors main.ml's driver exactly
   (same call sequence, same pass order) but dumps the full IR at every
   stage boundary and after every optimizer pass that reports a change.

   MAINTENANCE: this duplicates main.ml's call sequence by hand. When a
   pass is added to main.ml, add it here too, or the trace silently
   diverges from what the compiler actually does (this happened once:
   partial_app + include splicing landed in main.ml without a tracer
   update).

   SCOPE: traces through Tick_guard.run. main.ml's driver-level file
   post-processing (globals-init/apply-dispatch synthesis, deadval
   filtering, tick-budget exit resets) is deliberately NOT mirrored —
   use ./mcaml's actual output for the final file set.

   Usage: dune build dev_trace/tracer.exe
          _build/default/dev_trace/tracer.exe < scripts/demos/walkthrough.mcaml *)

open Ast

let pf fmt = Printf.printf fmt

let banner s =
  pf "\n%s\n== %s\n%s\n" (String.make 74 '=') s (String.make 74 '=')

(* ---------------- typ / binop printers ---------------- *)

let rec s_typ (t : typ) : string =
  match t with
  | TInt -> "TInt" | TFloat -> "TFloat" | TBool -> "TBool" | TUnit -> "TUnit"
  | TSelector -> "TSelector" | TPos -> "TPos"
  | TArrStatic (t, n) -> Printf.sprintf "TArrStatic(%s, %d)" (s_typ t) n
  | TArrDyn t -> Printf.sprintf "TArrDyn(%s)" (s_typ t)
  | TMat (t, r, c) -> Printf.sprintf "TMat(%s, %d, %d)" (s_typ t) r c
  | TRef t -> Printf.sprintf "TRef(%s)" (s_typ t)
  | TList t -> Printf.sprintf "TList(%s)" (s_typ t)
  | TAdt (n, ts) ->
      Printf.sprintf "TAdt(%S, [%s])" n
        (String.concat "; " (List.map s_typ ts))
  | TTuple ts ->
      Printf.sprintf "TTuple[%s]" (String.concat "; " (List.map s_typ ts))
  | TVar r ->
      (match !r with
       | None -> "TVar ?"
       | Some t -> Printf.sprintf "TVar(:= %s)" (s_typ t))
  | TParam s -> Printf.sprintf "TParam %S" s
  | TFun (args, r) ->
      Printf.sprintf "TFun([%s], %s)"
        (String.concat "; " (List.map s_typ args)) (s_typ r)

let s_binop (op : binop) : string =
  match op with
  | Add -> "Add" | Sub -> "Sub" | Mult -> "Mult" | Div -> "Div" | Mod -> "Mod"
  | FAdd -> "FAdd" | FSub -> "FSub" | FMult -> "FMult" | FDiv -> "FDiv"
  | Eq -> "Eq" | Neq -> "Neq" | Lt -> "Lt" | Leq -> "Leq"
  | Gt -> "Gt" | Geq -> "Geq" | And -> "And" | Or -> "Or"

(* ---------------- AST expr printer (constructor tree) ---------------- *)

let rec s_expr (ind : int) (e : expr) : string =
  let child e = String.make (ind + 2) ' ' ^ s_expr (ind + 2) e in
  let children es = String.concat ",\n" (List.map child es) in
  match e with
  | Int n -> Printf.sprintf "Int %d" n
  | Float f -> Printf.sprintf "Float %g" f
  | Bool b -> Printf.sprintf "Bool %b" b
  | Str s -> Printf.sprintf "Str %S" s
  | Var v -> Printf.sprintf "Var %S" v
  | Unit -> "Unit"
  | Nil -> "Nil"
  | Selector s -> Printf.sprintf "Selector %S" s
  | Command c -> Printf.sprintf "Command %S" c
  | BinOp (op, a, b) ->
      Printf.sprintf "BinOp(%s,\n%s)" (s_binop op) (children [a; b])
  | Let (x, e1, e2) ->
      Printf.sprintf "Let(%S,\n%s)" x (children [e1; e2])
  | If (c, t, f) -> Printf.sprintf "If(\n%s)" (children [c; t; f])
  | App (f, args) ->
      if args = [] then Printf.sprintf "App(%S, [])" f
      else Printf.sprintf "App(%S,\n%s)" f (children args)
  | Seq (a, b) -> Printf.sprintf "Seq(\n%s)" (children [a; b])
  | Array es -> Printf.sprintf "Array [\n%s]" (children es)
  | Index1 (a, i) -> Printf.sprintf "Index1(\n%s)" (children [a; i])
  | Index2 (a, i, j) -> Printf.sprintf "Index2(\n%s)" (children [a; i; j])
  | IndexSet1 (a, i, v) ->
      Printf.sprintf "IndexSet1(\n%s)" (children [a; i; v])
  | IndexSet2 (a, i, j, v) ->
      Printf.sprintf "IndexSet2(\n%s)" (children [a; i; j; v])
  | Ref e -> Printf.sprintf "Ref(\n%s)" (children [e])
  | Deref e -> Printf.sprintf "Deref(\n%s)" (children [e])
  | RefSet (r, v) -> Printf.sprintf "RefSet(\n%s)" (children [r; v])
  | For (i, lo, hi, body) ->
      Printf.sprintf "For(%S,\n%s)" i (children [lo; hi; body])
  | Cons (h, t) -> Printf.sprintf "Cons(\n%s)" (children [h; t])
  | Tuple es -> Printf.sprintf "Tuple [\n%s]" (children es)
  | Lambda (params, body) ->
      Printf.sprintf "Lambda([%s],\n%s)"
        (String.concat "; "
           (List.map (fun (n, t) -> Printf.sprintf "(%S, %s)" n (s_typ t))
              params))
        (children [body])
  | Closure (f, es) -> Printf.sprintf "Closure(%S,\n%s)" f (children es)
  | Match _ -> "Match(<arms>)"
  | Record _ -> "Record(<fields>)"
  | Field (e, f) -> Printf.sprintf "Field(%S,\n%s)" f (children [e])
  | Region (_, e) -> Printf.sprintf "Region(\n%s)" (children [e])
  | Coord _ -> "Coord(...)"

let s_params ps =
  String.concat "; "
    (List.map (fun (n, t) -> Printf.sprintf "(%S, %s)" n (s_typ t)) ps)

let s_def (d : def) : string =
  match d with
  | Fun (name, params, ret, body) ->
      Printf.sprintf "Fun(%S,\n  params = [%s],\n  ret = %s,\n  body =\n    %s\n)"
        name (s_params params) (s_typ ret) (s_expr 4 body)
  | Val (n, e) -> Printf.sprintf "Val(%S,\n  %s)" n (s_expr 2 e)
  | TypeDecl (n, _, _) -> Printf.sprintf "TypeDecl(%S, ...)" n
  | RecordDecl (n, _) -> Printf.sprintf "RecordDecl(%S, ...)" n

let dump_program tag (prog : program) : unit =
  banner tag;
  List.iter (fun d -> pf "%s\n\n" (s_def d)) prog

(* ---------------- kexpr printer ---------------- *)

let rec s_k (ind : int) (k : Knormal.kexpr) : string =
  let open Knormal in
  let child k = String.make (ind + 2) ' ' ^ s_k (ind + 2) k in
  let children ks = String.concat ",\n" (List.map child ks) in
  let sl xs = String.concat "; " (List.map (Printf.sprintf "%S") xs) in
  match k with
  | KUnit -> "KUnit"
  | KInt n -> Printf.sprintf "KInt %d" n
  | KVar v -> Printf.sprintf "KVar %S" v
  | KStr s -> Printf.sprintf "KStr %S" s
  | KCommand c -> Printf.sprintf "KCommand %S" c
  | KBinOp (op, a, b) ->
      Printf.sprintf "KBinOp(%s, %S, %S)" (s_binop op) a b
  | KLet (x, k1, k2) -> Printf.sprintf "KLet(%S,\n%s)" x (children [k1; k2])
  | KIf (c, k1, k2) -> Printf.sprintf "KIf(%S,\n%s)" c (children [k1; k2])
  | KSeq (k1, k2) -> Printf.sprintf "KSeq(\n%s)" (children [k1; k2])
  | KCall (f, args) -> Printf.sprintf "KCall(%S, [%s])" f (sl args)
  | KLoop (f, args) -> Printf.sprintf "KLoop(%S, [%s])" f (sl args)
  | KArrLitConst (aid, ints) ->
      Printf.sprintf "KArrLitConst(%S, [%s])" aid
        (String.concat "; " (List.map string_of_int ints))
  | KArrLitDyn (aid, vs) -> Printf.sprintf "KArrLitDyn(%S, [%s])" aid (sl vs)
  | KArrGetStatic (a, b, i) ->
      Printf.sprintf "KArrGetStatic(%S, %S, %d)" a b i
  | KArrGet (a, b, c) -> Printf.sprintf "KArrGet(%S, %S, %S)" a b c
  | KArrSetStatic (a, i, v) ->
      Printf.sprintf "KArrSetStatic(%S, %d, %S)" a i v
  | KArrSet (a, i, v) -> Printf.sprintf "KArrSet(%S, %S, %S)" a i v
  | _ -> "<kexpr: dyn-heap/list/adt/closure node>"

(* ---------------- CFG helpers ---------------- *)

let dump_cfg tag (cfg : Cfg.cfg_func) : unit =
  pf "\n----- %s -----\n%s%!" tag (Cfg.dump_func cfg)

let dump_table tag (fn_table : (string, Cfg.cfg_func) Hashtbl.t)
    (order : string list) : unit =
  banner tag;
  List.iter (fun name ->
    match Hashtbl.find_opt fn_table name with
    | None -> ()
    | Some cfg ->
        pf "\n[%s] is_template=%b preheader=%d instr(s)\n%s"
          name cfg.Cfg.is_template
          (List.length cfg.Cfg.preheader_instrs)
          (Cfg.dump_func cfg)
  ) order

let table_order fn_table fn_order =
  let extra =
    Hashtbl.fold (fun k _ acc ->
      if List.mem k fn_order then acc else k :: acc) fn_table []
  in
  fn_order @ List.rev extra

(* ---------------- liveness dump ---------------- *)

let s_vset (s : Liveness.VSet.t) : string =
  String.concat ", " (Liveness.VSet.elements s)

let dump_liveness (cfg : Cfg.cfg_func) : unit =
  let lv = Liveness.analyze cfg in
  Array.iter (fun (b : Cfg.block) ->
    let l = b.Cfg.label in
    if Cfg.block_is_reachable cfg b then begin
      let bl = lv.Liveness.per_block.(l) in
      pf "  L%d: live_in={%s}  live_out={%s}\n"
        l (s_vset bl.Liveness.live_in) (s_vset bl.Liveness.live_out);
      let arr = lv.Liveness.per_instr.(l) in
      List.iteri (fun i ins ->
        pf "      %-44s live_after={%s}\n"
          (Cfg.string_of_instr ins) (s_vset arr.(i))
      ) b.Cfg.instrs
    end
  ) cfg.Cfg.blocks

(* ---------------- instrumented optimizer ---------------- *)

let m3a_instrumented (name : string) (sweep : string)
    (cfg : Cfg.cfg_func) : unit =
  let i = ref 0 and continue = ref true in
  while !continue && !i < 10 do
    incr i;
    let step pname pass =
      let changed = pass cfg in
      pf "  [%s] M3a %s, iteration %d: %-10s -> %s\n"
        name sweep !i pname (if changed then "CHANGED" else "no change");
      if changed then
        dump_cfg (Printf.sprintf "%s after %s (%s, iter %d)"
                    name pname sweep !i) cfg;
      changed
    in
    let c1 = step "const_fold" Const_fold.run in
    let c2 = step "copy_prop" Copy_prop.run in
    let c3 = step "local_cse" Local_cse.run in
    let c4 = step "dce" Dce.run in
    continue := c1 || c2 || c3 || c4
  done

let loop_pass_instrumented (name : string) fn_table
    (cfg : Cfg.cfg_func) : unit =
  let step pname changed =
    pf "  [%s] loop pass: %-16s -> %s\n"
      name pname (if changed then "CHANGED" else "no change");
    if changed then
      dump_cfg (Printf.sprintf "%s after %s" name pname) cfg
  in
  step "licm" (Licm.run cfg);
  step "strength_reduce" (Strength_reduce.run cfg);
  step "unroll" (Unroll.run fn_table cfg);
  step "sroa" (Sroa.run ~fn_table cfg)

(* ---------------- has_self_tail (mirrors main.ml) ---------------- *)

let has_self_tail (cfg : Cfg.cfg_func) : bool =
  Array.exists
    (fun b ->
      Cfg.block_is_reachable cfg b
      && (match b.Cfg.term with
          | Cfg.TTail (f, _) when f = cfg.Cfg.fname -> true
          | _ -> false))
    cfg.Cfg.blocks

let print_files tag (files : (string * string list) list) : unit =
  banner tag;
  List.iter (fun (f, cmds) ->
    pf "--- %s.mcfunction  (%d commands) ---\n" f (List.length cmds);
    List.iter (fun c -> pf "  %s\n" c) cmds;
    pf "\n"
  ) files

(* ---------------- driver (mirrors main.ml) ---------------- *)

let () =
  let source = Source_include.expand (In_channel.input_all stdin) in
  let lexbuf = Lexing.from_string source in
  let program = Parser.prog Lexer.read lexbuf in
  dump_program "STAGE 1: raw AST (include-spliced, Parser.prog Lexer.read)"
    program;

  let program = List.map (Alpha.h Alpha.M.empty) program in
  dump_program "STAGE 2: after Alpha.h (unique binders)" program;

  List.iter (function
    | TypeDecl (name, params, ctors) ->
        Typing.register_type_decl name params ctors
    | RecordDecl (name, fields) -> Typing.register_record_decl name fields
    | _ -> ()
  ) program;

  let program = Partial_app.run program in
  dump_program
    "STAGE 2b: after Partial_app.run (under-applied calls -> let-temps + lambda)"
    program;

  let program = For_lift.run program in
  dump_program "STAGE 3: after For_lift.run (loops -> tail-recursive helpers)"
    program;

  Typing.build_sigs program;

  (* Mirror main.ml's collect_globals registration (minus the file
     emission): top-level `val`s must be in Typing.global_vals and
     Knormal's global-array table before typing/knormal run. *)
  List.iter (function
    | Val (name, Array elems) ->
        let has_float =
          List.exists (fun e -> match e with Float _ -> true | _ -> false)
            elems
        in
        let elt_ty = if has_float then TFloat else TInt in
        Typing.register_global_val name
          (TArrStatic (elt_ty, List.length elems));
        Knormal.register_global_array name ("__g_" ^ name)
          (List.length elems)
    | _ -> ()
  ) program;

  List.iter (function
    | Fun (name, params, ret, body)
      when not (For_lift.is_synthetic_name name) ->
        Typing.type_fun_def name params ret body
    | _ -> ()
  ) program;
  let program =
    List.map (function
      | Fun (name, params, ret, body) ->
          Fun (name,
               List.map (fun (n, t) -> (n, Typing.zonk_default t)) params,
               Typing.zonk_default ret, body)
      | d -> d) program
  in
  banner "STAGE 4: typing — global fun_sigs table (post-zonk)";
  List.iter (function
    | Fun (name, _, _, _) ->
        (match Hashtbl.find_opt Typing.fun_sigs name with
         | Some (args, ret) ->
             pf "  %s : (%s) -> %s\n" name
               (String.concat ", " (List.map s_typ args)) (s_typ ret)
         | None -> pf "  %s : <no entry in fun_sigs>\n" name)
    | _ -> ()) program;

  (* Phase 1c: knormal -> tco -> cfg_build, per Fun, with dumps between. *)
  let fn_table : (string, Cfg.cfg_func) Hashtbl.t = Hashtbl.create 16 in
  let fn_order : string list ref = ref [] in
  List.iter (fun def ->
    match def with
    | Val _ | TypeDecl _ | RecordDecl _ -> ()
    | Fun (name, params, _, body) ->
        banner (Printf.sprintf "STAGE 5 [%s]: knormal -> tco -> cfg_build"
                  name);
        let norm = Knormal.normalize_fun params body in
        pf "--- kexpr after Knormal.normalize_fun ---\n%s\n" (s_k 0 norm);
        let tcod = Tco.optimize_tail name norm in
        if tcod == norm then
          pf "\n--- Tco.optimize_tail: NO self tail call rewritten \
              (kexpr unchanged) ---\n"
        else
          pf "\n--- kexpr after Tco.optimize_tail ---\n%s\n" (s_k 0 tcod);
        let cfg = Cfg_build.of_kexpr name params tcod in
        dump_cfg (Printf.sprintf "%s CFG after Cfg_build.of_kexpr" name) cfg;
        Hashtbl.replace fn_table name cfg;
        fn_order := name :: !fn_order
  ) program;
  let fn_order = List.rev !fn_order in

  (* Phase 2a: inline. *)
  Inline.run fn_table;
  dump_table "PHASE 2a: full fn_table after Inline.run" fn_table fn_order;

  Closure_spec.run fn_table;

  (* Phase 2b: monomorphize. *)
  Monomorphize.run fn_table;
  let fn_order = table_order fn_table fn_order in
  dump_table "PHASE 2b: full fn_table after Monomorphize.run" fn_table
    fn_order;

  let closure_layout = Closure_layout.compute fn_table in
  Cost.k_max_captured := closure_layout.Closure_layout.k_max_captured;

  (* Phase 3, per function: optimize (pass-by-pass) -> liveness ->
     regalloc -> codegen. *)
  let all_files : (string * string list) list ref = ref [] in
  let guarded_funs : (string * int) list ref = ref [] in
  List.iter (fun name ->
    let cfg = Hashtbl.find fn_table name in
    if cfg.Cfg.is_template then
      pf "\n[%s] SKIPPED in Phase 3: is_template=true (never emitted)\n" name
    else begin
      banner (Printf.sprintf "PHASE 3 [%s]: optimize -> regalloc -> codegen"
                name);
      m3a_instrumented name "sweep 1" cfg;
      loop_pass_instrumented name fn_table cfg;
      m3a_instrumented name "sweep 2" cfg;
      Closure_spec.check_hot_loop cfg;
      pf "\n--- [%s] liveness (guard-chain pinning visible here) ---\n" name;
      dump_liveness cfg;
      Regalloc_cfg.alloc cfg;
      dump_cfg (Printf.sprintf "%s after Regalloc_cfg.alloc (slots=%d)"
                  name cfg.Cfg.slot_count) cfg;
      let files = Codegen_cfg.emit ~closure_layout cfg in
      print_files (Printf.sprintf "PHASE 3 [%s]: Codegen_cfg.emit output"
                     name) files;
      if has_self_tail cfg then begin
        let body_cost =
          Array.fold_left (fun acc b ->
            if Cfg.block_is_reachable cfg b
            then acc + Cost.estimate_block b else acc)
            0 cfg.Cfg.blocks
        in
        pf "[%s] has_self_tail=true, per-iteration body cost=%d \
            -> tick_guard candidate\n" name body_cost;
        guarded_funs := (name, body_cost) :: !guarded_funs
      end else
        pf "[%s] has_self_tail=false (reachable blocks only) \
            -> no tick guard\n" name;
      all_files := !all_files @ files
    end
  ) fn_order;
  let guarded = List.rev !guarded_funs in

  (* Phase 4: tick_split.  Phase 5: tick_guard. *)
  let split = Tick_split.run !all_files in
  banner "PHASE 4: Tick_split.run";
  if List.map fst split = List.map fst !all_files then
    pf "no file exceeded MCAML_TICK_BUDGET; file list unchanged\n"
  else
    print_files "PHASE 4 result" split;

  let final = Tick_guard.run ~guarded split in
  (* NOT the final emitted set: main.ml additionally synthesizes
     __globals_init / apply / apply_dispatch_* files, filters dead
     global _get files (deadval), and appends the $tick_iters
     natural-exit reset + closure-cell resets to entry files. For the
     true final files, compile with ./mcaml and read the output dir;
     this tool's job is the IR stages above. *)
  print_files "PHASE 5: after Tick_guard.run (last stage traced here — \
               see main.ml for driver-level post-processing)" final
