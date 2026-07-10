type builder = {
  mutable cur : Cfg.block;
  blocks : (Cfg.label, Cfg.block) Hashtbl.t;
  next_label : int ref;
  mutable region_depth : int;
}
val of_kexpr :
  string -> (string * Ast.typ) list -> Knormal.kexpr -> Cfg.cfg_func
