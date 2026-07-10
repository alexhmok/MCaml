type state = {
  cfg : Cfg.cfg_func;
  liveness : Liveness.instr_liveness;
  mutable main_cmds : string list;
  mutable helpers : (string * string list) list;
  mutable helper_ctr : int;
  emitted_macros : (Cfg.aid, unit) Hashtbl.t;
  emitted_setters : (Cfg.aid, unit) Hashtbl.t;
  mutable heap_get_pools : Ast.heap_pool list;
  mutable heap_set_pools : Ast.heap_pool list;
  mutable emit_cons_head : bool;
  mutable emit_cons_tail : bool;
  mutable emit_obj_tag : bool;
  mutable obj_field_indices : int list;
  mutable region_exit_levels : int list;
  mutable emit_region_walker_list : bool;
  closure_layout : Closure_layout.t;
}
val emit :
  ?closure_layout:Closure_layout.t ->
  Cfg.cfg_func -> (string * string list) list
