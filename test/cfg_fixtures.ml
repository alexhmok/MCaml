(* Hand-built CFG fixtures. The analysis passes index [cfg.blocks.(label)]
   directly and propagate through [preds], so fixtures must uphold two
   invariants: block labels equal array indices (dense 0..n-1, entry = 0),
   and [preds] is populated from [Cfg.succs]. [mk_func] asserts the first
   and derives the second so individual tests can't get them wrong. *)

open Cfg

let mk_block ?(guards = []) label instrs term =
  { label; instrs; term; preds = []; guards }

let mk_func ?(fname = "f") ?(params = []) ?(slot_count = 0) blocks =
  let blocks = Array.of_list blocks in
  Array.iteri (fun i b -> assert (b.label = i)) blocks;
  Cfg.populate_preds blocks;
  { fname; params; entry = 0; blocks; slot_count;
    preheader_instrs = []; is_template = false }
