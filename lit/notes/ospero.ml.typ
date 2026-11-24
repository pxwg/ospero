#import "/reader/book.typ": card-source, chunk
#show: card-source

= 项目结构 <ospero.ml>

@home 分为两个组件，一个是负责@local-to-global[]的 `Ospero.Kernel` 组件：

#chunk(id: <source-ospero-ml>)[
  ```ocaml
  module Core = Ospero_kernel
  ```
]

在这个项目中，@local-data[]需要使用各个标记语言中的@embedded-dsl 来实现。原则上，用户可以使用 `Ocaml` 语言编写属于自己的 DSL parser 并实现自己的领域特定语义。因此，另一部份组件将为用户构建项目所需 DSL parser 提供支持，即下列 `Ospero.Syntax` 组件：

#chunk(id: <source-ospero-ml-syntax>)[
  ```ocaml
  module Syntax = struct
    include Ospero_kernel.Syntax
    include Ospero_syntax.Rules
    <<source-ospero-ml-lang>>
  end
  ```
]

不过为了实现有限度的开箱即用，我们内置了 @syntax:lang_typst.mli[`Typst`], @syntax:lang_org.mli[`org-mode`] 和 @syntax:lang_markdown.mli[`Markdown`] 的基本支持。其中前二者的实现是从作者自身的笔记实践中抽取的，而 `Markdown` 的对应实现则是为了让更多用户可以开箱即用而设计的，因此，前二者的实现成熟度与更新频率将明显高于后者 (事实上，因为种种原因，作者并没有使用 `Markdown` 作为自身知识管理系统语言的想法)。

#chunk(id: <source-ospero-ml-lang>)[
  ```ocaml
  module Lang = Ospero_syntax.Lang
  ```
]

#chunk(id: <file-ospero-ml>, target: "ospero.ml")[
  ```ocaml
  <<source-ospero-ml>>

  <<source-ospero-ml-syntax>>
  ```
]
