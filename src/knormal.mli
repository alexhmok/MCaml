type heap_pool = Ast.heap_pool = PoolScratch | PoolPermheap
type kexpr =
    KUnit
  | KInt of int
  | KVar of string
  | KStr of string
  | KCommand of string
  | KBinOp of Ast.binop * string * string
  | KLet of string * kexpr * kexpr
  | KIf of string * kexpr * kexpr
  | KSeq of kexpr * kexpr
  | KCall of string * string list
  | KLoop of string * string list
  | KArrLitConst of string * int list
  | KArrLitDyn of string * string list
  | KArrGetStatic of string * string * int
  | KArrGet of string * string * string
  | KArrSetStatic of string * int * string
  | KArrSet of string * string * string
  | KDynAllocConst of string * heap_pool * int
  | KDynAlloc of string * heap_pool * string
  | KHeapGet of string * heap_pool * string * string
  | KHeapSet of heap_pool * string * string * string
  | KCons of string * string * string
  | KHead of string * string
  | KTail of string * string
  | KRegion of kexpr * Ast.typ * string option
  | KAdtAlloc of string * int * string list
  | KTagGet of string * string
  | KFieldGet of string * string * int
  | KClosureMake of string * string * string list
  | KApply of string option * string * string list
val register_global_array : string -> string -> int -> unit
val normalize_fun : (string * Ast.typ) list -> Ast.expr -> kexpr
