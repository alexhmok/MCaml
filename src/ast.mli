type coord_part = Abs of float | Rel of float option | Local of float option
type typ =
    TInt
  | TFloat
  | TBool
  | TUnit
  | TSelector
  | TPos
  | TArrStatic of typ * int
  | TArrDyn of typ
  | TMat of typ * int * int
  | TRef of typ
  | TList of typ
  | TAdt of string * typ list
  | TTuple of typ list
  | TVar of typ option ref
  | TParam of string
  | TFun of typ list * typ
type constructor = string * typ list
type pattern =
    PWild
  | PVar of string
  | PInt of int
  | PCtor of string * pattern list
  | PNil
  | PCons of pattern * pattern
  | PTuple of pattern list
  | PRecord of (string * pattern) list
type binop =
    Add
  | Sub
  | Mult
  | Div
  | Mod
  | FAdd
  | FSub
  | FMult
  | FDiv
  | Eq
  | Neq
  | Lt
  | Leq
  | Gt
  | Geq
  | And
  | Or
type heap_pool = PoolScratch | PoolPermheap
type expr =
    Int of int
  | Float of float
  | Bool of bool
  | Str of string
  | Var of string
  | Selector of string
  | Coord of coord_part * coord_part * coord_part
  | Command of string
  | BinOp of binop * expr * expr
  | Let of string * expr * expr
  | If of expr * expr * expr
  | App of string * expr list
  | Seq of expr * expr
  | Array of expr list
  | Index1 of expr * expr
  | Index2 of expr * expr * expr
  | IndexSet1 of expr * expr * expr
  | IndexSet2 of expr * expr * expr * expr
  | Unit
  | Ref of expr
  | Deref of expr
  | RefSet of expr * expr
  | For of string * expr * expr * expr
  | Nil
  | Cons of expr * expr
  | Region of typ ref * expr
  | Match of expr * (pattern * expr) list
  | Tuple of expr list
  | Record of (string * expr) list
  | Field of expr * string
  | Lambda of (string * typ) list * expr
  | Closure of string * expr list
type def =
    Val of string * expr
  | Fun of string * (string * typ) list * typ * expr
  | TypeDecl of string * string list * constructor list
  | RecordDecl of string * (string * typ) list
type program = def list
