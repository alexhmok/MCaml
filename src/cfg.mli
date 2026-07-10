val o0 : bool
val pass_disabled : string -> bool
type label = int
type vreg = string
type aid = string
type polarity = Pos | Neg
type heap_pool = Ast.heap_pool = PoolScratch | PoolPermheap
type instr =
    IConst of vreg * int
  | ICopy of vreg * vreg
  | ICommand of string
  | IBinOp of vreg * Ast.binop * vreg * vreg
  | ICall of vreg option * string * vreg list
  | IArrLitConst of aid * int list
  | IArrLitDyn of aid * vreg list
  | IArrGetStatic of vreg * aid * int
  | IArrGet of vreg * aid * vreg
  | IArrSetStatic of aid * int * vreg
  | IArrSet of aid * vreg * vreg
  | IHeapAllocConst of vreg * heap_pool * int
  | IHeapAlloc of vreg * heap_pool * vreg
  | IHeapGet of vreg * heap_pool * vreg * vreg
  | IHeapSet of heap_pool * vreg * vreg * vreg
  | ICons of vreg * vreg * vreg
  | IHead of vreg * vreg
  | ITail of vreg * vreg
  | IAdtAlloc of vreg * int * vreg list
  | ITagGet of vreg * vreg
  | IFieldGet of vreg * vreg * int
  | IRegionEnter of int
  | IRegionExit of int * vreg option * Ast.typ
  | IClosureMake of vreg * string * vreg list
  | IApply of vreg option * vreg * vreg list
type terminator =
    TRet
  | TJump of label
  | TBranch of vreg * label * label * label
  | TTail of string * vreg list
  | TUnreachable
type block = {
  label : label;
  mutable instrs : instr list;
  mutable term : terminator;
  mutable preds : label list;
  mutable guards : (vreg * polarity) list;
}
type cfg_func = {
  fname : string;
  params : (string * Ast.typ) list;
  entry : label;
  mutable blocks : block array;
  mutable slot_count : int;
  mutable preheader_instrs : instr list;
  mutable is_template : bool;
}
val make_block : label -> block
val add_instr : block -> instr -> unit
val finalize_block : block -> unit
val block_is_sealed : block -> bool
val succs : terminator -> label list
val term_uses : terminator -> vreg list
val instr_def : instr -> vreg option
val instr_uses : instr -> vreg list
val map_instr_operands :
  def:(vreg -> vreg) -> use:(vreg -> vreg) -> instr -> instr
val map_instr_vregs : (vreg -> vreg) -> instr -> instr
val map_term_vregs : (vreg -> vreg) -> terminator -> terminator
val param_index : vreg -> int option
val is_reserved : vreg -> bool
val block_is_reachable : cfg_func -> block -> bool
val populate_preds : block array -> unit
val reverse_postorder : cfg_func -> label list
val string_of_instr : instr -> string
val dump_func : cfg_func -> string
