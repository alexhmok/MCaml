(* codegen.ml — top-level compile driver.

   After M3c-1a, compile is split into two stages so the M3c inliner can
   operate on a table of already-lowered CFGs between them:

     - compile_def_to_cfg   : AST def    -> cfg_func option
         (knormal -> tco -> cfg_build; no optimize/regalloc yet)
     - compile_cfg_to_files : cfg_func   -> (fname, cmds) list
         (optimize -> regalloc -> codegen_cfg)

   [compile_def] is kept as a convenience that pipes one into the other —
   used only by the legacy dump path. The real driver in main.ml calls the
   two halves separately so it can run Inline.run on the full function
   table after Phase 1. *)

open Ast

let compile_def_to_cfg (d : def) : Cfg.cfg_func option =
  match d with
  | Val _ | TypeDecl _ | RecordDecl _ -> None
  | Fun (name, params, _, body) ->
      let norm = Knormal.normalize_fun params body in
      let optimized = Tco.optimize_tail name norm in
      Some (Cfg_build.of_kexpr name params optimized)

let compile_cfg_to_files
    ?fn_table ?closure_layout (cfg : Cfg.cfg_func) : (string * string list) list =
  Optimize.run ?fn_table cfg;
  Regalloc_cfg.alloc cfg;
  Codegen_cfg.emit ?closure_layout cfg

let compile_def (d : def) : (string * string list) list =
  match compile_def_to_cfg d with
  | None -> []
  | Some cfg -> compile_cfg_to_files cfg
