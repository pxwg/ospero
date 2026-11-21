#import "/reader/book.typ": card-source, chunk
#show: card-source

= Markdown 默认嵌入 DSL <syntax:lang_markdown.mli>

Markdown 是传播最广的@lml[]，但本身缺少统一的元数据与指令语法。为了开箱即用又不引入自定义内联解析，本适配器只借助两种现有块级容器划出静态子集：紧跟标题的 `zk-meta` 代码围栏承载卡片元数据，`:::zk-<name>` 容器承载具名动作调用，二者内部均使用 TOML。

== 快速开始 <syntax:lang_markdown.mli:quick-start>

一张最小的 Markdown 卡片由标题、`zk-meta` 围栏与可选的 `:::zk-<name>` 指令块组成：

````markdown
# 卡片标题

```zk-meta
id = "note-a"
tags = ["demo"]
```

:::zk-review
```toml zk-args
target = "note-b"
```
补充说明。
:::

## 嵌套子卡片

```zk-meta
id = "note-a-1"
tags = ["sub"]
```

子卡片正文。
````

在 OCaml 侧接入 `Lang.Markdown.adapter`，按需叠加嵌套卡片语法糖：

```ocaml
module Markdown = Ospero.Syntax.Lang.Markdown

let actions =
  Markdown.actions
  |> Markdown.Sugar.nested_card define_action (fun ~contents ~depth:_ -> contents)

let syntax = Ospero.Syntax.configure [ Markdown.adapter ~actions frontend_input ]
```

== 具体规则 <syntax:lang_markdown.mli:rules>

基础声明复用 @syntax:value.mli[] 的 `Value.t`，使 TOML 数组与表直接映射为列表与记录。

#chunk(id: <source-syntax-lang-markdown-mli-initial>)[
  ```ocaml
  open Ospero_kernel
  val language : Text.Language.t
  type value = Value.t
  ```
]

普通标题不声明卡片，只有紧随 `zk-meta` 围栏的标题才参与身份识别。若围栏内 TOML 存在语法错误，仍保留错误前已读出的字段与插入点 `insertion`，让后续诊断能够定位缺失的 `id`。

- `metadata`: `zk-meta` 围栏的解析结果与插入点。
  #chunk(id: <source-syntax-lang-markdown-mli-metadata>)[
    ```ocaml
    type metadata = {
      fields : Value.field list;
      diagnostics : Frontend.Diagnostic.t list;
      insertion : Provenance.span;
    }
    ```
  ]
- `heading`: 供身份规则读取的标题记录；无 `zk-meta` 围栏时 `metadata` 为 `None`。
  #chunk(id: <source-syntax-lang-markdown-mli-heading>)[
    ```ocaml
    type heading = {
      level : int;
      title : string Provenance.located;
      metadata : metadata option;
    }
    ```
  ]

扫描器跳过普通围栏代码块，只在正文提取两类节点：

- `Directive`: `:::` 容器指令。首块若带 `zk-args` 标记则按 TOML 读作参数，余下文本作为正文并递归收集内部指令。
  #chunk(id: <source-syntax-lang-markdown-mli-node-directive>)[
    ```ocaml
    | Directive of {
        name : string Provenance.located;
        arguments : Value.field list Frontend.read;
        body : Text.t Provenance.located option;
        inner : node Provenance.located list;
      }
    ```
  ]
- `Card`: 嵌套子卡片，复用 @syntax:card.mli[] 中的 `Card.nested`。
  #chunk(id: <source-syntax-lang-markdown-mli-node-card>)[
    ```ocaml
    | Card of Card.nested
    ```
  ]

组装得到节点类型与正文规则上下文：

#chunk(id: <source-syntax-lang-markdown-mli-node>)[
  ```ocaml
  type node =
    <<source-syntax-lang-markdown-mli-node-directive>>
    <<source-syntax-lang-markdown-mli-node-card>>
  ```
]

#chunk(id: <source-syntax-lang-markdown-mli-context>)[
  ```ocaml
  type context = value Card.context
  ```
]

语义提取通过 @syntax:rules.mli[] 的三张默认规则表完成，最后由 `adapter` 组装：

- `values`: 按字段类型读取 TOML 字面量。
  #chunk(id: <source-syntax-lang-markdown-mli-rules-values>)[
    ```ocaml
    val values : value Rules.Payload_rules.t
    ```
  ]
- `identities`: 默认规则 `"meta-id"`，取 `zk-meta` 围栏里的字符串字段 `id` 作为卡片 ID。
  #chunk(id: <source-syntax-lang-markdown-mli-rules-identities>)[
    ```ocaml
    val identities : heading Rules.Identity_rules.t
    ```
  ]
- `actions`: 默认规则 `"named-directive"`，匹配 `:::zk-<name>` 容器：
  ````markdown
  :::zk-review
  ```toml zk-args
  target = "b"
  ```
  body
  :::
  ````
  #chunk(id: <source-syntax-lang-markdown-mli-rules-actions>)[
    ```ocaml
    val actions : (node, context) Rules.Action_rules.t
    ```
  ]
- `adapter`: 组装为 `string Syntax.adapter`，各规则表与 `define` 动作名均可替换。
  #chunk(id: <source-syntax-lang-markdown-mli-adapter>)[
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

`Sugar` 提供可选语法糖：

- `nested_card`: 注册 `"nested-card"`，将当前卡片下的子卡片绑定到定义动作：
  ````markdown
  ## 子卡片

  ```zk-meta
  id = "sub-id"
  ```

  子卡片正文。
  ````
  #chunk(id: <source-syntax-lang-markdown-mli-sugar-nested-card>)[
    ```ocaml
    val nested_card :
      'args Syntax.Action.t ->
      (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
      (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
    ```
  ]

组装为 `Sugar` 模块签名：

#chunk(id: <source-syntax-lang-markdown-mli-sugar>)[
  ```ocaml
  module Sugar : sig
    <<source-syntax-lang-markdown-mli-sugar-nested-card>>
  end
  ```
]

按顺序组合为 `syntax/lang_markdown.mli`：

#chunk(id: <file-syntax-lang-markdown-mli>, target: "syntax/lang_markdown.mli")[
  ```ocaml
  <<source-syntax-lang-markdown-mli-initial>>
  <<source-syntax-lang-markdown-mli-metadata>>
  <<source-syntax-lang-markdown-mli-heading>>
  <<source-syntax-lang-markdown-mli-node>>

  <<source-syntax-lang-markdown-mli-context>>

  <<source-syntax-lang-markdown-mli-rules-values>>
  <<source-syntax-lang-markdown-mli-rules-identities>>
  <<source-syntax-lang-markdown-mli-rules-actions>>
  <<source-syntax-lang-markdown-mli-adapter>>

  <<source-syntax-lang-markdown-mli-sugar>>
  ```
]
