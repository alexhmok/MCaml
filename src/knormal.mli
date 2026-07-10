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
val counter : int ref
val new_temp : unit -> string
val arr_counter : int ref
val new_arr_id : unit -> string
val str_of_coord : Ast.coord_part -> string
val dyn_env : (string, string) Hashtbl.t
val closure_env : (string, unit) Hashtbl.t
val arr_env : (string, string) Hashtbl.t
val arr_dims : (string, int * int option) Hashtbl.t
val global_arr_env : (string, string) Hashtbl.t
val global_arr_dims : (string, int * int option) Hashtbl.t
val register_global_array : string -> string -> int -> unit
val reseed_globals : unit -> unit
val ref_env : (string, string) Hashtbl.t
val all_ints : Ast.expr list -> int list option
val bind_or_unit : string option -> kexpr -> kexpr
val seq_alloc : string option -> kexpr list -> (string -> kexpr) -> kexpr
val resolve_arr_base : string -> Ast.expr -> string * string
val matrix_cols : string -> string -> int
val set_result : string option -> kexpr -> kexpr
val record_decl_of_field : string -> (string * Ast.typ) list
val normalize_to : string option -> Ast.expr -> kexpr
val normalize_each : Ast.expr list -> string list * kexpr list
val emit_arr_lit : string -> Ast.expr list -> kexpr
val scale_binop : string option -> Ast.binop -> Ast.expr -> kexpr
val macro_read :
  string option -> Ast.expr -> (string -> string -> kexpr) -> kexpr
val compile_match :
  string option ->
  string list ->
  (Ast.pattern list * (string * string) list * Ast.expr) list -> kexpr
val compile_unfold_column :
  string option ->
  string ->
  string list ->
  (Ast.pattern list * (string * string) list * Ast.expr ->
   Ast.pattern * Ast.pattern list * (string * string) list * Ast.expr) ->
  (Ast.pattern list * (string * string) list * Ast.expr) list ->
  int -> (Ast.pattern -> Ast.pattern list option) -> kexpr
val normalize : Ast.expr -> kexpr
val normalize_fun : (string * Ast.typ) list -> Ast.expr -> kexpr
