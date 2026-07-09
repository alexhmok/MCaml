type loop = {
  header : Cfg.label;
  body : Cfg.label list;
  back_edges : (Cfg.label * Cfg.label) list;
}
val find_back_edges :
  Cfg.cfg_func -> int array -> (Cfg.label * Cfg.label) list
val reachable_back_to :
  int list array -> Cfg.label -> Cfg.label -> Cfg.label list
val find_loops : Cfg.cfg_func -> int array -> loop list
val dump_loops : loop list -> string
