(* monomorphize.ml — compile-time specialization of functions that take
   array parameters.

   A function with array params is a TEMPLATE: its body's [IArrGet*]
   instructions reference a sentinel aid "#param<i>" that stands for
   whichever array the caller eventually passes. At every call site that
   passes concrete arrays (via knormal's "#arr:<aid>" pseudo argument),
   Monomorphize clones the callee, rewrites the sentinels with the
   concrete aids, drops the array params (and renumbers the remaining
   scalar params), registers the clone as a new entry in the function
   table, and rewrites the call site to point at it.

   The pass iterates to fixed point: specializing a template may create
   calls inside the clone that need further specialization (e.g. one
   template calling another). *)

open Cfg

(* ---- predicates & helpers ---- *)

let is_pseudo_arr (v : vreg) : bool =
  String.length v >= 5 && String.sub v 0 5 = "#arr:"

let aid_of_pseudo (v : vreg) : string =
  (* strip the "#arr:" prefix *)
  String.sub v 5 (String.length v - 5)

let is_sentinel_aid (a : aid) : bool =
  String.length a >= 6 && String.sub a 0 6 = "#param"

let sentinel_index (a : aid) : int =
  (* "#param3" -> 3 *)
  int_of_string (String.sub a 6 (String.length a - 6))

(* ---- cfg deep clone ---- *)

let clone_block (b : block) : block =
  {
    label  = b.label;
    instrs = b.instrs;  (* instructions are immutable records of our own; ok to share until rewrite *)
    term   = b.term;
    preds  = b.preds;
    guards = b.guards;
  }

let clone_cfg (cfg : cfg_func) : cfg_func =
  let new_blocks = Array.map clone_block cfg.blocks in
  { fname       = cfg.fname;
    params      = cfg.params;
    entry       = cfg.entry;
    blocks      = new_blocks;
    slot_count  = cfg.slot_count;
    preheader_instrs = cfg.preheader_instrs;
    is_template = cfg.is_template;
  }

(* ---- specialization of a single clone ----

   Inputs:
     - [cfg]        : a fresh clone of the template
     - [aid_map]    : maps sentinel index to concrete aid
     - [param_remap]: maps old param index -> Some new_index (kept) or None (dropped)
     - [new_fname]  : the clone's new name
     - [new_params] : the clone's new parameter list (arrays dropped)
*)
let specialize_cfg
    (cfg : cfg_func)
    (aid_map : (int, aid) Hashtbl.t)
    (param_remap : int option array)
    (new_fname : string)
    (new_params : (string * Ast.typ) list) : cfg_func =
  let rewrite_aid (a : aid) : aid =
    if is_sentinel_aid a then
      let idx = sentinel_index a in
      try Hashtbl.find aid_map idx
      with Not_found ->
        failwith (Printf.sprintf
          "monomorphize: unfilled sentinel %s in clone %s" a new_fname)
    else a
  in
  let rewrite_param_vreg (v : vreg) : vreg =
    if is_pseudo_arr v then begin
      (* Pseudo-arr arg for an ICall to another template. If the inner
         aid is a sentinel for one of OUR array params, rewrite it to
         the concrete aid. A later mono iteration will then specialize
         the nested call correctly. *)
      let inner = aid_of_pseudo v in
      if is_sentinel_aid inner then
        let idx = sentinel_index inner in
        (match Hashtbl.find_opt aid_map idx with
         | Some concrete -> "#arr:" ^ concrete
         | None -> v)
      else v
    end else
    match param_index v with
    | Some old_idx ->
        (match param_remap.(old_idx) with
         | Some new_idx -> Printf.sprintf "param_%d" new_idx
         | None ->
             failwith (Printf.sprintf
               "monomorphize: stray %s in %s (array param)" v new_fname))
    | None -> v
  in
  let orig_fname = cfg.fname in
  let rewrite_instr (i : instr) : instr =
    (* Two layers. First, every vreg operand goes through
       rewrite_param_vreg via the shared walker — this includes ICall's
       pseudo-arr "#arr:" args (kept so a later mono iteration can
       specialize the nested call; sentinel inner aids become concrete
       there; the call target is deliberately not renamed here).
       Second, the aid field on the six static-array constructors goes
       through rewrite_aid — dynamic-heap/cons/ADT/closure ops carry no
       static-array aid (pool enums are opaque), so the walker alone
       covers them. *)
    let i = map_instr_vregs rewrite_param_vreg i in
    match i with
    | IArrLitConst (id, ints) -> IArrLitConst (rewrite_aid id, ints)
    | IArrLitDyn (id, temps) -> IArrLitDyn (rewrite_aid id, temps)
    | IArrGetStatic (d, id, k) -> IArrGetStatic (d, rewrite_aid id, k)
    | IArrGet (d, id, idx) -> IArrGet (d, rewrite_aid id, idx)
    | IArrSetStatic (id, k, vr) -> IArrSetStatic (rewrite_aid id, k, vr)
    | IArrSet (id, idx, vr) -> IArrSet (rewrite_aid id, idx, vr)
    | _ -> i
  in
  let rewrite_term (t : terminator) : terminator =
    let v = rewrite_param_vreg in
    match t with
    | TRet | TUnreachable | TJump _ -> t
    | TBranch (c, lt, le, lj) -> TBranch (v c, lt, le, lj)
    | TTail (f, args) ->
        (* TTail is a self-tail-call produced by TCO. In the clone, the
           self name changes and array args are dropped entirely. *)
        let target = if f = orig_fname then new_fname else f in
        let new_args =
          List.filter_map (fun a ->
            let a' = v a in
            if is_pseudo_arr a' then None else Some a'
          ) args
        in
        TTail (target, new_args)
  in
  Array.iter (fun (b : block) ->
    b.instrs <- List.map rewrite_instr b.instrs;
    b.term <- rewrite_term b.term;
    b.guards <- List.map (fun (vr, p) -> (rewrite_param_vreg vr, p)) b.guards
  ) cfg.blocks;
  { cfg with fname = new_fname; params = new_params; is_template = false }

(* ---- find-and-rewrite one call ----

   Given a caller and a pseudo-call, build the specialization key, reuse
   an existing clone if one exists for this key, otherwise create one.
   Returns the rewritten instruction. *)

let mangle_name (fname : string) (aids : string list) : string =
  fname ^ "__" ^ (String.concat "_" aids)

(* Extract the mapping param_index -> concrete aid (for array params only)
   from the call arguments. Also returns the subset of args that are
   scalar vregs (arrays dropped). *)
let extract_maps
    (callee_params : (string * Ast.typ) list)
    (call_args : vreg list)
  : (int * aid) list * vreg list =
  let paired = List.combine (List.mapi (fun i p -> (i, p)) callee_params) call_args in
  List.fold_left (fun (amap, scalars) ((idx, (_, ty)), arg) ->
    match ty with
    | Ast.TArrStatic _ | Ast.TMat _ ->
        if not (is_pseudo_arr arg) then
          failwith (Printf.sprintf
            "monomorphize: callee expects array at param %d, got %s" idx arg);
        ((idx, aid_of_pseudo arg) :: amap, scalars)
    | _ ->
        if is_pseudo_arr arg then
          failwith (Printf.sprintf
            "monomorphize: pseudo array arg at scalar param %d" idx);
        (amap, arg :: scalars)
  ) ([], []) paired
  |> fun (a, s) -> (List.rev a, List.rev s)

let ensure_clone
    (table : (string, cfg_func) Hashtbl.t)
    (template_name : string)
    (aid_map_list : (int * aid) list)
    (clones : (string, unit) Hashtbl.t) : string =
  let aid_strs = List.map snd aid_map_list in
  let clone_name = mangle_name template_name aid_strs in
  if Hashtbl.mem clones clone_name then clone_name
  else begin
    let template = Hashtbl.find table template_name in
    let cfg = clone_cfg template in
    (* aid_map: sentinel idx -> concrete aid *)
    let aid_map = Hashtbl.create 4 in
    List.iter (fun (idx, aid) -> Hashtbl.replace aid_map idx aid) aid_map_list;
    (* Build param_remap and new params list. *)
    let n = List.length template.params in
    let remap = Array.make n None in
    let new_params_rev = ref [] in
    let counter = ref 0 in
    List.iteri (fun i (pname, ty) ->
      match ty with
      | Ast.TArrStatic _ | Ast.TMat _ -> ()
      | _ ->
          remap.(i) <- Some !counter;
          incr counter;
          new_params_rev := (pname, ty) :: !new_params_rev
    ) template.params;
    let new_params = List.rev !new_params_rev in
    let clone = specialize_cfg cfg aid_map remap clone_name new_params in
    Hashtbl.replace table clone_name clone;
    Hashtbl.add clones clone_name ();
    clone_name
  end

let rewrite_caller
    (table : (string, cfg_func) Hashtbl.t)
    (caller : cfg_func)
    (clones : (string, unit) Hashtbl.t)
    (progress : bool ref) : unit =
  Array.iter (fun (b : block) ->
    b.instrs <- List.map (fun instr ->
      match instr with
      | ICall (d, fname, args)
        when List.exists is_pseudo_arr args
             && Hashtbl.mem table fname ->
          let callee = Hashtbl.find table fname in
          let (aid_map_list, scalar_args) =
            extract_maps callee.params args
          in
          let clone_name = ensure_clone table fname aid_map_list clones in
          progress := true;
          ICall (d, clone_name, scalar_args)
      | _ -> instr
    ) b.instrs
  ) caller.blocks

let run (table : (string, cfg_func) Hashtbl.t) : unit =
  let clones : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let progress = ref true in
  let iter_cap = ref 16 in
  while !progress && !iter_cap > 0 do
    decr iter_cap;
    progress := false;
    let names = Hashtbl.fold (fun k _ acc -> k :: acc) table [] in
    List.iter (fun name ->
      let cfg = Hashtbl.find table name in
      if cfg.is_template then ()
      else rewrite_caller table cfg clones progress
    ) names
  done
