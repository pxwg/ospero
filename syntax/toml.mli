(** A TOML reader for metadata and argument blocks. Spans are byte offsets
    into the given text, so a block can be read in place.

    Supported: bare, quoted and dotted keys, [\[table\]] headers, basic and
    literal strings (also multi-line), integers, booleans, arrays and inline
    tables. Floats and dates are kept as [Value.Other]. Arrays of tables are
    reported as unsupported. *)
open Ospero_kernel

(** Return the complete entries before the first syntax error, with its
    diagnostic if present. A field is complete only after its line ends. *)
val parse_prefix :
  file:string -> string -> start:int -> stop:int ->
  Value.field list * Frontend.Diagnostic.t list

val parse :
  file:string -> string -> start:int -> stop:int ->
  (Value.field list, Frontend.Diagnostic.t list) result
