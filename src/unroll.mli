val limit : int
val no_unroll : bool
val const_def_in_block : Cfg.block -> Cfg.vreg -> int option
val collect_call_sites :
  (string, Cfg.cfg_func) Hashtbl.t ->
  string -> (Cfg.block * Cfg.vreg list) list
val resolve_lo_hi :
  (string, Cfg.cfg_func) Hashtbl.t -> string -> (int * int) option
val is_reserved : Cfg.vreg -> bool
val rename : (Cfg.vreg, unit) Hashtbl.t -> string -> Cfg.vreg -> Cfg.vreg
val detect_shape :
  Cfg.cfg_func -> (Cfg.label * Cfg.label * Cfg.label * Cfg.vreg) option
val run_on_cfg : (string, Cfg.cfg_func) Hashtbl.t -> Cfg.cfg_func -> bool
val run : (string, Cfg.cfg_func) Hashtbl.t -> Cfg.cfg_func -> bool
