type info = {
  mutable inits : int;
  mutable length : int;
  mutable dynamic_get : bool;
  mutable dynamic_put : bool;
  mutable static_max : int;
  mutable escapes : bool;
}
val run : ?fn_table:(string, Cfg.cfg_func) Hashtbl.t -> Cfg.cfg_func -> bool
