(** Located source values for project-specific metadata decoding. *)
type value = Dsl_syntax.value =
  | String of string
  | Int of int
  | Bool of bool
  | List of value Dsl_syntax.located list
  | Record of field list

and field = Dsl_syntax.field = {
  name : string Dsl_syntax.located;
  value : value Dsl_syntax.located;
}

type diagnostic = {
  range : Dsl_syntax.range;
  message : string;
}

(** Custom decoders may report multiple diagnostics.
    [Error []] remains a failure, including inside list and record decoders. *)
type 'a decoder =
  value Dsl_syntax.located -> ('a, diagnostic list) result

val string : string decoder
val int : int decoder
val bool : bool decoder
val list : 'a decoder -> 'a list decoder

type 'a field_rule

val required : string -> 'a decoder -> 'a field_rule
val optional : string -> 'a decoder -> 'a option field_rule
val default : string -> 'a decoder -> 'a -> 'a field_rule

type _ fields =
  | Nil : unit fields
  | Cons : 'a field_rule * 'b fields -> ('a * 'b) fields

(** Absence selects optional/default behavior; present values must decode.
    Duplicate schema names raise [Invalid_argument] at construction.
    Unknown and duplicate input fields are rejected. Diagnostics list structural
    errors first, then field errors in schema order. The builder runs only
    after all fields pass validation. *)
val record : 'a fields -> ('a -> 'b) -> 'b decoder
