(* Dead-val elimination: unreferenced globals are dropped from the
   __globals_init synthesis, and referenced-but-static-only globals
   lose their over-emitted `__g_<name>_get` macro file while keeping
   their init. Dynamic reads (IArrGet) keep both. *)

open Cfg
open Cfg_fixtures

(* One function reading __g_dyn dynamically and __g_stat statically;
   __g_dead is mentioned nowhere. A template function referencing
   __g_tmpl must be ignored (templates are never emitted). *)
let fn_table () =
  let tbl : (string, cfg_func) Hashtbl.t = Hashtbl.create 4 in
  let user =
    mk_func ~fname:"user" ~slot_count:2
      [ mk_block 0
          [ IArrGet ("$r0", "__g_dyn", "param_0");
            IArrGetStatic ("$r1", "__g_stat", 1);
            ICopy ("$ret", "$r0") ]
          TRet ]
  in
  let tmpl =
    { (mk_func ~fname:"tmpl" ~slot_count:1
         [ mk_block 0 [ IArrGet ("$r0", "__g_tmpl", "param_0") ] TRet ])
      with is_template = true }
  in
  Hashtbl.replace tbl "user" user;
  Hashtbl.replace tbl "tmpl" tmpl;
  tbl

let globals =
  [ ("dyn", Ast.TInt, [ 1; 2 ]);
    ("stat", Ast.TInt, [ 3; 4 ]);
    ("dead", Ast.TInt, [ 5; 6 ]);
    ("tmpl", Ast.TInt, [ 7; 8 ]) ]

let check_filter_globals () =
  let referenced, dyn_read = Deadval.collect_refs (fn_table ()) in
  let kept = Deadval.filter_globals referenced globals in
  let names = List.map (fun (n, _, _) -> n) kept in
  Alcotest.(check (list string))
    "unreferenced and template-only vals dropped, order preserved"
    [ "dyn"; "stat" ] names;
  Alcotest.(check bool) "dyn read dynamically" true
    (Hashtbl.mem dyn_read "__g_dyn");
  Alcotest.(check bool) "stat not read dynamically" false
    (Hashtbl.mem dyn_read "__g_stat")

let check_drop_get_files () =
  let _, dyn_read = Deadval.collect_refs (fn_table ()) in
  let files =
    [ ("user", [ "cmd" ]);
      ("__g_dyn_get", [ "macro" ]);
      ("__g_stat_get", [ "macro" ]);
      ("__g_stat_set", [ "macro" ]);   (* setters are never dropped *)
      ("arr3_get", [ "macro" ]) ]      (* non-global getters untouched *)
  in
  let kept = List.map fst (Deadval.drop_dead_get_files dyn_read files) in
  Alcotest.(check (list string)) "only the static-only global getter dropped"
    [ "user"; "__g_dyn_get"; "__g_stat_set"; "arr3_get" ] kept

let suite =
  [ ( "deadval",
      [ Alcotest.test_case "filter_globals" `Quick check_filter_globals;
        Alcotest.test_case "drop_dead_get_files" `Quick check_drop_get_files ]
    ) ]
