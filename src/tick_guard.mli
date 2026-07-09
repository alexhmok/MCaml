val default_tick_commands : int
val default_iter_limit_fallback : int
val tick_commands : unit -> int
val legacy_iter_limit_override : unit -> int option
val guard_overhead : int
val max_limit : int
val compute_limit : body_cost:int -> int
val disabled : unit -> bool
val counter_for : string -> string
val guard_cmds : target_fname:string -> limit:int -> string list
val entry_file_name : (string * 'a) list -> string -> string
val prepend_to :
  (string * string list) list ->
  string -> string list -> (string * string list) list
val run :
  guarded:(string * int) list ->
  (string * string list) list -> (string * string list) list
