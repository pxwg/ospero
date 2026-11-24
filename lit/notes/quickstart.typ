#import "/reader/book.typ": card-source, chunk
#show: card-source

= 快速开始 <quickstart>

本节旨在引导你 (或者你的 Agent) 快速配置你的第一个 @home 实例。@home 的核心是@local-to-global[]管线，本次示例配置旨在围绕它做最简单的演示，你可以通过点击其中的链接来更深入探索这个项目的动机和实现 (因为文学编程的组织形式，它们实际上是一体的)。

示例使用内置的 @syntax:lang_typst.mli[Typst] 适配器，换用 @syntax:lang_org.mli[Org] 或 @syntax:lang_markdown.mli[Markdown] 只需替换适配器配置，其余代码保持不变。

== 1. 准备笔记源文 <quickstart-notes>

假设有两份最小卡片：`a.typ` 引用 `note-b`，并内嵌了一张子卡片 `note-a-1`：

```typst
/// tags = ["core"]
= 卡片 A <note-a>

参见 @note-b。

/// tags = ["sub"]
== 子卡片 <note-a-1>
嵌套正文。
/// end
```

```typst
/// tags = ["ref"]
= 卡片 B <note-b>

目标卡片正文。
```

== 2. 声明元数据与 Action <quickstart-schema>

字段与参数只在 @core:src:schema.mli[Schema] 和 @core:src:syntax.mli-input[Frontend_input] 中声明一次，同时供语法层按类型读取和前端解码校验：

```ocaml
open Ospero.Core
open Frontend
module Syntax = Ospero.Syntax
module Args = Syntax.Args

type define = {
  contents : Text.t Provenance.located;
  depth : int Provenance.located;
}

type action =
  | Cite of string Provenance.located
  | Define of define

type metadata = { tags : string list }

let cite =
  Syntax.Action.declare ~name:"cite"
    Args.(spec (let+ target = required "target" string ~get:Fun.id in target))

let define =
  Syntax.Action.declare ~name:"define"
    Args.(spec (
      let+ contents = required "contents" contents ~get:(fun d -> d.contents)
      and+ depth = required "depth" int ~get:(fun d -> d.depth) in
      { contents; depth }))

let metadata_schema =
  Schema.(record (
    let+ tags = optional "tags" (list string) ~default:[] in
    { tags }))

let frontend_input =
  Syntax.Frontend_input.create ~metadata:metadata_schema [
    Syntax.Frontend_input.action cite ~decode:(fun t -> Ok (Cite t));
    Syntax.Frontend_input.action define ~decode:(fun d -> Ok (Define d));
  ]

module Decoder = Frontend.Decode (struct
  type nonrec metadata = metadata
  type nonrec action = action
  let decode_metadata = Syntax.Frontend_input.decode_metadata frontend_input
  let decode_action = Syntax.Frontend_input.decode_action frontend_input
end)
```

== 3. 组装语法适配器并做局部提取 <quickstart-syntax>

在默认具名调用之外，通过 @syntax:rules.mli-action[行动规则表] 叠加 `@ref` 与嵌套子卡片语法糖，然后由 @source-core-src-syntax-mli-parse-project[parse_project] 抽出原始项目与卡片外诊断：

```ocaml
module Typst = Syntax.Lang.Typst

let typst_actions =
  Typst.actions
  |> Typst.Sugar.references cite Fun.id
  |> Typst.Sugar.nested_card define (fun ~contents ~depth -> { contents; depth })

let syntax_config =
  Syntax.configure [
    Typst.adapter ~actions:typst_actions ~define:"define" frontend_input
  ]

let raw_project, unowned_diagnostics =
  Syntax.parse_project syntax_config [
    { Syntax.file = "a.typ"; language = Typst.language; native = source_a };
    { Syntax.file = "b.typ"; language = Typst.language; native = source_b };
  ]
```

== 4. 解释行动并组装初始知识图 <quickstart-observation>

实现 @core:src:frontend.mli-pipeline[FRONTEND] 的纯函数 `interpret`，将 @action[] 翻译为 `Relate` 与 `Define` 贡献 (嵌套 `Contents` 通过 @source-core-src-syntax-mli-parse-contents[parse_contents] 懒展开)，再调用 `observe` 得到 @core:src:observation.mli[Observation]：

```ocaml
module Observed = Frontend.Make (struct
  include Decoder
  type relation = string
  type consumption = unit
  type error = Diagnostic.t

  let interpret = function
    | Cite target ->
        (match Graph.Vertex_id.of_string target.value with
         | Ok id ->
             [ Observation.Relate
                 { target = { target with value = id }; relation = "cite" } ]
         | Error msg ->
             [ Observation.Fail (Diagnostic.make ?span:target.span (Invalid msg)) ])
    | Define d ->
        (match Syntax.parse_contents syntax_config d.contents with
         | Ok child -> [ Observation.Define (decode_source child) ]
         | Error errs -> List.map (fun e -> Observation.Fail e) errs)
end)

let observation = Observed.observe raw_project
```

== 5. 运行策略并查询末层报告 <quickstart-policy>

最后在固定拓扑上定义一条 @core:src:policy.mli[Policy]，使用 @core:src:policy.mli-product[Product] 组合子自动追踪异常因果，并通过 @source-core-src-policy-wiring-mli-run-obs[run_observation] 一次完成编译、求值与 @core:src:policy_report.mli[Policy_report] 汇总：

```ocaml
let passthrough_policy =
  Policy.make_deciding (Cons_state Nil) (fun (state, ()) ->
    let primary : _ Policy.product_assignment = {
      vertex = (fun id ->
        Policy.Product.(vertex state id) |> Policy.Product.decide);
      edge = (fun id ->
        Policy.Product.(edge state id) |> Policy.Product.decide);
    } in
    Policy.Publish { primary; named = [] })

let input_id = Result.get_ok (Policy.Invocation_id.of_string "input")
let pass_id = Result.get_ok (Policy.Invocation_id.of_string "passthrough")

let outcomes, report =
  Result.get_ok (
    Policy_wiring.run_observation
      ~syntax:unowned_diagnostics
      ~observation
      ~input:input_id
      ~calls:(fun _ ->
        [ { Policy.id = pass_id; inputs = [ input_id ]; definition = passthrough_policy } ]))
```

拿到 `report` 后，既可以按卡片查诊断 (`Policy_report.for_card report card_id`) 供 @lsp[LSP] 展示，也可以遍历 `Policy_report.roots report` 并调用 `Policy_report.impact` 查看每条根因在整张图上的影响子图，同时，也可以通过消费 report，实现前端渲染。
