(lang dune 3.0)
(name mcaml)

; Generates mcaml.opam from the package stanza below — edit here, then
; `dune build` refreshes the .opam file (checked in so plain
; `opam install . --deps-only` works without a prior dune build).
(generate_opam_files true)

(package
 (name mcaml)
 (allow_empty) ; nothing is opam-installable; the package exists to declare deps
 (synopsis "ML-like language compiling to Minecraft .mcfunction files")
 (depends
  (ocaml (>= 4.14))
  (alcotest :with-test)
  ; menhir/ocamllex output (lexer.ml, parser.ml/.mli) is checked in;
  ; menhir is only needed when modifying parser.mly, hence :dev
  (menhir :dev)))
