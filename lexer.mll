{
  open Parser
  open Lexing
  exception SyntaxError of string
  let next_line lexbuf =
    let pos = lexbuf.lex_curr_p in
    lexbuf.lex_curr_p <- { pos with pos_bol = lexbuf.lex_curr_pos; pos_lnum = pos.pos_lnum + 1 }
}

let white = [' ' '\t']+
let newline = '\r' | '\n' | "\r\n"
let int = '-'? ['0'-'9']+
let float = '-'? ['0'-'9']+ '.' ['0'-'9']*
let id = ['a'-'z' 'A'-'Z' '_'] ['a'-'z' 'A'-'Z' '0'-'9' '_']*
let selector = '@' ['a' 'e' 'p' 'r' 's'] ('[' [^ ']']* ']')?

rule read = parse
  | white    { read lexbuf }
  | newline  { next_line lexbuf; read lexbuf }
  
  (* FIX: Ignore comments *)
  | "(*"     { read_comment lexbuf }

  | int      { INT (int_of_string (Lexing.lexeme lexbuf)) }
  | float    { FLOAT (float_of_string (Lexing.lexeme lexbuf)) }
  | "true"   { TRUE }
  | "false"  { FALSE }
  | "let"    { LET }
  | "in"     { IN }
  | "if"     { IF }
  | "then"   { THEN }
  | "else"   { ELSE }
  | "fun"    { FUN }
  | "val"    { VAL }
  | "cmd!"   { CMD }
  | "ref"    { REF }
  | "for"    { FOR }
  | "to"     { TO }
  | "do"     { DO }
  | "done"   { DONE }
  | "int"    { T_INT }
  | "float"  { T_FLOAT }
  | "bool"   { T_BOOL }
  | "unit"   { T_UNIT }
  | "sel"    { T_SEL }
  | "pos"    { T_POS }
  | "arr"    { T_ARR }
  | "mat"    { T_MAT }
  | "list"   { T_LIST }
  | "darr"   { T_DARR }
  | "region" { REGION }
  | "type"   { TYPE }
  | "match"  { MATCH }
  | "with"   { WITH }
  | "of"     { OF }
  | "->"     { ARROW }
  | selector { SELECTOR (Lexing.lexeme lexbuf) }
  | "~"      { TILDE }
  | "^"      { CARET }
  | "|>"     { PIPE }
  | "[|"     { LBAR }
  | "|]"     { RBAR }
  | "["      { LBRACK }
  | "]"      { RBRACK }
  | "("      { LPAREN }
  | ")"      { RPAREN }
  (* D8: record braces + field-access dot. Safe w.r.t. floats: ocamllex
     longest-match keeps `0.5` a FLOAT token (digits '.' digits* beats
     INT then DOT); selector dots only occur inside the bracketed part
     of the selector token. *)
  | "{"      { LBRACE }
  | "}"      { RBRACE }
  | "."      { DOT }
  | ","      { COMMA }
  | "::"     { CONS }
  | ":"      { COLON }
  | ";"      { SEMICOLON }
  | "="      { EQUAL }
  | "+"      { PLUS }
  | "-"      { MINUS }
  | "*"      { TIMES }
  | "/"      { DIV }
  | "%"      { PERCENT }
  | "<"      { LT }
  | ">"      { GT }
  | "<="     { LEQ }
  | ">="     { GEQ }
  | "!="     { NEQ }
  | "&&"     { AND }
  | "||"     { OR }
  | "|"      { BAR }
  | ":="     { COLEQ }
  | "!"      { BANG }
  | id       { ID (Lexing.lexeme lexbuf) }
  | '"'      { read_string (Buffer.create 17) lexbuf }
  | _ { raise (SyntaxError ("Unexpected char: " ^ Lexing.lexeme lexbuf)) }
  | eof      { EOF }

(* String Reader *)
and read_string buf = parse
  | '"'       { STRING (Buffer.contents buf) }
  | '\\' '/'  { Buffer.add_char buf '/'; read_string buf lexbuf }
  | '\\' '"'  { Buffer.add_char buf '"'; read_string buf lexbuf }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_string buf lexbuf }
  | '\\' 'b'  { Buffer.add_char buf '\b'; read_string buf lexbuf }
  | '\\' 'f'  { Buffer.add_char buf '\012'; read_string buf lexbuf }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_string buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_string buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_string buf lexbuf }
  | [^ '"' '\\']+ { Buffer.add_string buf (Lexing.lexeme lexbuf); read_string buf lexbuf }
  | _ { raise (SyntaxError ("Illegal string char: " ^ Lexing.lexeme lexbuf)) }
  | eof { raise (SyntaxError ("String not terminated")) }

(* FIX: Comment Reader (Recursive) *)
and read_comment = parse
  | "*)"     { read lexbuf }
  | newline  { next_line lexbuf; read_comment lexbuf }
  | _        { read_comment lexbuf }
  | eof      { raise (SyntaxError ("Comment not terminated")) }