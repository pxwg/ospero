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
  body : content located list;
}

type declaration =
  | Label of label
  | Note of note

type file = declaration located list
