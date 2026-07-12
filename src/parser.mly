%{
open Ast

(* Phase D: constructors are Capitalized, variables/wildcards are not.
   This is how a bare ID in pattern position disambiguates. *)
let is_ctor_name s =
  String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'

let pattern_of_id name =
  if name = "_" then PWild
  else if is_ctor_name name then PCtor (name, [])
  else PVar name

(* G4: TYVAR's lexeme keeps the leading quote ("'a"); strip it so stored
   param/TParam names are bare ("a") — §13.11 decision 3. *)
let strip_tyvar tv = String.sub tv 1 (String.length tv - 1)
%}

/* Tokens */
%token <int> INT
%token <float> FLOAT
%token <string> ID
%token <string> STRING
%token <string> SELECTOR
%token <string> TYVAR

/* Keywords */
%token LET IN IF THEN ELSE FUN VAL CMD
%token TRUE FALSE PIPE
%token REF FOR TO DO DONE
%token BANG COLEQ

/* Symbols */
%token LPAREN RPAREN LBRACE RBRACE COMMA COLON SEMICOLON
%token DOT
%token EQUAL PLUS MINUS TIMES DIV PERCENT LT GT LEQ GEQ NEQ AND OR
%token PLUSDOT MINUSDOT TIMESDOT DIVDOT
%token TILDE CARET EOF
%token LBAR RBAR LBRACK RBRACK
%token CONS
%token REGION ARROW
%token TYPE MATCH WITH OF BAR

/* Virtual precedence marker used to lower seq_expr reduction below operators */
%token BELOW_SEMI
/* Phase D: virtual marker so a nested match greedily takes trailing
   `| arm`s (shift beats reducing the inner match_arms list) — same
   trick as BELOW_SEMI, OCaml semantics. */
%token BELOW_BAR

/* Types */
%token T_INT T_FLOAT T_BOOL T_UNIT T_SEL T_POS
%token T_ARR T_MAT T_LIST T_DARR

/* Return Types */
%type <Ast.program> prog
%type <Ast.def> definition
%type <Ast.def list> list_definition
%type <Ast.expr> expr
%type <Ast.expr> seq_expr
%type <Ast.coord_part> coord_part
%type <Ast.typ> typ
%type <Ast.typ> typ_atom
%type <Ast.typ list> star_typ_list
%type <Ast.typ list> typ_comma_list
%type <string list> tyvar_comma_list
%type <(string * Ast.typ)> param
%type <Ast.binop> binop
%type <(string * Ast.typ) list> param_list
%type <(string * Ast.typ) list> nonempty_param_list
%type <Ast.expr list> arg_list
%type <Ast.expr list> nonempty_arg_list
%type <Ast.expr list> expr_semi_list
%type <Ast.expr list> nonempty_expr_semi_list
%type <Ast.pattern> pattern
%type <Ast.pattern> atom_pattern
%type <Ast.pattern list> pattern_comma_list
%type <(Ast.pattern * Ast.expr) list> match_arms
%type <Ast.pattern * Ast.expr> match_arm
%type <Ast.constructor list> ctor_list
%type <Ast.constructor> ctor
%type <Ast.typ list> ctor_typs
%type <(string * Ast.typ) list> record_field_decls
%type <(string * Ast.expr) list> record_field_exprs
%type <(string * Ast.pattern) list> record_field_pats
%type <unit> opt_bar

/* Precedence */
%nonassoc BELOW_SEMI
%right SEMICOLON
%nonassoc BELOW_BAR
%left BAR
%right PIPE
%nonassoc IN ELSE
%right COLEQ
%left OR
%left AND
%left EQUAL NEQ LT GT LEQ GEQ
%right CONS
%left PLUS MINUS PLUSDOT MINUSDOT
%left TIMES DIV PERCENT TIMESDOT DIVDOT
%nonassoc BANG REF
%left LBRACK DOT

%start prog

%%

prog:
  | definitions = list_definition EOF { definitions }

list_definition:
  | { [] }
  | d = definition rest = list_definition { d :: rest }

