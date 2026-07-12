let () =
  Alcotest.run "mcaml"
    (Test_const_fold.suite @ Test_codegen_helpers.suite
    @ Test_codegen_cfg.suite @ Test_deadval.suite
    @ Test_dominators.suite @ Test_liveness.suite
    @ Test_source_include.suite @ Test_parser_g4b.suite)
