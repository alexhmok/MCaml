(* source_include.ml — pre-lex `include "path"` splicing.

   MCaml has no module system (G3 is future work); library reuse has
   been literal concatenation (`cat lib/math.mcaml prog.mcaml | ./mcaml`).
   This pass gives programs a first-class way to say the same thing: a
   line consisting of exactly

     include "relative/or/absolute/path.mcaml"

   is replaced, before the lexer ever runs, by the (recursively
   expanded) contents of that file. Semantics are deliberately those of
   `cat`, nothing more:

   - Relative paths resolve against the INCLUDING file's directory
     (stdin input resolves against the cwd).
   - Each file is spliced at most once per compile (`#pragma once`
     style), keyed by absolute path — a second `include` of the same
     file, directly or via a cycle, expands to nothing. This is also
     what makes include cycles terminate.
   - A missing file raises Failure ("include: cannot open ..."), which
     main.ml's Failure handler reports and exits 2 on, like every other
     pipeline rejection.
   - Declaration order still matters exactly as with concatenation:
     include a library before using its names.

   Recognition is strictly line-wise: the directive must be alone on
   its line (leading/trailing whitespace allowed). `include` is not an
   MCaml keyword and two adjacent expressions are never valid syntax,
   so no legal program line can match. One documented sharp edge: the
   lexer allows string literals to span newlines, so an include-shaped
   line INSIDE a multi-line string would be spliced — don't do that
   (real cmd! strings are single-line Minecraft commands). *)

(* If [line] is exactly `include "<path>"` (mod surrounding whitespace),
   return the path. *)
let parse_directive (line : string) : string option =
  let s = String.trim line in
  if String.starts_with ~prefix:"include" s then begin
    let rest = String.sub s 7 (String.length s - 7) in
    (* Require whitespace after the keyword so an identifier like
       `included_thing` can never match. *)
    if rest = "" || not (rest.[0] = ' ' || rest.[0] = '\t') then None
    else
      let rest = String.trim rest in
      let n = String.length rest in
      if n >= 2 && rest.[0] = '"' && rest.[n - 1] = '"'
         && not (String.contains (String.sub rest 1 (n - 2)) '"')
      then Some (String.sub rest 1 (n - 2))
      else None
  end
  else None

let absolutize (dir : string) (path : string) : string =
  let full = if Filename.is_relative path then Filename.concat dir path
             else path in
  if Filename.is_relative full then Filename.concat (Sys.getcwd ()) full
  else full

let read_file (path : string) : string =
  let ic =
    try open_in_bin path
    with Sys_error _ ->
      failwith (Printf.sprintf "include: cannot open \"%s\"" path)
  in
  let contents = really_input_string ic (in_channel_length ic) in
  close_in ic;
  contents

let rec expand_text (visited : (string, unit) Hashtbl.t) (dir : string)
    (text : string) : string =
  String.split_on_char '\n' text
  |> List.map (fun line ->
      match parse_directive line with
      | None -> line
      | Some path ->
          let full = absolutize dir path in
          if Hashtbl.mem visited full then ""
          else begin
            Hashtbl.add visited full ();
            expand_text visited (Filename.dirname full) (read_file full)
          end)
  |> String.concat "\n"

(* Expand every include directive in [text]. [dir] is the base for
   relative paths at the top level (the including file's directory;
   pass the cwd for stdin input). *)
let expand ?(dir : string = Sys.getcwd ()) (text : string) : string =
  expand_text (Hashtbl.create 8) dir text
