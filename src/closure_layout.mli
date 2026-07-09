type shape = { code : int; fname : string; n_captured : int; n_args : int; }
type t = {
  shapes : (string, shape) Hashtbl.t;
  by_code : shape array;
  k_max_captured : int;
  k_max_apply_args : int;
}
val empty : t
val compute : (string, Cfg.cfg_func) Hashtbl.t -> t
val code_of : t -> string -> int
