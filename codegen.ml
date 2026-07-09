(* codegen.ml — top-level compile driver.

   After M3c-1a, compile is split into two stages so the M3c inliner can
   operate on a table of already-lowered CFGs between them:

     - compile_def_to_cfg   : AST def    -> cfg_func option
         (knormal -> tco -> cfg_build; no optimize/regalloc yet)
     - compile_cfg_to_files : cfg_func   -> (fname, cmds) list
         (optimize -> regalloc -> codegen_cfg)

   The driver in main.ml calls the two halves separately so it can run
   Inline.run on the full function table after Phase 1. *)

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
  (* F6a/F6b: loop_detect is only meaningful post-optimize (LICM/unroll/
     SROA have already run), and this is before regalloc — exactly the
     point §13.12's F6 decision names, reusing the existing
     Optimize->Regalloc->Codegen sequence rather than adding a new
     whole-table pass. *)
  Closure_spec.check_hot_loop cfg;
  Regalloc_cfg.alloc cfg;
  Codegen_cfg.emit ?closure_layout cfg
