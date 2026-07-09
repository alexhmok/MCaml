val max_leaf_size : int
val max_caller_growth : int
val event_counter : int ref
val fresh_event : unit -> int
val is_leaf : Cfg.cfg_func -> bool
val size_of : Cfg.cfg_func -> int
val is_ref_slot : string -> bool
val make_rewriter :
  event_id:int -> args:Cfg.vreg array -> Cfg.vreg -> Cfg.vreg
val rewrite_guards :
  (Cfg.vreg -> Cfg.vreg) ->
  (Cfg.vreg * Cfg.polarity) list -> (Cfg.vreg * Cfg.polarity) list
val rewrite_term :
  label_map:(Cfg.label -> Cfg.label) ->
  kont_label:Cfg.label ->
  (Cfg.vreg -> Cfg.vreg) -> Cfg.terminator -> Cfg.terminator
val recompute_preds : Cfg.block array -> unit
val split_at : int -> 'a list -> 'a list * 'a list
val find_call :
  Cfg.cfg_func ->
  (string -> bool) ->
  (int * int * Cfg.vreg option * string * Cfg.vreg list) option
val splice_once :
  Cfg.cfg_func ->
  Cfg.cfg_func ->
  block_idx:int -> instr_idx:int -> args:Cfg.vreg list -> Cfg.cfg_func
val run : (string, Cfg.cfg_func) Hashtbl.t -> unit
