val is_pseudo_arr : Cfg.vreg -> bool
val aid_of_pseudo : Cfg.vreg -> string
val is_sentinel_aid : Cfg.aid -> bool
val sentinel_index : Cfg.aid -> int
val clone_block : Cfg.block -> Cfg.block
val clone_cfg : Cfg.cfg_func -> Cfg.cfg_func
val specialize_cfg :
  Cfg.cfg_func ->
  (int, Cfg.aid) Hashtbl.t ->
  int option array -> string -> (string * Ast.typ) list -> Cfg.cfg_func
val mangle_name : string -> string list -> string
val extract_maps :
  (string * Ast.typ) list ->
  Cfg.vreg list -> (int * Cfg.aid) list * Cfg.vreg list
val ensure_clone :
  (string, Cfg.cfg_func) Hashtbl.t ->
  string -> (int * Cfg.aid) list -> (string, unit) Hashtbl.t -> string
val rewrite_caller :
  (string, Cfg.cfg_func) Hashtbl.t ->
  Cfg.cfg_func -> (string, unit) Hashtbl.t -> bool ref -> unit
val run : (string, Cfg.cfg_func) Hashtbl.t -> unit
