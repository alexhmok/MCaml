type def_info = {
  def_count : (Cfg.vreg, int) Hashtbl.t;
  def_instr : (Cfg.vreg, Cfg.instr) Hashtbl.t;
  all_defs : (Cfg.vreg, Cfg.instr list) Hashtbl.t;
}
val collect_defs : Cfg.cfg_func -> def_info
val resolve_origin : def_info -> Cfg.vreg -> (string * Cfg.vreg list) option
type report_entry = {
  mutable resolved_sites : int;
  mutable escape_reason : string option;
  mutable hot_loop : string option;
}
val report : (string, report_entry) Hashtbl.t
val caps_count : (string, int) Hashtbl.t
val site_functions : (string, (string, unit) Hashtbl.t) Hashtbl.t
val get_entry : string -> report_entry
val note_resolved : string -> unit
val note_site : string -> string -> unit
val note_escape : string -> string -> string -> unit
val note_unresolved_closure_use : def_info -> string -> Cfg.vreg -> unit
val rewrite_same_function : Cfg.cfg_func -> unit
val is_tfun : Ast.typ -> bool
val alias_set : Cfg.cfg_func -> Cfg.vreg -> (Cfg.vreg, unit) Hashtbl.t
val only_directly_applied : Cfg.cfg_func -> int -> string option
val clone_block : Cfg.block -> Cfg.block
val clone_cfg : Cfg.cfg_func -> Cfg.cfg_func
type resolved_param = {
  idx : int;
  lam_fname : string;
  caps : Cfg.vreg list;
}
val mangle : string -> resolved_param list -> string
val only_applied_cache : (string * int, string option) Hashtbl.t
val only_applied_cached :
  (string, Cfg.cfg_func) Hashtbl.t -> string -> int -> string option
val ensure_clone :
  (string, Cfg.cfg_func) Hashtbl.t ->
  (string, int) Hashtbl.t ->
  (string, unit) Hashtbl.t ->
  int -> string -> resolved_param list -> string option
val rewrite_callers :
  (string, Cfg.cfg_func) Hashtbl.t ->
  (string, int) Hashtbl.t ->
  (string, unit) Hashtbl.t -> int -> Cfg.cfg_func -> bool ref -> unit
val run : (string, Cfg.cfg_func) Hashtbl.t -> unit
val check_hot_loop : Cfg.cfg_func -> unit
val print_report : unit -> unit
