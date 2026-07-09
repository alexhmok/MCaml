val max_iterations : int
val no_m3a : bool
val m3a_fixedpoint : Cfg.cfg_func -> unit
val no_licm : bool
val loop_pass :
  ?fn_table:(string, Cfg.cfg_func) Hashtbl.t -> Cfg.cfg_func -> unit
val run : ?fn_table:(string, Cfg.cfg_func) Hashtbl.t -> Cfg.cfg_func -> unit
