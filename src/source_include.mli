(* Pre-lex `include "path"` splicing — see source_include.ml for the
   directive's exact semantics (line-wise, once-per-file, cat-like). *)

(* Exposed for unit tests; returns the path when the line is exactly an
   include directive (mod surrounding whitespace). *)
val parse_directive : string -> string option

(* Expand every include directive in the text. [dir] is the base for
   relative paths at the top level (default: cwd, the stdin case).
   Raises Failure on a missing file. *)
val expand : ?dir:string -> string -> string
