val extended_succs : Cfg.cfg_func -> Cfg.block -> int list
val extended_preds : Cfg.cfg_func -> int list array
val reverse_postorder : Cfg.cfg_func -> int list * int array
val compute : Cfg.cfg_func -> int array
val dominates : int array -> int -> int -> bool
val dump : Cfg.cfg_func -> int array -> string
