module VSet = Liveness.VSet
val is_reserved : Cfg.vreg -> bool
val reverse_postorder : Cfg.cfg_func -> Cfg.label list
val alloc : Cfg.cfg_func -> unit