definition:
  | VAL name = ID EQUAL e = seq_expr
    { Val(name, e) }
  | FUN name = ID LPAREN params = param_list RPAREN COLON ret_type = typ EQUAL body = seq_expr
    { Fun(name, params, ret_type, body) }
  /* E4: return annotation is optional — omitted mints an unbound
     unification variable that typing pins from the body (and defaults
     to int at the knormal boundary if nothing constrains it). */
  | FUN name = ID LPAREN params = param_list RPAREN EQUAL body = seq_expr
    { Fun(name, params, TVar (ref None), body) }
  | TYPE name = ID EQUAL opt_bar ctors = ctor_list
    { TypeDecl(name, [], ctors) }
  /* G4: single-param parameterized decl, e.g. `type 'a option = ...`.
     v1 scope: exactly one param (§13.11 decision 4); multi-param
     decls are a deferred follow-up. */
  | TYPE tv = TYVAR name = ID EQUAL opt_bar ctors = ctor_list
    { TypeDecl(name, [strip_tyvar tv], ctors) }
  /* G4b: multi-param decl, e.g. `type ('a, 'b) either = ...`.
     Duplicate param names are rejected in typing (register_type_decl). */
  | TYPE LPAREN tvs = tyvar_comma_list RPAREN name = ID EQUAL opt_bar ctors = ctor_list
    { TypeDecl(name, List.map strip_tyvar tvs, ctors) }
  /* D8: record declaration. Fields in decl order; registration and
     the global-field-namespace check live in typing.ml. */
  | TYPE name = ID EQUAL LBRACE fields = record_field_decls RBRACE
    { RecordDecl(name, fields) }

record_field_decls:
  | f = ID COLON t = typ { [(f, t)] }
  | f = ID COLON t = typ SEMICOLON rest = record_field_decls { (f, t) :: rest }

opt_bar:
  | { () }
  | BAR { () }

ctor_list:
  | c = ctor { [c] }
  | c = ctor BAR rest = ctor_list { c :: rest }

ctor:
  | name = ID { (name, []) }
  | name = ID OF ts = ctor_typs { (name, ts) }

/* D7: ctor fields split on TIMES at the top level (OCaml's rule), so
   `of int * t` stays TWO fields and a tuple-typed field must be
   parenthesized: `of (int * int) * t`. This is why the elements are
   typ_atom, not typ. */
ctor_typs:
  | t = typ_atom { [t] }
  | t = typ_atom TIMES rest = ctor_typs { t :: rest }

param_list:
  | { [] }
  | l = nonempty_param_list { l }

nonempty_param_list:
  | p = param { [p] }
  | p = param COMMA rest = nonempty_param_list { p :: rest }

param:
  | name = ID COLON t = typ { (name, t) }
  /* E4: unannotated param — fresh unification variable (§13.10). */
  | name = ID { (name, TVar (ref None)) }

/* D7: `int * int` is a tuple type. One TIMES-free atom collapses to
   itself; two or more become TTuple.
   Phase F: `t -> r` / `() -> r` arrow-type ANNOTATION syntax (distinct
   from the Lambda EXPRESSION grammar above, which needs no arrow
   surface syntax at all since a lambda's own type is inferred).
   G4b: the n-ary form `(t1, t2) -> r` and multi-arg type application
   `(t1, t2) name` joined via [typ_comma_list]. F1's session notes
   claimed the shared `LPAREN typ` prefix with the grouping atom could
   not be LALR(1)-disambiguated; that was wrong — the decision point is
   COMMA vs RPAREN, one token, and menhir left-factors the prefix with
   zero conflicts (verified by running menhir on this exact grammar,
   2026-07-11). Right-recursive on [typ] itself so `int -> int -> int`
   (a function returning a function, decision 2's HOF-factory case)
   associates right with zero extra grammar. */
typ:
  | t = star_typ_list ARROW ret = typ
      { TFun ([(match t with [x] -> x | ts -> TTuple ts)], ret) }
  | LPAREN RPAREN ARROW ret = typ
      { TFun ([], ret) }
  /* G4b: n-ary arrow annotation `(t1, t2) -> r`. */
  | LPAREN t = typ COMMA rest = typ_comma_list RPAREN ARROW ret = typ
      { TFun (t :: rest, ret) }
  | ts = star_typ_list { match ts with [t] -> t | ts -> TTuple ts }

