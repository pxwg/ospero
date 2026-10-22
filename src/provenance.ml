(** Source locations are interpreted against the input snapshot that produced
    an observation. Offsets are zero-based bytes; [stop] is exclusive.
    Editor encoding conversion belongs to the frontend adapter. *)
type span = {
  file : string;
  start : int;
  stop : int;
}

(** A source occurrence, not a semantic identity.
    [None] means no direct source location is known. *)
type 'a located = {
  value : 'a;
  span : span option;
}

let located ?span value = { value; span }

(** Preserve the source occurrence when transforming its value.
    This does not infer provenance for newly generated objects. *)
let map f located = { located with value = f located.value }
