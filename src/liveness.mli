module VSet : Set.S with type elt = string
                     and type t = Set.Make(String).t
type block_liveness = { live_in : VSet.t; live_out : VSet.t; }
type instr_liveness = {
  per_block : block_liveness array;
  per_instr : VSet.t array array;
}
val is_reserved : Cfg.vreg -> bool
val add_if_tracked : Cfg.vreg -> VSet.t -> VSet.t
val analyze : Cfg.cfg_func -> instr_liveness
