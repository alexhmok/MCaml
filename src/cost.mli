val k_max_captured : int ref
val is_comparison : Ast.binop -> bool
val estimate : Cfg.instr -> int
val estimate_term : Cfg.terminator -> int
val estimate_block : Cfg.block -> int
val estimate_func : Cfg.cfg_func -> int