typ_comma_list:
  | t = typ { [t] }
  | t = typ COMMA rest = typ_comma_list { t :: rest }

/* G4b: `('a, 'b)` decl-side param list. */
tyvar_comma_list:
  | tv = TYVAR { [tv] }
  | tv = TYVAR COMMA rest = tyvar_comma_list { tv :: rest }

star_typ_list:
  | t = typ_atom { [t] }
  | t = typ_atom TIMES rest = star_typ_list { t :: rest }

typ_atom:
  | T_INT { TInt }
  | T_FLOAT { TFloat }
  | T_BOOL { TBool }
  | T_UNIT { TUnit }
  | T_SEL { TSelector }
  | T_POS { TPos }
  | T_ARR LBRACK T_INT COMMA n = INT RBRACK { TArrStatic(TInt, n) }
  | T_ARR LBRACK T_FLOAT COMMA n = INT RBRACK { TArrStatic(TFloat, n) }
  | T_MAT LBRACK T_INT COMMA m = INT COMMA n = INT RBRACK { TMat(TInt, m, n) }
  | T_MAT LBRACK T_FLOAT COMMA m = INT COMMA n = INT RBRACK { TMat(TFloat, m, n) }
  | T_LIST { TList TInt }
  | T_DARR { TArrDyn TInt }
  | name = ID { TAdt (name, []) }   /* Phase D: nominal reference to a declared ADT; existence checked in typing */
  | REF T_INT { TRef TInt }
  | REF T_BOOL { TRef TBool }
  | LPAREN t = typ RPAREN { t }   /* D7: grouping, e.g. a tuple-typed ctor field `of (int * int) * t` */
  /* G4: postfix type application, e.g. `int option`, `int option
     option`, `(int * int) option`. Left-recursive on typ_atom so it
     composes with LPAREN-grouping and nests for free. */
  | t = typ_atom name = ID { TAdt (name, [t]) }
  /* G4b: multi-arg type application `(int, bool) either`. Shares its
     LPAREN prefix with the grouping atom above; disambiguated at
     COMMA vs RPAREN (one token — zero menhir conflicts). */
  | LPAREN t = typ COMMA rest = typ_comma_list RPAREN name = ID
      { TAdt (name, t :: rest) }
  /* G4/decision 5: `list` joins the postfix grammar (`float list`,
     `t list`); the bare T_LIST keyword above stays `int list` for
     back-compat. */
  | t = typ_atom T_LIST { TList t }
  /* G4: decl-side type variable reference inside a ctor/record/param
     field type, e.g. `Some of 'a`. Legality (bound by the enclosing
     decl's own param list) is checked in typing.ml, not here. */
  | v = TYVAR { TParam (strip_tyvar v) }

seq_expr:
  | e = expr %prec BELOW_SEMI { e }
  | e1 = expr SEMICOLON e2 = seq_expr { Seq(e1, e2) }

