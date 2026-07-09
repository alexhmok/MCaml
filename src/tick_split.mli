val default_budget : int
val budget : unit -> int
val has_suffix : string -> string -> bool
val has_prefix : string -> string -> bool
val is_call_helper : string -> bool
val is_prefix_then_digits : string -> string -> bool
val is_helper_file : string -> bool
val split_at : int -> 'a list -> 'a list * 'a list
val split_one :
  budget:int -> string -> string list -> (string * string list) list
val run : (string * string list) list -> (string * string list) list
