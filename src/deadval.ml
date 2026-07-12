(* deadval.ml — dead global-`val` elimination (TODO.md, Phase G wart).

   Every top-level `val` used to survive into __globals_init.mcfunction
   (and, when read anywhere, grow a `__g_<name>_get` macro file) even
   when no compiled function referenced it. This pass walks the live
   function table between Phase 2 (inline/monomorphize — clones may
   reference a global the original only saw through an array param)
   and Phase 3, and collects:

     - [referenced]: every global aid (`__g_<name>`) mentioned by any
       instruction of any non-template function. Vals NOT in this set
       are dropped from the __globals_init synthesis.
     - [dyn_read]: the subset with at least one dynamic-index read
       (IArrGet) — the only lowering that dispatches through the
       `<aid>_get` macro file. A referenced val without a dynamic read
       keeps its init but its `_get` file is dead weight
       ([Codegen_cfg.ensure_macro_helper] emits it for static reads
       and literals too) and is dropped from the emitted file list.

   Scope note (why this is NOT reachability from entry points): MCaml
   has no dead-function elimination and no explicit entry-point list —
   every emitted function is invocable from chat, so a val referenced
   only by a never-called library helper must still be initialized or
   that helper would silently read empty storage when invoked. Culling
   the MineTorch LUT case (`lib/math.mcaml` concatenated for one or
   two helpers) therefore additionally needs an entry-rooted
   dead-function pass; see TODO.md.

   Writes (IArrSet/IArrSetStatic) count as references: a val that is
   only ever written is still runtime-touched storage. `<aid>_set`
   macro files need no treatment here — [ensure_macro_setter] only
   fires on an actual IArrSet, so they are never over-emitted. *)

let is_global_aid (id : string) : bool =
  String.starts_with ~prefix:"__g_" id

(* Returns (referenced, dyn_read) tables keyed by global aid. *)
let collect_refs (fn_table : (string, Cfg.cfg_func) Hashtbl.t)
  : (string, unit) Hashtbl.t * (string, unit) Hashtbl.t =
  let referenced : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let dyn_read : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let note tbl id = if is_global_aid id then Hashtbl.replace tbl id () in
  let walk_instr (i : Cfg.instr) : unit =
    match i with
    | Cfg.IArrGet (_, id, _) -> note referenced id; note dyn_read id
    | Cfg.IArrGetStatic (_, id, _)
    | Cfg.IArrSet (id, _, _)
    | Cfg.IArrSetStatic (id, _, _)
    | Cfg.IArrLitConst (id, _)
    | Cfg.IArrLitDyn (id, _) -> note referenced id
    | _ -> ()
  in
  Hashtbl.iter (fun _ (cfg : Cfg.cfg_func) ->
    if not cfg.Cfg.is_template then begin
      List.iter walk_instr cfg.Cfg.preheader_instrs;
      Array.iter (fun (b : Cfg.block) -> List.iter walk_instr b.Cfg.instrs)
        cfg.Cfg.blocks
    end) fn_table;
  (referenced, dyn_read)

(* Filter the Phase G globals list down to vals some function
   references. [globals] entries are (name, typ, ints) as collected by
   main.ml; the aid is `__g_<name>`. *)
let filter_globals
    (referenced : (string, unit) Hashtbl.t)
    (globals : (string * Ast.typ * int list) list)
  : (string * Ast.typ * int list) list =
  List.filter (fun (name, _, _) -> Hashtbl.mem referenced ("__g_" ^ name))
    globals

(* Drop `__g_<name>_get` macro files whose val has no surviving
   dynamic-index read. Only global getter files are touched; every
   other file (including `__g_*_set`, pool getters, per-arr getters)
   passes through unchanged. *)
let drop_dead_get_files
    (dyn_read : (string, unit) Hashtbl.t)
    (files : (string * string list) list)
  : (string * string list) list =
  List.filter (fun (fname, _) ->
    match String.ends_with ~suffix:"_get" fname, is_global_aid fname with
    | true, true ->
        let aid = String.sub fname 0 (String.length fname - 4) in
        Hashtbl.mem dyn_read aid
    | _ -> true)
    files