expr:
  | i = INT { Int i }
  | f = FLOAT { Float f }
  | TRUE { Bool true }
  | FALSE { Bool false }
  | s = STRING { Str s }
  | id = ID { Var id }
  | sel = SELECTOR { Selector sel }

  | LT x = coord_part COMMA y = coord_part COMMA z = coord_part GT
    { Coord(x, y, z) }

  /* UPDATED: Takes a string literal "say hi" instead of { say hi } */
  | CMD s = STRING { Command s }

  | e1 = expr op = binop e2 = expr { BinOp(op, e1, e2) }
  | e1 = expr CONS e2 = expr { Cons(e1, e2) }

  | LET x = ID EQUAL e1 = seq_expr IN e2 = seq_expr { Let(x, e1, e2) }
  /* D7: destructuring let — parse-time sugar for a one-arm match.
     Tuple patterns only (records destructure via match). Typing's
     exhaustiveness check rejects a refutable pattern here (e.g.
     `let (0, b) = e`) exactly as it would a one-arm match. */
  | LET LPAREN p = pattern COMMA ps = pattern_comma_list RPAREN EQUAL e1 = seq_expr IN e2 = seq_expr
      { Match(e1, [ (PTuple (p :: ps), e2) ]) }
  | IF cond = expr THEN e1 = expr ELSE e2 = expr { If(cond, e1, e2) }

  | func = ID LPAREN args = arg_list RPAREN { App(func, args) }

  | arg = expr PIPE func = ID
    { App(func, [arg]) }
  | arg = expr PIPE func = ID LPAREN other_args = nonempty_arg_list RPAREN
    { App(func, arg :: other_args) }

  | LPAREN e = seq_expr RPAREN { e }
  | LPAREN RPAREN { Unit }
  /* D7: tuple expression. Reuses nonempty_arg_list for the tail, so
     `(a, b, c)` is Tuple [a; b; c] while `f(a, b)` stays a two-arg
     App (the App production consumes its own LPAREN). */
  | LPAREN e = expr COMMA rest = nonempty_arg_list RPAREN { Tuple (e :: rest) }

  /* D8: record literal and field access. */
  | LBRACE fields = record_field_exprs RBRACE { Record fields }
  | e = expr DOT field = ID { Field(e, field) }

  | REF e = expr { Ref e }
  | BANG e = expr { Deref e }
  /* OCaml-style unary float negation: ~-. e desugars to 0.0 -. e — same
     precedence tier as REF/BANG (binds tighter than binary arithmetic,
     looser than indexing/field access). */
  | TILDE MINUSDOT e = expr %prec BANG { BinOp(FSub, Float 0.0, e) }
  /* Unary integer negation. Literal operands fold in place so `-1` /
     `-1.5` stay literals; anything else desugars to `0 - e` (int-only,
     like OCaml's prefix `-`; floats use ~-.). Same precedence tier as
     BANG/REF: `-x * y` is `(-x) * y`, `-a[i]` negates the element.
     Pattern and coord positions don't build through expr, so they get
     their own MINUS cases below. */
  | MINUS e = expr %prec BANG
    { match e with
      | Int i -> Int (-i)
      | Float f -> Float (-.f)
      | e -> BinOp(Sub, Int 0, e) }
  | e1 = expr COLEQ e2 = expr { RefSet(e1, e2) }
  | FOR i = ID EQUAL lo = expr TO hi = expr DO body = seq_expr DONE { For(i, lo, hi, body) }

  | LBAR elems = expr_semi_list RBAR { Array elems }
  | LBRACK RBRACK { Nil }
  | LBRACK elems = nonempty_expr_semi_list RBRACK
      { List.fold_right (fun h t -> Cons(h, t)) elems Nil }
  | e = expr LBRACK i = expr RBRACK { Index1(e, i) }
  | e = expr LBRACK i = expr COMMA j = expr RBRACK { Index2(e, i, j) }

  | REGION LPAREN FUN LPAREN RPAREN ARROW body = seq_expr RPAREN { Region (ref TUnit, body) }

  /* Phase F: lambda expression. Mirrors Fun's own production exactly,
     reusing param_list verbatim - no new nonterminal (F1 sub-decision
     2). Body sits at `expr` (not seq_expr), same reason match_arm's
     body does: a trailing "; e2" after the lambda sequences with
     whatever follows instead of being swallowed into the body.
     Region's own literal REGION LPAREN FUN LPAREN RPAREN ARROW ...
     production above is a fully separate token sequence that never
     builds through `expr`, so this rule cannot interact with it.
     %prec BELOW_BAR is required here for the same reason match_arm
     carries it: ARROW has no declared precedence, so without this the
     reduce action of THIS rule is unresolved against a shift of any
     following operator token (PLUS, CONS, ...) - menhir silently
     defaults to shift, producing 18 shift/reduce conflicts. Pinning
     the reduce action below every operator's precedence makes the
     body extend greedily and removes every conflict (confirmed by
     re-running menhir after adding this). */
  | FUN LPAREN params = param_list RPAREN ARROW body = expr %prec BELOW_BAR
    { Lambda (params, body) }

  | MATCH e = seq_expr WITH opt_bar arms = match_arms { Match(e, arms) }

match_arms:
  | a = match_arm %prec BELOW_BAR { [a] }
  | a = match_arm BAR rest = match_arms { a :: rest }

