val build_guard_prefix : (Cfg.vreg * Cfg.polarity) list -> string
val wrap_cmd : string -> string -> string
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
val fresh_helper_name : state -> string
val add_helper : state -> string -> string list -> unit
val cons_uniq : 'a -> 'a list -> 'a list
val ensure_macro_helper : state -> Cfg.aid -> unit
val ensure_macro_setter : state -> Cfg.aid -> unit
val push_cmd : state -> string -> string -> unit
val push_cmds : state -> string -> string list -> unit
val push_ret_copy : state -> string -> Cfg.vreg option -> unit
val is_reserved_slot : string -> bool
val slots_live_across_call :
  state -> Cfg.block -> int -> Cfg.vreg option -> string list
val emit_instr : state -> string -> Cfg.block -> int -> Cfg.instr -> unit
val emit_term : state -> string -> Cfg.terminator -> unit
val emit_block : state -> Cfg.block -> unit
val append_flagged_helpers : state -> unit
val assemble_output : state -> Cfg.cfg_func -> (string * string list) list
val emit :
  ?closure_layout:Closure_layout.t ->
  Cfg.cfg_func -> (string * string list) list
