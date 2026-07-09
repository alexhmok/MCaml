type builder = {
  mutable cur : Cfg.block;
  blocks : (Cfg.label, Cfg.block) Hashtbl.t;
  next_label : int ref;
  mutable region_depth : int;
}
val fresh_label : builder -> Cfg.label
val new_block : builder -> guards:(Cfg.vreg * Cfg.polarity) list -> Cfg.block
val seal : Cfg.block -> Cfg.terminator -> unit
val lower : builder -> Knormal.kexpr -> dest:Cfg.vreg option -> unit
val finalize_all : Cfg.block array -> unit
val blocks_of_table : (Cfg.label, Cfg.block) Hashtbl.t -> Cfg.block array
val of_kexpr :
  string -> (string * Ast.typ) list -> Knormal.kexpr -> Cfg.cfg_func
