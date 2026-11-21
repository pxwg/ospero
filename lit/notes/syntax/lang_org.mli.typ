#import "/reader/book.typ": card-source, chunk
#show: card-source

= Org 默认嵌入 DSL <syntax:lang_org.mli>

#link("https://orgmode.org/")[Org-mode] 原生具备标题树、属性抽屉 (`:PROPERTIES:`)、关键字行 (`#+KEY:`) 和块 (`#+begin_...`)，无需发明额外容器即可直接表达卡片、元数据与动作。与 Typst / Markdown 使用 TOML 不同，Org 属性和参数没有独立的字面量语法，因此本适配器保留原始文本，按模式声明的字段类型延迟解码。

== 快速开始 <syntax:lang_org.mli:quick-start>

一张最小的 Org 卡片用 `:ID:` 属性声明身份，其余抽屉属性构成元数据，正文用 `#+zk_*` 关键字或块调用动作，用 `[[id:...]]` 建立链接：

```org
* 卡片标题
:PROPERTIES:
:ID: note-a
:TAGS: [demo, "org mode"]
:END:

参见 [[id:note-b][另一张卡片]]。

#+zk_include: :target note-b

#+begin_zk_review :target note-b
补充说明。
#+end_zk_review

** 嵌套子卡片
:PROPERTIES:
:ID: note-a-1
:END:

子卡片正文。
```

在 OCaml 侧接入 `Lang.Org.adapter` 并按需叠加 `Sugar`：

```ocaml
module Org = Ospero.Syntax.Lang.Org

let actions =
  Org.actions
  |> Org.Sugar.id_link link_action Fun.id
  |> Org.Sugar.include_keyword embed_action Fun.id
  |> Org.Sugar.nested_card define_action (fun ~contents ~depth:_ -> contents)

let syntax = Ospero.Syntax.configure [ Org.adapter ~actions frontend_input ]
```

== 具体规则 <syntax:lang_org.mli:rules>

`value` 就是属性名或 `:key` 之后的原始字符串；读取时按字段类型解释，例如 `:target 2604032336` 在字符串字段中读作字符串而非整数。

#chunk(id: <source-syntax-lang-org-mli-initial>)[
  ```ocaml
  open Ospero_kernel
  open Frontend
  val language : Text.Language.t
  type value = string
  ```
]

标题提取遵循 Org 惯例：自动剥离任务关键字 (取自文件内 `#+TODO:` 等序列，默认 `TODO` / `DONE`)、优先级标记 (如 `[#A]`) 与末尾标签 (如 `:a:b:`)；带 `COMMENT` 的标题及其整棵子树会被忽略。属性键按小写读取，带点号的属性名 (如 `:CAPTURE.TYPE:`) 映射为记录字段的嵌套键。

#chunk(id: <source-syntax-lang-org-mli-heading>)[
  ```ocaml
  type heading = {
    level : int;
    title : string Provenance.located;
    properties : (string Provenance.located * value Provenance.located) list;
  }
  ```
]

扫描器跳过注释行与 `COMMENT` 子树，只提取四类节点 (块内的行永远不视作标题)：

- `Keyword`: `#+KEY: value` 关键字行，`inner` 收集值里的链接。
  #chunk(id: <source-syntax-lang-org-mli-node-keyword>)[
    ```ocaml
    | Keyword of {
        name : string Provenance.located;
        value : value Provenance.located;
        inner : node Provenance.located list;
      }
    ```
  ]
- `Block`: `#+begin_<name>` 块；逐字块 (`src`、`example`、`export`、`comment`) 内部不递归扫描。
  #chunk(id: <source-syntax-lang-org-mli-node-block>)[
    ```ocaml
    | Block of {
        name : string Provenance.located;
        parameters : value Provenance.located;
        contents : Text.t Provenance.located;
        inner : node Provenance.located list;
      }
    ```
  ]
- `Link`: Org 链接，如 `[[id:b]]` 或 `[[id:b][shown]]`。
  #chunk(id: <source-syntax-lang-org-mli-node-link>)[
    ```ocaml
    | Link of {
        path : string Provenance.located;
        description : string Provenance.located option;
      }
    ```
  ]
- `Card`: 嵌套子卡片，复用 @syntax:card.mli[] 中的 `Card.nested`。
  #chunk(id: <source-syntax-lang-org-mli-node-card>)[
    ```ocaml
    | Card of Card.nested
    ```
  ]

组装得到节点类型：

#chunk(id: <source-syntax-lang-org-mli-node>)[
  ```ocaml
  type node =
    <<source-syntax-lang-org-mli-node-keyword>>
    <<source-syntax-lang-org-mli-node-block>>
    <<source-syntax-lang-org-mli-node-link>>
    <<source-syntax-lang-org-mli-node-card>>
  ```
]

文档扫描与遍历由以下接口提供：

- `context`: 正文规则的运行上下文，复用 @syntax:card.mli[] 中的 `Card.context`。
  #chunk(id: <source-syntax-lang-org-mli-context>)[
    ```ocaml
    type context = value Card.context
    ```
  ]
