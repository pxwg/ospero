(** Source offsets are zero-based bytes; stop is exclusive. *)
type range = {
  file : string;
  start : int;
  stop : int;
}

type 'a located = {
  value : 'a;
  range : range;
}

(** Restricted data values, before project-specific decoding. *)
type value =
  | String of string
  | Int of int
  | Bool of bool
  | List of value located list
  | Record of field list

and field = {
  name : string located;
  value : value located;
}

type argument =
  | Reference of string
  | String of string

type invocation = {
  name : string located;
  arguments : argument located list;
  body : content located list option;
}

and content =
  | Text of string
  | Typst of string
  | Action of invocation

type label = {
  name : string located;
  identity : string located;
}

type note = {
  target : string located;
  title : string located;
  metadata : value located option;
  body : content located list;
}

type declaration =
  | Label of label
  | Note of note

type file = declaration located list
