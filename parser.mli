
(* The type of tokens. *)

type token = 
  | WITH
  | VAL
  | T_UNIT
  | T_SEL
  | T_POS
  | T_MAT
  | T_LIST
  | T_INT
  | T_FLOAT
  | T_DARR
  | T_BOOL
  | T_ARR
  | TYVAR of (string)
  | TYPE
  | TRUE
  | TO
  | TIMESDOT
  | TIMES
  | TILDE
  | THEN
  | STRING of (string)
  | SEMICOLON
  | SELECTOR of (string)
  | RPAREN
  | REGION
  | REF
  | RBRACK
  | RBRACE
  | RBAR
  | PLUSDOT
  | PLUS
  | PIPE
  | PERCENT
  | OR
  | OF
  | NEQ
  | MINUSDOT
  | MINUS
  | MATCH
  | LT
  | LPAREN
  | LET
  | LEQ
  | LBRACK
  | LBRACE
  | LBAR
  | INT of (int)
  | IN
  | IF
  | ID of (string)
  | GT
  | GEQ
  | FUN
  | FOR
  | FLOAT of (float)
  | FALSE
  | EQUAL
  | EOF
  | ELSE
  | DOT
  | DONE
  | DO
  | DIVDOT
  | DIV
  | CONS
  | COMMA
  | COLON
  | COLEQ
  | CMD
  | CARET
  | BELOW_SEMI
  | BELOW_BAR
  | BAR
  | BANG
  | ARROW
  | AND

(* This exception is raised by the monolithic API functions. *)

exception Error

(* The monolithic API. *)

val prog: (Lexing.lexbuf -> token) -> Lexing.lexbuf -> (Ast.program)
