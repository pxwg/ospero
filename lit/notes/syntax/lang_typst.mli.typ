#import "/reader/book.typ": card-source, chunk
#show: card-source

= Typst 默认嵌入 DSL <syntax:lang_typst.mli>

#link("https://typst.app/")[Typst] 作为声称的 `LaTeX` 替代品，是一款新派的排版语言，支持更为优雅的数学排版以及增量渲染——这使得编辑体验得到大幅增加，不必再像编写 `LaTeX` 那般写几个字符就要等待很长时间才能获取排版结果。

`Typst` 作为一款图灵完备的排版语言，并不适合作为“适合机器处理”的@lml。然而，有鉴于其在编辑层面的良好体验，我们事实上可通过约定一个“标记子集”，将其作为一款@lml[]被使用。

== 快速开始 <syntax:lang_typst.mli-1>

一张最小的 Typst 卡片由三部分组成：标题前的 `///` TOML 元数据块、带 `<id>` 的标题，以及正文里的引用或 `#zk.<action>` 调用：

```typst
/// tags = ["demo"]
= 卡片标题 <note-a>

正文里可以用 @note-b 建立引用，也可以用具名调用声明动作：
#zk.review(target: "note-b")[补充说明]

/// tags = ["sub"]
== 嵌套子卡片 <note-a-1>
子卡片正文。
/// end
```

在 OCaml 侧，直接把 `Lang.Typst.adapter` 接入前端输入，并按需叠加 `Sugar` 即可：

```ocaml
module Typst = Ospero.Syntax.Lang.Typst

let actions =
  Typst.actions
  |> Typst.Sugar.references link_action Fun.id
  |> Typst.Sugar.include_note embed_action Fun.id
  |> Typst.Sugar.nested_card define_action (fun ~contents ~depth:_ -> contents)

let syntax = Ospero.Syntax.configure [ Typst.adapter ~actions frontend_input ]
```

== 具体规则 <syntax:lang_typst.mli-2>

下面我们就结合函数签名来介绍一下这个语言的完整撰写规则。

#chunk(id: <source-syntax-lang-typst-mli-initial>)[
  ```ocaml
  open Ospero_kernel
  val language : Text.Language.t
  type value = Value.t
  ```
]

首先是 Typst @lml[]子集的标题规范。我们在这里约定，标题、metadata 和 `id` 的标记采用如下形式：

```typst
/// metadata-for-title-1
= Title-1 <id>

/// metadata-for-title-2
== Title-2 <id-1>
...
```

其中根据 #link("https://typst.app/docs/reference/model/heading/")[Typst 的 heading 规范]，等号数目对应 heading 的 level。这对应着如下实现。

#chunk(id: <source-syntax-lang-typst-mli-heading>)[
  ```ocaml
  type heading = {
    level : int;
    title : string Provenance.located;
    label : string Provenance.located option;
    metadata : Value.field list Frontend.read option;
  }
  ```
]

标题与卡片边界的补充约定：

- ```typ ///``` 块写 TOML 元数据；无块时 `metadata` 为 `None`，TOML 出错时记录错误但仍声明卡片。
- 标题行上打开的函数调用会延续到闭合行，多行仍算一个标题：
  ```typst
  /// tags = ["typst"]
  = #text(
    "Title",
  ) <id>
  ```
- 单独一行 ```typ /// end``` (或 ```typ /// end <id>```) 提前结束最内层未关闭的卡片。这很适合我们撰写一些片段性质的可复用文本。

扫描器会跳过原始代码块、普通注释、数学公式及顶层语句体，只提取五类节点：

- `Call`: 函数调用，记录调用路径、参数、尾随内容块及块内子节点。
  #chunk(id: <source-syntax-lang-typst-mli-node-call>)[
    ```ocaml
    | Call of {
        name : string Provenance.located;
        arguments : argument list;
        trailing : Text.t Provenance.located list;
        inner : node Provenance.located list;
      }
    ```
  ]
- `Reference`: 引用，如 `@b`、`@b[]` 或 `@b[shown]`。空括号与省略括号等价。
  #chunk(id: <source-syntax-lang-typst-mli-node-ref>)[
    ```ocaml
    | Reference of {
        target : string Provenance.located;
        supplement : Text.t Provenance.located option;
            (** Omitted and empty supplements are both [None]. *)
      }
    ```
  ]
- `Card`: 嵌套子卡片，复用 @syntax:card.mli[] 中的 `Card.nested` 。
  #chunk(id: <source-syntax-lang-typst-mli-node-card>)[
    ```ocaml
    | Card of Card.nested
    ```
  ]
- `Label`: 标记中的 `<name>` (含标题末尾的 label)；默认只有带 `///` 块的标题 label 会作为卡片 ID。
  #chunk(id: <source-syntax-lang-typst-mli-node-label>)[
    ```ocaml
    | Label of string
    ```
  ]
- `Statement`: 顶层语句 (如 `#let`, `#import`, `#set`, `#show`)，不读内容， `#import` 额外记录字面路径。
  #chunk(id: <source-syntax-lang-typst-mli-node-statement>)[
    ```ocaml
    | Statement of {
        keyword : string;
        path : string Provenance.located option;
      }
    ```
  ]

组装起来就得到所需要被分析的节点类型：

#chunk(id: <source-syntax-lang-typst-mli-node>)[
  ```ocaml
  type node =
    <<source-syntax-lang-typst-mli-node-call>>
    <<source-syntax-lang-typst-mli-node-ref>>
    <<source-syntax-lang-typst-mli-node-card>>
    <<source-syntax-lang-typst-mli-node-label>>
    <<source-syntax-lang-typst-mli-node-statement>>

  <<source-syntax-lang-typst-mli-argument>>
  ```
]

