%{ open Ast %}

/* Tokens */
%token <int> INT
%token <float> FLOAT
%token <string> ID
%token <string> STRING
%token <string> SELECTOR

/* Keywords */
%token LET IN IF THEN ELSE FUN VAL CMD
%token TRUE FALSE PIPE
%token REF FOR TO DO DONE
%token BANG COLEQ

/* Symbols */
%token LPAREN RPAREN LBRACE RBRACE COMMA COLON SEMICOLON
%token EQUAL PLUS MINUS TIMES DIV PERCENT LT GT LEQ GEQ NEQ AND OR
%token TILDE CARET EOF
%token LBAR RBAR LBRACK RBRACK
%token CONS
%token REGION ARROW

/* Virtual precedence marker used to lower seq_expr reduction below operators */
%token BELOW_SEMI

/* Types */
%token T_INT T_BOOL T_UNIT T_SEL T_POS
%token T_ARR T_MAT T_LIST T_DARR

/* Return Types */
%type <Ast.program> prog
%type <Ast.def> definition
%type <Ast.def list> list_definition
%type <Ast.expr> expr
%type <Ast.expr> seq_expr
%type <Ast.coord_part> coord_part
%type <Ast.typ> typ
%type <(string * Ast.typ)> param
%type <Ast.binop> binop
%type <(string * Ast.typ) list> param_list
%type <(string * Ast.typ) list> nonempty_param_list
%type <Ast.expr list> arg_list
%type <Ast.expr list> nonempty_arg_list
%type <Ast.expr list> expr_semi_list
%type <Ast.expr list> nonempty_expr_semi_list

/* Precedence */
%nonassoc BELOW_SEMI
%right SEMICOLON
%right PIPE
%nonassoc IN ELSE
%right COLEQ
%left OR
%left AND
%left EQUAL NEQ LT GT LEQ GEQ
%right CONS
%left PLUS MINUS
%left TIMES DIV PERCENT
%nonassoc BANG REF
%left LBRACK

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

param_list:
  | { [] }
  | l = nonempty_param_list { l }

nonempty_param_list:
  | p = param { [p] }
  | p = param COMMA rest = nonempty_param_list { p :: rest }

param:
  | name = ID COLON t = typ { (name, t) }

typ:
  | T_INT { TInt }
  | T_BOOL { TBool }
  | T_UNIT { TUnit }
  | T_SEL { TSelector }
  | T_POS { TPos }
  | T_ARR LBRACK T_INT COMMA n = INT RBRACK { TArrStatic(TInt, n) }
  | T_MAT LBRACK T_INT COMMA m = INT COMMA n = INT RBRACK { TMat(TInt, m, n) }
  | T_LIST { TList TInt }
  | T_DARR { TArrDyn TInt }
  | REF T_INT { TRef TInt }
  | REF T_BOOL { TRef TBool }

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
  | IF cond = expr THEN e1 = expr ELSE e2 = expr { If(cond, e1, e2) }

  | func = ID LPAREN args = arg_list RPAREN { App(func, args) }

  | arg = expr PIPE func = ID
    { App(func, [arg]) }
  | arg = expr PIPE func = ID LPAREN other_args = nonempty_arg_list RPAREN
    { App(func, arg :: other_args) }

  | LPAREN e = seq_expr RPAREN { e }
  | LPAREN RPAREN { Unit }

  | REF e = expr { Ref e }
  | BANG e = expr { Deref e }
  | e1 = expr COLEQ e2 = expr { RefSet(e1, e2) }
  | FOR i = ID EQUAL lo = expr TO hi = expr DO body = seq_expr DONE { For(i, lo, hi, body) }

  | LBAR elems = expr_semi_list RBAR { Array elems }
  | LBRACK RBRACK { Nil }
  | LBRACK elems = nonempty_expr_semi_list RBRACK
      { List.fold_right (fun h t -> Cons(h, t)) elems Nil }
  | e = expr LBRACK i = expr RBRACK { Index1(e, i) }
  | e = expr LBRACK i = expr COMMA j = expr RBRACK { Index2(e, i, j) }

  | REGION LPAREN FUN LPAREN RPAREN ARROW body = seq_expr RPAREN { Region (ref TUnit, body) }

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
  | TILDE     { Rel None }
  | TILDE f = FLOAT { Rel (Some f) }
  | TILDE i = INT   { Rel (Some (float_of_int i)) }
  | CARET     { Local None }
  | CARET f = FLOAT { Local (Some f) }
  | CARET i = INT   { Local (Some (float_of_int i)) }

%inline binop:
  | PLUS { Add } | MINUS { Sub } | TIMES { Mult } | DIV { Div } | PERCENT { Mod }
  | EQUAL { Eq } | NEQ { Neq } | LT { Lt } | GT { Gt } | LEQ { Leq } | GEQ { Geq }
  | AND { And } | OR { Or }