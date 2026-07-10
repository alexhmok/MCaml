val limit : int
val no_sroa : bool
val pseudo_arr_aid : Cfg.vreg -> Cfg.aid option
val is_sentinel_aid : Cfg.aid -> bool
type info = {
  mutable inits : int;
  mutable length : int;
  mutable dynamic_get : bool;
  mutable dynamic_put : bool;
  mutable static_max : int;
  mutable escapes : bool;
}
val fresh_info : unit -> info
val collect : Cfg.cfg_func -> (Cfg.aid, info) Hashtbl.t
val promotable : info -> bool
val slot_name : Cfg.aid -> int -> Cfg.vreg
val rewrite_instr : (Cfg.aid, info) Hashtbl.t -> Cfg.instr -> Cfg.instr list
val aids_touched_by : Cfg.cfg_func -> (Cfg.aid, unit) Hashtbl.t
val run : ?fn_table:(string, Cfg.cfg_func) Hashtbl.t -> Cfg.cfg_func -> bool