参数 `argument` 区分具名与位置参数 (位置参数 `name = None`)，值按 @syntax:value.mli[] 的 `Value.t` 静态读取 (字符串、布尔、整数、数组、字典、label、内容块)，需运行期求值的参数会报错 (这个约束保证了静态性)。

#chunk(id: <source-syntax-lang-typst-mli-argument>)[
  ```ocaml
  and argument = {
    name : string Provenance.located option;
    value : value Provenance.located;
  }
  ```
]

文档扫描与遍历由以下接口提供：

- `context`: 正文规则的运行上下文，复用 @syntax:card.mli[] 中的 `Card.context`。
  #chunk(id: <source-syntax-lang-typst-mli-context>)[
    ```ocaml
    type context = value Card.context
    ```
  ]
- `scan`: 扫描文档并返回 @syntax:card.mli[] 的 `Card.outline` (适配器与渲染器共用)。
  #chunk(id: <source-syntax-lang-typst-mli-scan-fn>)[
    ```ocaml
    val scan : file:string -> string -> (heading, value, node) Card.outline
    ```
  ]
- `children`: 返回 `Call` 内容块内的子节点。
  #chunk(id: <source-syntax-lang-typst-mli-children>)[
    ```ocaml
    val children : node -> node Provenance.located list
    ```
  ]

语义提取通过 @syntax:rules.mli[] 的三张默认规则表完成，最后由 `adapter` 组装：

- `values`: 按字段类型读取 `Value.t` 字面量。
  #chunk(id: <source-syntax-lang-typst-mli-rules-values>)[
    ```ocaml
    val values : value Rules.Payload_rules.t
    ```
  ]
- `identities`: 默认规则 `"heading-label"`，取带 `///` 块标题末尾的 `<label>` 作为卡片 ID。
  #chunk(id: <source-syntax-lang-typst-mli-rules-identities>)[
    ```ocaml
    val identities : heading Rules.Identity_rules.t
    ```
  ]
- `actions`: 默认规则 `"named-call"`，匹配 `#zk.<name>(...)[...]`，只接受具名静态参数和至多一个尾随内容块：
  ```typst
  #zk.review(target: "b")[body]
  ```
  #chunk(id: <source-syntax-lang-typst-mli-rules-actions>)[
    ```ocaml
    val actions : (node, context) Rules.Action_rules.t
    ```
  ]
- `adapter`: 组装为 `string Syntax.adapter` (各规则表和 `define` 动作名均可按需替换)。
  #chunk(id: <source-syntax-lang-typst-mli-adapter>)[
    ```ocaml
    val adapter :
      ?values:value Rules.Payload_rules.t ->
      ?identities:heading Rules.Identity_rules.t ->
      ?actions:(node, context) Rules.Action_rules.t ->
      ?define:string ->
      ('metadata, 'action) Syntax.Frontend_input.t ->
      string Syntax.adapter
    ```
  ]


`Sugar` 提供可选语法糖，将常见 Typst 写法绑定到项目动作：

- `references`: 注册 `"at-reference"` (`@b`) 与 `"ref-call"` (`#ref(<b>)`)，补充文本留给渲染：
  ```typst
  参见 @note-a 或 #ref(<note-b>)。
  ```
  #chunk(id: <source-syntax-lang-typst-mli-sugar-references>)[
    ```ocaml
    val references :
      'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
      (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
    ```
  ]
- `include_note`: 注册 `"include-note"`，匹配 `#include-note[@b]` 或 `#include-note([@b], ...)`，内容块须恰有一个 `@reference`，展示选项留给渲染：
  ```typst
  #include-note[@note-c]
  ```
  #chunk(id: <source-syntax-lang-typst-mli-sugar-include-note>)[
    ```ocaml
    val include_note :
      'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
      (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
    ```
  ]
- `nested_card`: 注册 `"nested-card"`，将当前卡片下的子卡片绑定到定义动作，传入 `contents` 与层级差 `depth`：
  ```typst
  /// tags = ["sub"]
  == 子卡片 <sub-id>
  子卡片正文。
  ```
  #chunk(id: <source-syntax-lang-typst-mli-sugar-nested-card>)[
    ```ocaml
    val nested_card :
      'args Syntax.Action.t ->
      (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
      (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
    ```
  ]

组装为 `Sugar` 模块签名：

#chunk(id: <source-syntax-lang-typst-mli-sugar>)[
  ```ocaml
  module Sugar : sig
    <<source-syntax-lang-typst-mli-sugar-references>>
    <<source-syntax-lang-typst-mli-sugar-include-note>>
    <<source-syntax-lang-typst-mli-sugar-nested-card>>
  end
  ```
]

按顺序组合为 `syntax/lang_typst.mli` :

#chunk(id: <file-syntax-lang-typst-mli>, target: "syntax/lang_typst.mli")[
  ```ocaml
  <<source-syntax-lang-typst-mli-initial>>
  <<source-syntax-lang-typst-mli-heading>>
  <<source-syntax-lang-typst-mli-node>>

  <<source-syntax-lang-typst-mli-context>>
  <<source-syntax-lang-typst-mli-scan-fn>>
  <<source-syntax-lang-typst-mli-children>>

  <<source-syntax-lang-typst-mli-rules-values>>
  <<source-syntax-lang-typst-mli-rules-identities>>
  <<source-syntax-lang-typst-mli-rules-actions>>
  <<source-syntax-lang-typst-mli-adapter>>

  <<source-syntax-lang-typst-mli-sugar>>
  ```
]
