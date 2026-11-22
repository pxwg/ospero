#import "/reader/book.typ": card-source, chunk
#show: card-source

= provenance.mli <core:src:provenance.mli>

#chunk(id: <source-core-src-provenance-mli>)[
```ocaml
(** Positions in the input snapshot that produced an observation.
    Offsets are zero-based bytes; [stop] is exclusive. Conversion to editor
    coordinates belongs to the frontend adapter. *)
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

val located : ?span:span -> 'a -> 'a located

(** Transform a value while preserving its occurrence's location.
    This does not infer provenance for newly generated objects. *)
val map : ('a -> 'b) -> 'a located -> 'b located
```
]

#chunk(id: <file-core-src-provenance-mli>, target: "core/src/provenance.mli")[
```ocaml
<<source-core-src-provenance-mli>>
```
]