match_arm:
  /* %prec BELOW_BAR sinks this rule below every operator token, so an
     arm body extends greedily: `p -> e * 2` keeps `* 2` in the body
     (shift) instead of reducing the arm and making the whole match the
     left operand. Same resolution gives trailing `| arm`s to the
     innermost match. */
  | p = pattern ARROW body = expr %prec BELOW_BAR { (p, body) }

/* D6: `::` in pattern position. A layered grammar (atom / cons chain)
   gives right associativity without touching the expr-level %right CONS
   declaration — pattern position is disjoint from expr position (only
   after `with` / `|`), so no conflict with expr `::` and no BELOW_BAR
   interaction: the CONS token inside a pattern is consumed before ARROW
   is ever seen. */
pattern:
  | p = atom_pattern CONS rest = pattern { PCons(p, rest) }
  | p = atom_pattern { p }

atom_pattern:
  | i = INT { PInt i }
  | MINUS i = INT { PInt (-i) }
  | name = ID { pattern_of_id name }
  | name = ID LPAREN ps = pattern_comma_list RPAREN
      { if not (is_ctor_name name) then
          failwith (Printf.sprintf
            "pattern %s(...): only constructors (Capitalized) can take \
             arguments in a pattern" name);
        PCtor(name, ps) }
  | LBRACK RBRACK { PNil }
  | LPAREN p = pattern RPAREN { p }
  /* D7: tuple pattern — (p1, p2, ...). One-element parens stay
     grouping (the arm above). */
  | LPAREN p = pattern COMMA ps = pattern_comma_list RPAREN { PTuple (p :: ps) }
  /* D8: record pattern — fields permutable and omittable (missing =
     PWild; resolution against the decl is typing's job). */
  | LBRACE fields = record_field_pats RBRACE { PRecord fields }

pattern_comma_list:
  | p = pattern { [p] }
  | p = pattern COMMA rest = pattern_comma_list { p :: rest }

record_field_exprs:
  | f = ID EQUAL e = expr { [(f, e)] }
  | f = ID EQUAL e = expr SEMICOLON rest = record_field_exprs { (f, e) :: rest }

record_field_pats:
  | f = ID EQUAL p = pattern { [(f, p)] }
  | f = ID EQUAL p = pattern SEMICOLON rest = record_field_pats { (f, p) :: rest }

expr_semi_list:
  | { [] }
  | l = nonempty_expr_semi_list { l }

nonempty_expr_semi_list:
  | e = expr { [e] }
  | e = expr SEMICOLON rest = nonempty_expr_semi_list { e :: rest }

arg_list:
  | { [] }
  | l = nonempty_arg_list { l }

nonempty_arg_list:
  | e = expr { [e] }
  | e = expr COMMA rest = nonempty_arg_list { e :: rest }

coord_part:
  | f = FLOAT { Abs f }
  | i = INT   { Abs (float_of_int i) }
  | MINUS f = FLOAT { Abs (-.f) }
  | MINUS i = INT   { Abs (float_of_int (-i)) }
  | TILDE     { Rel None }
  | TILDE f = FLOAT { Rel (Some f) }
  | TILDE i = INT   { Rel (Some (float_of_int i)) }
  | TILDE MINUS f = FLOAT { Rel (Some (-.f)) }
  | TILDE MINUS i = INT   { Rel (Some (float_of_int (-i))) }
  | CARET     { Local None }
  | CARET f = FLOAT { Local (Some f) }
  | CARET i = INT   { Local (Some (float_of_int i)) }
  | CARET MINUS f = FLOAT { Local (Some (-.f)) }
  | CARET MINUS i = INT   { Local (Some (float_of_int (-i))) }

%inline binop:
  | PLUS { Add } | MINUS { Sub } | TIMES { Mult } | DIV { Div } | PERCENT { Mod }
  | PLUSDOT { FAdd } | MINUSDOT { FSub } | TIMESDOT { FMult } | DIVDOT { FDiv }
  | EQUAL { Eq } | NEQ { Neq } | LT { Lt } | GT { Gt } | LEQ { Leq } | GEQ { Geq }
  | AND { And } | OR { Or }