- `scan`: 扫描文档并返回 @syntax:card.mli[] 的 `Card.outline`，适配器与外部消费者共用。
  #chunk(id: <source-syntax-lang-org-mli-scan-fn>)[
    ```ocaml
    val scan : file:string -> string -> (heading, value, node) Card.outline
    ```
  ]
- `children`: 返回关键字值中的链接或非逐字块内的子节点。
  #chunk(id: <source-syntax-lang-org-mli-children>)[
    ```ocaml
    val children : node -> node Provenance.located list
    ```
  ]

语义提取通过 @syntax:rules.mli[] 的三张默认规则表与参数切分函数完成，最后由 `adapter` 组装：

- `values`: 支持字符串、整数、布尔与列表 (`[a, "b c"]` 按逗号分隔，裸列表按空白分隔)，记录类型留给项目规则。
  #chunk(id: <source-syntax-lang-org-mli-rules-values>)[
    ```ocaml
    val values : value Rules.Payload_rules.t
    ```
  ]
- `identities`: 默认规则 `"id-property"`，大小写无关地读取 `:ID:` 属性。
  #chunk(id: <source-syntax-lang-org-mli-rules-identities>)[
    ```ocaml
    val identities : heading Rules.Identity_rules.t
    ```
  ]
- `actions`: 默认规则 `"named-keyword"` 与 `"named-block"`，匹配 `zk_` 前缀：
  ```org
  #+zk_review: :target b

  #+begin_zk_review :target b
  body
  #+end_zk_review
  ```
  #chunk(id: <source-syntax-lang-org-mli-rules-actions>)[
    ```ocaml
    val actions : (node, context) Rules.Action_rules.t
    ```
  ]
- `arguments`: 切分 `:key value` 参数对；首个键之前出现非空文本则报错。
  #chunk(id: <source-syntax-lang-org-mli-arguments>)[
    ```ocaml
    val arguments :
      value Provenance.located ->
      (value Rules.Payload_rules.field list, Diagnostic.t list) result
    ```
  ]
- `adapter`: 组装为 `string Syntax.adapter`；抽屉常存放其他工具写入的辅助属性，因此 `unknown_properties` 默认为 #raw("`Ignore")。
  #chunk(id: <source-syntax-lang-org-mli-adapter>)[
    ```ocaml
    val adapter :
      ?values:value Rules.Payload_rules.t ->
      ?identities:heading Rules.Identity_rules.t ->
      ?actions:(node, context) Rules.Action_rules.t ->
      ?define:string ->
      ?unknown_properties:[ `Ignore | `Report ] ->
      ('metadata, 'action) Syntax.Frontend_input.t ->
      string Syntax.adapter
    ```
  ]

`Sugar` 提供可选语法糖，将常见 Org 写法绑定到项目动作：

- `id_link`: 注册 `"id-link"`，匹配 `[[id:b]]` 并把位置跨度落在 ID 上：
  ```org
  参见 [[id:note-a]] 或 [[id:note-b][说明]]。
  ```
  #chunk(id: <source-syntax-lang-org-mli-sugar-id-link>)[
    ```ocaml
    val id_link :
      'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
      (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
    ```
  ]
- `include_keyword`: 注册 `"zk-include"`，匹配单参数嵌入指令：
  ```org
  #+zk_include: :target note-c
  ```
  #chunk(id: <source-syntax-lang-org-mli-sugar-include-keyword>)[
    ```ocaml
    val include_keyword :
      'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
      (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
    ```
  ]
- `nested_card`: 注册 `"nested-card"`，将当前卡片下的子卡片绑定到定义动作：
  ```org
  ** 子卡片
  :PROPERTIES:
  :ID: sub-id
  :END:
  子卡片正文。
  ```
  #chunk(id: <source-syntax-lang-org-mli-sugar-nested-card>)[
    ```ocaml
    val nested_card :
      'args Syntax.Action.t ->
      (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
      (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
    ```
  ]

组装为 `Sugar` 模块签名：

#chunk(id: <source-syntax-lang-org-mli-sugar>)[
  ```ocaml
  module Sugar : sig
    <<source-syntax-lang-org-mli-sugar-id-link>>
    <<source-syntax-lang-org-mli-sugar-include-keyword>>
    <<source-syntax-lang-org-mli-sugar-nested-card>>
  end
  ```
]

按顺序组合为 `syntax/lang_org.mli`：

#chunk(id: <file-syntax-lang-org-mli>, target: "syntax/lang_org.mli")[
  ```ocaml
  <<source-syntax-lang-org-mli-initial>>
  <<source-syntax-lang-org-mli-heading>>
  <<source-syntax-lang-org-mli-node>>

  <<source-syntax-lang-org-mli-context>>
  <<source-syntax-lang-org-mli-scan-fn>>
  <<source-syntax-lang-org-mli-children>>

  <<source-syntax-lang-org-mli-rules-values>>
  <<source-syntax-lang-org-mli-rules-identities>>
  <<source-syntax-lang-org-mli-rules-actions>>
  <<source-syntax-lang-org-mli-arguments>>
  <<source-syntax-lang-org-mli-adapter>>

  <<source-syntax-lang-org-mli-sugar>>
  ```
]
