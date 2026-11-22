#import "/reader/book.typ": card-source, chunk
#show: card-source

= TOML 元数据读取器 <syntax:toml.mli>

本模块为 @syntax:lang_typst.mli[Typst] 与 @syntax:lang_markdown.mli[Markdown] 适配器提供就地读取 TOML 元数据块与参数块的能力，产出带字节偏移的 @syntax:value.mli[Value.field] 列表，具体实现见 @syntax:toml.ml[toml.ml]。其中 `parse_prefix` 在遇到首处语法错误前仍会交出已读完的字段与诊断，便于上层做局部容错。

#chunk(id: <source-syntax-toml-mli>)[
  ```ocaml
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
  ```
]

#chunk(id: <file-syntax-toml-mli>, target: "syntax/toml.mli")[
  ```ocaml
  <<source-syntax-toml-mli>>
  ```
]
