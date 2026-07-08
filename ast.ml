type coord_part = Abs of float | Rel of float option | Local of float option
type typ = TInt | TFloat | TBool | TUnit | TSelector | TPos
         | TArrStatic of typ * int    (* static array: element type, compile-time length *)
         | TArrDyn of typ             (* dynamic array: element type; length is runtime *)
         | TMat of typ * int * int    (* element type, rows, cols *)
         | TRef of typ                (* ref cell holding T *)
         | TList of typ               (* cons list: element type; handle at runtime *)
         | TAdt of string * typ list  (* Phase D: nominal user-declared ADT; runtime value is an objpool handle (or a small-int for nullary-only enums — D4 decides). G4: type args — [] for non-parameterized decls; §13.11 decision 1. *)
         | TTuple of typ list         (* D7: structural tuple; runtime value is an objpool handle to a {tag:0, f0...} cell *)
         | TVar of typ option ref     (* Phase E: unification variable — None = unbound, Some t = destructively linked (§13.10 decision 1). Only typing.ml (and the parser, for omitted annotations) ever mints one; main.ml zonks every def before knormal so no pass below typing sees a TVar. Schemes live in typing.ml's env, NOT here (decision 2). *)
         | TParam of string           (* G4: decl-side type variable — a BINDER, not a unification var. Legal only inside a registered ctor field type until substituted at every use/pattern site; never reaches unify unsubstituted (§13.11 decision 2). *)

(* Phase D: one constructor of a declared ADT: name + field types.
   Constructor names must be Capitalized (validated at registration in
   typing.ml) so patterns can distinguish `Circle` (ctor) from `x` (var). *)
type constructor = string * typ list

(* Phase D: patterns for `match`. PCtor covers both nullary (`Point`)
   and applied (`Circle(r)`, `Node(l, r)`) constructor patterns. *)
type pattern =
  | PWild                              (* _ *)
  | PVar of string                     (* binds the scrutinee (sub)value *)
  | PInt of int                        (* integer literal pattern *)
  | PCtor of string * pattern list     (* constructor pattern, possibly nested *)
  (* D6: builtin-list patterns. Dedicated variants, NOT PCtor with magic
     names — Nil/Cons must stay out of ctor_info so they can never leak
     into expression typing's ctor fallback and allocate {tag:0} cells
     behind the -1 sentinel ABI (§13.5 D6 note). *)
  | PNil                               (* [] — matches the -1 sentinel *)
  | PCons of pattern * pattern         (* h :: t *)
  (* D7: tuple pattern. Dedicated variant per the D6 precedent — tuples
     are structural and never enter the ctor namespace. Always a
     complete single-ctor signature, so match dispatch reads no tag. *)
  | PTuple of pattern list             (* (p1, p2, ...) — arity >= 2 *)
  (* D8: record pattern. Fields may appear in any order and may be
     omitted (missing = PWild). Owner type resolves from the field
     names (one global field namespace). Like tuples: single-ctor
     complete signature, zero tag reads. *)
  | PRecord of (string * pattern) list (* { x = p; ... } *)
type binop = Add | Sub | Mult | Div | Mod
           | FMult | FDiv                 (* Phase N: Q16.16 fixed-point multiply/divide *)
           | Eq | Neq | Lt | Leq | Gt | Geq | And | Or

(* Phase A: dynamic-heap pool tag. Lives in ast.ml (not cfg.ml) so that
   codegen_helpers — which is built before cfg.ml — can reference it. *)
type heap_pool = PoolScratch | PoolPermheap

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
  | Nil                                    (* [] : TList t — empty list literal *)
  | Cons of expr * expr                    (* h :: t — cons cell *)
  | Region of typ ref * expr               (* region (fun () -> body) — the [typ ref] is written by typing.ml and read by knormal.ml so the IR's IRegionExit can carry the return type the deep-copy walker dispatches on *)
  | Match of expr * (pattern * expr) list  (* Phase D: match e with | p -> e | ... *)
  | Tuple of expr list                     (* D7: (e1, e2, ...) — arity >= 2; allocates one {tag:0, f0...} objpool cell *)
  | Record of (string * expr) list         (* D8: { x = e; ... } — exact field set required, any order; same {tag:0, f0...} cell (decl order) *)
  | Field of expr * string                 (* D8: r.x — 3-cmd KFieldGet through the obj_f<k> macro getter *)

type def =
  | Val of string * expr
  | Fun of string * (string * typ) list * typ * expr
  | TypeDecl of string * string list * constructor list (* Phase D: type t = A | B of int | ...; G4: param names in decl order, [] for non-parameterized decls (§13.11 decision 4) *)
  | RecordDecl of string * (string * typ) list (* D8: type t = { x : int; ... } — fields in decl order; no ctor_info entry *)

type program = def list