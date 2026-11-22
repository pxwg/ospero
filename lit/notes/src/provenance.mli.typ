#import "/reader/book.typ": card-source, chunk
#show: card-source

= 源码溯源 <core:src:provenance.mli>

源码位置与语义身份是两件独立的事：`span` 记录输入快照中的零基字节范围 (行列号换算留给编辑器适配层)，`located` 则允许某些生成对象把位置标为 `None`，从而不为派生内容伪造源码范围。具体实现见 @core:src:provenance.ml[provenance.ml]。

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
