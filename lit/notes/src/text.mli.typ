#import "/reader/book.typ": chunk

= text.mli <core:src:text.mli>

#chunk(id: <source-core-src-text-mli>)[
```ocaml
(** Renderable text tagged with the language that interprets it.
    Source locations are attached separately with [Provenance.located]. *)

(** A markup language naming how text is to be read, such as Typst or Org.
    Languages are open: projects choose their own names. *)
module Language : sig
  type t

  (** Accept any non-empty string. Names are compared exactly. *)
  val of_string : string -> (t, string) result

  val to_string : t -> string

  val equal : t -> t -> bool

  val compare : t -> t -> int
end

type t = {
  text : string;
  language : Language.t;
}
```
]

#chunk(id: <file-core-src-text-mli>, target: "core/src/text.mli")[
```ocaml
<<source-core-src-text-mli>>
```
]
