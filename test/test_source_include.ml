(* Pre-lex include splicing: directive recognition is strictly
   line-wise, files splice once per compile (which is also what makes
   cycles terminate), relative paths resolve against the including
   file's directory, and a missing file raises Failure (main.ml's
   exit-2 arm). *)

let write_file dir name contents =
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  path

let with_temp_dir f =
  let dir = Filename.temp_dir "mcaml_inc" "" in
  f dir

let contains (haystack : string) (needle : string) : bool =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  loop 0

let count_occurrences (haystack : string) (needle : string) : int =
  let n = String.length needle and h = String.length haystack in
  let total = ref 0 in
  for i = 0 to h - n do
    if String.sub haystack i n = needle then incr total
  done;
  !total

let check_parse () =
  let some = Alcotest.(check (option string)) in
  some "plain" (Some "lib/math.mcaml") (Source_include.parse_directive "include \"lib/math.mcaml\"");
  some "whitespace" (Some "a.mcaml") (Source_include.parse_directive "   include\t \"a.mcaml\"  ");
  some "identifier prefix is not a directive" None (Source_include.parse_directive "included_thing");
  some "call is not a directive" None (Source_include.parse_directive "include(\"x\")");
  some "no quotes" None (Source_include.parse_directive "include x.mcaml");
  some "trailing junk" None (Source_include.parse_directive "include \"a\" (* c *)");
  some "embedded quote" None (Source_include.parse_directive "include \"a\"b\"")

let check_passthrough () =
  let src = "fun f(x: int): int = x + 1\nfun main(): int = f(2)\n" in
  Alcotest.(check string) "no directive: identity" src (Source_include.expand src)

let check_splice () =
  with_temp_dir (fun dir ->
    let _ = write_file dir "lib.mcaml" "fun inc(x: int): int = x + 1\n" in
    let src = "include \"lib.mcaml\"\nfun main(): int = inc(41)\n" in
    let out = Source_include.expand ~dir src in
    Alcotest.(check bool) "library body spliced in"
      true (contains out "fun inc" && contains out "fun main"))

let check_nested_and_relative () =
  with_temp_dir (fun dir ->
    let sub = Filename.concat dir "sub" in
    Sys.mkdir sub 0o755;
    let _ = write_file sub "inner.mcaml" "fun inner(): int = 7\n" in
    (* outer includes inner by a path relative to OUTER's own dir *)
    let _ = write_file dir "outer.mcaml"
      "include \"sub/inner.mcaml\"\nfun outer(): int = inner()\n" in
    let out = Source_include.expand ~dir "include \"outer.mcaml\"\n" in
    Alcotest.(check bool) "nested include resolved relative to includer"
      true (contains out "fun inner" && contains out "fun outer"))

let check_once_and_cycle () =
  with_temp_dir (fun dir ->
    (* a includes b, b includes a: must terminate, each spliced once *)
    let _ = write_file dir "a.mcaml" "include \"b.mcaml\"\nfun fa(): int = 1\n" in
    let _ = write_file dir "b.mcaml" "include \"a.mcaml\"\nfun fb(): int = 2\n" in
    let out = Source_include.expand ~dir "include \"a.mcaml\"\ninclude \"a.mcaml\"\n" in
    Alcotest.(check int) "a spliced exactly once" 1 (count_occurrences out "fun fa");
    Alcotest.(check int) "b spliced exactly once" 1 (count_occurrences out "fun fb"))

let check_missing () =
  Alcotest.check_raises "missing file raises Failure"
    (Failure "include: cannot open \"/nonexistent_mcaml_lib.mcaml\"")
    (fun () -> ignore (Source_include.expand "include \"/nonexistent_mcaml_lib.mcaml\""))

let suite =
  [ ("source_include", [
      Alcotest.test_case "directive parsing" `Quick check_parse;
      Alcotest.test_case "no-directive passthrough" `Quick check_passthrough;
      Alcotest.test_case "basic splice" `Quick check_splice;
      Alcotest.test_case "nested + includer-relative" `Quick check_nested_and_relative;
      Alcotest.test_case "once-per-file + cycle termination" `Quick check_once_and_cycle;
      Alcotest.test_case "missing file fails loudly" `Quick check_missing;
    ]) ]
