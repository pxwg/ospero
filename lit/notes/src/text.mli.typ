#import "/reader/book.typ": card-source, chunk
#show: card-source

= 语言标记文本 <core:src:text.mli>

在@local-data[]中，我们不构造公共富文本 AST，而是把标题与正文片段按原样保留为字符串，并附带开放的语言标签 `Language.t`，由下游渲染器或二次解析器按各自语言解释。源码位置不放在这里，而是通过 @core:src:provenance.mli[Provenance] 独立附着，具体实现见 @core:src:text.ml[text.ml]。

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
