(* closure_layout.ml — Phase F5: whole-program closure-shape table.

   Computed once in main.ml, after [Closure_spec.run] (§13.12 decision
   5's own framing: "after F3's whole-program escape analysis has
   enumerated every Escaping closure shape") AND after [Monomorphize.run].
   The ordering relative to monomorphize is load-bearing: [compute] skips
   is_template functions, so running before monomorphize would miss every
   IClosureMake inside an array-parameterized template's clones and
   [code_of] would crash on them at codegen — see the long comment at the
   call site in main.ml for the full story (this was a real bug, not a
   hypothetical).

   Scans every non-template [cfg_func] for [IClosureMake] instructions and
   assigns each distinct lambda-helper name a dense, whole-program integer
   `code` (§13.12 decision 4's `-2`-tagged cell's `code` field) in
   alphabetical order for determinism — a new global table, lambda-helper
   name -> code, per the F5 kickoff's item 1 (NOT a hash/intern of the
   name). This may be a superset of what ultimately survives per-function
   M3a DCE during Phase 3 (that DCE hasn't run yet at this point in the
   pipeline) — harmless: an unreached code just means [mcaml:apply]'s
   dispatch chain carries one extra, never-taken branch and
   [apply_dispatch_<code>] never gets called. Every actually-surviving
   [IClosureMake]'s fname is guaranteed to be present (this table is
   computed from a superset snapshot), so codegen lookups never fail.

   Also derives the two whole-program constants F5 needs:
   - [k_max_captured]: the max env-field count across every shape, feeding
     cost.ml's IApply formula (§13.12 decision 5: "4 + 2 * K_max_captured").
   - [k_max_apply_args]: the max own-arity (args-at-call-site count)
     across every shape. Not needed for codegen correctness (each IApply
     call site already knows its own arg count structurally) but recorded
     for completeness / future diagnostics (F6). *)

type shape = {
  code : int;
  fname : string;
  n_captured : int;   (* env_0 .. env_{n_captured-1} *)
  n_args : int;       (* own arity: the lifted lambda helper's own params,
                          i.e. params.length - n_captured *)
}

type t = {
  shapes : (string, shape) Hashtbl.t;   (* fname -> shape *)
  by_code : shape array;                (* code -> shape, sorted by code *)
  k_max_captured : int;
  k_max_apply_args : int;
}

let empty : t = {
  shapes = Hashtbl.create 0;
  by_code = [||];
  k_max_captured = 0;
  k_max_apply_args = 0;
}

let compute (table : (string, Cfg.cfg_func) Hashtbl.t) : t =
  (* fname -> captured count, first occurrence wins (every occurrence of
     the same fname carries the same captured count — structurally fixed
     by for_lift at the single lexical Closure-construction site that
     produced this lambda helper, §13.12 decision 6 / for_lift.ml). *)
  let captured_of : (string, int) Hashtbl.t = Hashtbl.create 8 in
  Hashtbl.iter (fun _ (cfg : Cfg.cfg_func) ->
    if not cfg.Cfg.is_template then
      Array.iter (fun (b : Cfg.block) ->
        List.iter (fun i -> match i with
          | Cfg.IClosureMake (_, fname, caps) ->
              if not (Hashtbl.mem captured_of fname) then
                Hashtbl.replace captured_of fname (List.length caps)
          | _ -> ()) b.Cfg.instrs
      ) cfg.Cfg.blocks
  ) table;
  if Hashtbl.length captured_of = 0 then empty
  else begin
    let sorted =
      Hashtbl.fold (fun n c acc -> (n, c) :: acc) captured_of []
      |> List.sort (fun (a, _) (b, _) -> compare a b)
    in
    let shapes = Hashtbl.create (List.length sorted) in
    let by_code =
      List.mapi (fun code (fname, n_captured) ->
        let helper =
          match Hashtbl.find_opt table fname with
          | Some h -> h
          | None ->
              failwith
                (Printf.sprintf
                   "closure_layout: lambda helper %s referenced by an \
                    IClosureMake has no fn_table entry" fname)
        in
        let n_args = List.length helper.Cfg.params - n_captured in
        let s = { code; fname; n_captured; n_args } in
        Hashtbl.replace shapes fname s;
        s
      ) sorted
      |> Array.of_list
    in
    let k_max_captured =
      Array.fold_left (fun acc s -> max acc s.n_captured) 0 by_code
    in
    let k_max_apply_args =
      Array.fold_left (fun acc s -> max acc s.n_args) 0 by_code
    in
    { shapes; by_code; k_max_captured; k_max_apply_args }
  end

let code_of (t : t) (fname : string) : int =
  match Hashtbl.find_opt t.shapes fname with
  | Some s -> s.code
  | None ->
      failwith
        (Printf.sprintf
           "closure_layout: %s has no assigned code — internal error, \
            the whole-program table should be a superset of every \
            surviving IClosureMake" fname)
