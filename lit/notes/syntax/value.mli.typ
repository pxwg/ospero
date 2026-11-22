#import "/reader/book.typ": card-source, chunk
#show: card-source

= 公共字面量值 <syntax:value.mli>

在字段声明为原始字面量赋予项目类型之前，@syntax:lang_typst.mli[Typst] 参数、Typst 元数据与 @syntax:lang_markdown.mli[Markdown] TOML 块共用本模块定义的字面量表示 `t`，并通过 `rules` 提供默认的 @syntax:rules.mli-payload[值规则表]，具体实现见 @syntax:value.ml[value.ml]。

#chunk(id: <source-syntax-value-mli>)[
  ```ocaml
  (** Literal values written in a source, before a field declaration gives
      them a type. Typst arguments, Typst metadata and Markdown TOML share it. *)
  open Ospero_kernel

  type t =
    | String of string
    | Int of int
    | Bool of bool
    | Array of t Provenance.located list
    | Table of field list
        (** Fields keep their source order, including duplicate keys. *)
    | Contents of Text.t
    | Label of string
    | Other of string
        (** A literal without a default reading, or an expression that needs
            evaluation, kept verbatim. *)

  and field = string Provenance.located * t Provenance.located

  (** Default readings of [String], [Int], [Bool], [Contents], [Array] as a list
      and [Table] as a record. Other values match no rule. *)
  val rules : t Rules.Payload_rules.t

  (** Fields in the form expected by [Payload_rules.read_arguments]. *)
  val fields : field list -> t Rules.Payload_rules.field list
  ```
]

#chunk(id: <file-syntax-value-mli>, target: "syntax/value.mli")[
  ```ocaml
  <<source-syntax-value-mli>>
  ```
]
