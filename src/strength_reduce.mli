type basic_iv = {
  iv_vreg : Cfg.vreg;
  param_idx : int;
  step : int;
  latches : Cfg.label list;
}
val param_slot_of : Cfg.vreg -> int option
val iter_self_tails :
  Cfg.cfg_func -> (Cfg.block -> Cfg.vreg list -> unit) -> unit
val param_copies_in_entry : Cfg.cfg_func -> (Cfg.vreg * int) list
type block_info = {
  alias : (Cfg.vreg, Cfg.vreg) Hashtbl.t;
  consts : (Cfg.vreg, int) Hashtbl.t;
}
val scan_block : Cfg.block -> block_info
val resolve : block_info -> Cfg.vreg -> Cfg.vreg
val step_from_update : Cfg.block -> Cfg.vreg -> Cfg.vreg -> int option
val detect_basic_ivs : Cfg.cfg_func -> basic_iv list
type derived_iv = {
  derived_dest : Cfg.vreg;
  iv : Cfg.vreg;
  stride_vreg : Cfg.vreg option;
  base_vreg : Cfg.vreg option;
  defining_blk : Cfg.label;
}
type iv_table = { basics : basic_iv list; deriveds : derived_iv list; }
val invariant_params :
  Cfg.cfg_func -> (Cfg.vreg * int) list -> (int, unit) Hashtbl.t
type cls =
    Inv
  | IvLin of { iv : Cfg.vreg; stride : Cfg.vreg option;
      base : Cfg.vreg option;
    }
val classify :
  Cfg.cfg_func ->
  basic_iv list -> (Cfg.vreg, cls) Hashtbl.t * derived_iv list
val backedge_iv_dests :
  Cfg.cfg_func -> basic_iv list -> (Cfg.vreg, unit) Hashtbl.t
val detect_derived_ivs : Cfg.cfg_func -> basic_iv list -> derived_iv list
val analyze : Cfg.cfg_func -> iv_table
type rewrite_state = {
  defs : (Cfg.vreg, Cfg.instr) Hashtbl.t;
  param_of : (Cfg.vreg, int) Hashtbl.t;
  emitted : (Cfg.vreg, Cfg.vreg) Hashtbl.t;
  mutable pre : Cfg.instr list;
}
val global_tmp : int ref
val fresh_tmp : rewrite_state -> Cfg.vreg
val materialize : rewrite_state -> Cfg.vreg -> Cfg.vreg option
val mk_state : Cfg.cfg_func -> rewrite_state
val no_sr : bool
val carrier_name : int -> Cfg.vreg
val global_carrier : int ref
val mint_carrier : unit -> Cfg.vreg
val useful_deriveds_of : Cfg.cfg_func -> derived_iv list -> derived_iv list
val materialize_stride : rewrite_state -> derived_iv -> Cfg.vreg option
val materialize_base :
  rewrite_state -> derived_iv -> [ `Fail | `Have of Cfg.vreg | `NoBase ]
val emit_carrier_init :
  rewrite_state ->
  basic_iv -> Cfg.vreg -> [ `Fail | `Have of Cfg.vreg | `NoBase ] -> Cfg.vreg
val replace_defining_instr : Cfg.cfg_func -> derived_iv -> Cfg.vreg -> bool
val append_latch_increments :
  Cfg.cfg_func ->
  (Cfg.vreg * Cfg.label, unit) Hashtbl.t ->
  basic_iv -> Cfg.vreg -> Cfg.vreg -> unit
val run : Cfg.cfg_func -> bool
val dump : Cfg.cfg_func -> iv_table -> string
