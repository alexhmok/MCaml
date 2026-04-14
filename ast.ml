type coord_part = Abs of float | Rel of float option | Local of float option
type typ = TInt | TBool | TUnit | TSelector | TPos
         | TArrStatic of typ * int    (* static array: element type, compile-time length *)
         | TArrDyn of typ             (* dynamic array: element type; length is runtime *)
         | TMat of typ * int * int    (* element type, rows, cols *)
         | TRef of typ                (* ref cell holding T *)
type binop = Add | Sub | Mult | Div | Eq | Neq | Lt | Leq | Gt | Geq | And | Or

type expr =
  | Int of int
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
  | Array of expr list                     (* [| e1; e2; ...; eN |] — flat; nested becomes matrix in typing *)
  | Index1 of expr * expr                  (* a[i] *)
  | Index2 of expr * expr * expr           (* m[i, j] *)
  | IndexSet1 of expr * expr * expr        (* a[i] := v — unit-typed *)
  | IndexSet2 of expr * expr * expr * expr (* m[i, j] := v — unit-typed *)
  | Unit                                   (* unit literal () *)
  | Ref of expr                            (* ref e — allocate cell *)
  | Deref of expr                          (* !r — read cell *)
  | RefSet of expr * expr                  (* r := e — write cell *)
  | For of string * expr * expr * expr     (* For(i, lo, hi, body) *)

type def =
  | Val of string * expr
  | Fun of string * (string * typ) list * typ * expr

type program = def list