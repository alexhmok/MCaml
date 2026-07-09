val obj_name : string
val is_comparison : Ast.binop -> bool
val cmp_str : Ast.binop -> string
val op_str : Ast.binop -> string
val cmd_score_set : string -> int -> string
val cmd_score_op : string -> string -> string -> string
val cmd_score_copy : string -> string -> string
val cmd_score_add : string -> int -> string
val store_score_to_storage : string -> string -> string
val read_storage_to_score : string -> string -> string
val stage_idx_arg : string -> string
val call_macro_helper : string -> string
val macro_get : string -> string -> string -> string list
val macro_getter_into : string -> string -> string
val macro_getter_of_path : string -> string
val macro_setter_of_path : string -> string
val cmd_param_sets : string list -> string list
val cmd_score_binop : string -> Ast.binop -> string -> string -> string list
val cmd_arr_lit_const : string -> int list -> string
val cmd_arr_lit_dyn : string -> string list -> string list
val cmd_arr_get_static : string -> string -> int -> string
val cmd_arr_get : string -> string -> string -> string list
val macro_helper_body : string -> string
val cmd_arr_set_static : string -> int -> string -> string
val cmd_arr_set : string -> string -> string -> string list
val macro_setter_body : string -> string
val pool_name : Ast.heap_pool -> string
val pool_next_slot : Ast.heap_pool -> string
val pool_storage_path : Ast.heap_pool -> string
val pool_get_body : Ast.heap_pool -> string
val pool_set_body : Ast.heap_pool -> string
val cmd_heap_alloc_const : string -> Ast.heap_pool -> int -> string list
val cmd_heap_get : string -> Ast.heap_pool -> string -> string -> string list
val cmd_heap_set : Ast.heap_pool -> string -> string -> string -> string list
val objpool_alloc_finish : string -> string list
val objpool_alloc_cells :
  string -> string -> (int -> string) -> string list -> string list
val cmd_cons : string -> string -> string -> string list
val cmd_cons_field : string -> string -> string -> string list
val cmd_cons_head : string -> string -> string list
val cmd_cons_tail : string -> string -> string list
val cons_head_body : string
val cons_tail_body : string
val cmd_adt_alloc : string -> int -> string list -> string list
val cmd_obj_get : string -> string -> string -> string list
val cmd_obj_tag_get : string -> string -> string list
val cmd_obj_field_get : string -> string -> int -> string list
val obj_tag_body : string
val obj_field_body : int -> string
val cmd_closure_make : string -> int -> string list -> string list
val cmd_apply : string -> string list -> string list
val apply_dispatch_body : int list -> string list
val apply_dispatch_trampoline_body : int -> int -> string -> string list
val cmd_tail_jump : string -> string list -> string list
val cmd_call_helper_body_generic :
  slots:string list -> call_cmds:string list -> string list
val cmd_call_helper_body_narrow :
  slots:string list -> target:string -> args:string list -> string list
val cmd_apply_helper_body :
  slots:string list -> cl:string -> args:string list -> string list
val cmd_region_enter : int -> string list
val cmd_region_exit_primitive : int -> string list
val cmd_region_exit_list_int : int -> string -> string list
val region_walker_list_stash_body : string list
val region_walker_list_rebuild_body : string list
val region_truncate_body : string -> int -> string list
val region_truncate_scratch_body : int -> string list
val region_truncate_objpool_body : int -> string list
