val make_rewriter :
  event_id:int -> args:Cfg.vreg array -> Cfg.vreg -> Cfg.vreg
val run : (string, Cfg.cfg_func) Hashtbl.t -> unit
