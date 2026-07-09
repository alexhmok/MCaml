val compile_def_to_cfg : Ast.def -> Cfg.cfg_func option
val compile_cfg_to_files :
  ?fn_table:(string, Cfg.cfg_func) Hashtbl.t ->
  ?closure_layout:Closure_layout.t ->
  Cfg.cfg_func -> (string * string list) list
