val dump_cfg : bool
val dump_loops : bool
val dump_iv : bool
val dump_costs : bool
val no_tick_split : bool
val parse_out_dir : unit -> string
val ensure_dir : string -> unit
val check_reserved_names : Ast.def list -> unit
val register_type_decls : Ast.def list -> unit
val collect_globals : Ast.def list -> (string * Ast.typ * int list) list
val type_user_funs : Ast.def list -> unit
val zonk_program : Ast.def list -> Ast.def list
val build_fn_table :
  Ast.def list -> (string, Cfg.cfg_func) Hashtbl.t * string list
val run_whole_program_passes :
  (string, Cfg.cfg_func) Hashtbl.t -> Closure_layout.t
val extend_fn_order : ('a, 'b) Hashtbl.t -> 'a list -> 'a list
val run_dump_hooks : (string, Cfg.cfg_func) Hashtbl.t -> string list -> unit
val compute_entry_info :
  (string, Cfg.cfg_func) Hashtbl.t ->
  Closure_layout.t -> bool * (string -> bool)
val reset_cmds : string list
val append_reset :
  string -> (string * string list) list -> (string * string list) list
val has_self_tail : Cfg.cfg_func -> bool
val report_costs :
  string -> Cfg.cfg_func -> (string * string list) list -> unit
val report_cfg :
  string -> Cfg.cfg_func -> (string * string list) list -> unit
val emit_functions :
  fn_table:(string, Cfg.cfg_func) Hashtbl.t ->
  closure_layout:Closure_layout.t ->
  fn_order:string list ->
  any_dyn_heap_use:bool ->
  is_public_entry:(string -> bool) ->
  (string * string list) list * (string * int) list
val globals_init_files :
  (string * 'a * int list) list -> (string * string list) list
val apply_dispatch_files : Closure_layout.t -> (string * string list) list
val split_and_guard :
  (string * string list) list ->
  (string * int) list -> (string * string list) list
val dedupe_files : (string * string list) list -> (string * string list) list
val write_files : string -> (string * string list) list -> unit
