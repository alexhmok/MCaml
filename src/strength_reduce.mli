type basic_iv = {
  iv_vreg : Cfg.vreg;
  param_idx : int;
  step : int;
  latches : Cfg.label list;
}
type derived_iv = {
  derived_dest : Cfg.vreg;
  iv : Cfg.vreg;
  stride_vreg : Cfg.vreg option;
  base_vreg : Cfg.vreg option;
  defining_blk : Cfg.label;
}
type iv_table = { basics : basic_iv list; deriveds : derived_iv list; }
val analyze : Cfg.cfg_func -> iv_table
val run : Cfg.cfg_func -> bool
val dump : Cfg.cfg_func -> iv_table -> string
