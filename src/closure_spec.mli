type def_info = {
  def_count : (Cfg.vreg, int) Hashtbl.t;
  def_instr : (Cfg.vreg, Cfg.instr) Hashtbl.t;
  all_defs : (Cfg.vreg, Cfg.instr list) Hashtbl.t;
}
type report_entry = {
  mutable resolved_sites : int;
  mutable escape_reason : string option;
  mutable hot_loop : string option;
}
type resolved_param = {
  idx : int;
  lam_fname : string;
  caps : Cfg.vreg list;
}
val run : (string, Cfg.cfg_func) Hashtbl.t -> unit
val check_hot_loop : Cfg.cfg_func -> unit
val print_report : unit -> unit
