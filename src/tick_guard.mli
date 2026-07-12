val disabled : unit -> bool
val reset_cmd : target_fname:string -> string
val entry_file_name : (string * 'a) list -> string -> string
val run :
  guarded:(string * int) list ->
  (string * string list) list -> (string * string list) list
