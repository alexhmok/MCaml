val entry_file_name : (string * 'a) list -> string -> string
val run :
  guarded:(string * int) list ->
  (string * string list) list -> (string * string list) list
