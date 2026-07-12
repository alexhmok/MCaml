val collect_refs :
  (string, Cfg.cfg_func) Hashtbl.t ->
  (string, unit) Hashtbl.t * (string, unit) Hashtbl.t
val filter_globals :
  (string, unit) Hashtbl.t ->
  (string * Ast.typ * int list) list ->
  (string * Ast.typ * int list) list
val drop_dead_get_files :
  (string, unit) Hashtbl.t ->
  (string * string list) list ->
  (string * string list) list
