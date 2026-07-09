val collect_arr_writes :
  Cfg.cfg_func -> Cfg.label list -> (Cfg.aid, int) Hashtbl.t
val collect_loop_defs :
  Cfg.cfg_func -> Cfg.label list -> (Cfg.vreg, unit) Hashtbl.t
val movable_v1 :
  (Cfg.vreg, unit) Hashtbl.t -> (Cfg.aid, int) Hashtbl.t -> Cfg.instr -> bool
val run_on_loop : Cfg.cfg_func -> Loop_detect.loop -> bool
val run : Cfg.cfg_func -> bool
