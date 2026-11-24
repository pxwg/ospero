#import "/reader/book.typ": card-source, chunk
#show: card-source

= 认识 Ospero <meet-ospero>

@home 是一个构建在@lml[]上以 @zettelkasten-intro[]为基本组织模式的@pkm。它在设计之初的一个重要用途——或者说唯一用途——是在笔记撰写过程中建立起局部知识之间的联系，这有助于你在接受新知识时主动建立与既有知识的联结。事实上，鉴于知识可以来自课程教科书等传统“学习”背景，也可以是长期个人思维活动的结晶——这更接近于科学研究或者 (更广义来说的) 知识产出过程，这套系统应当适用于一切可以以文本为载体的知识活动。

举例而言，在初学量子场论的路径积分概念时，你有可能会记录：

#chunk(
  id: <file-examples-quickstart-minimal-a-typ>,
  target: "examples/quickstart/minimal/a.typ",
  noweb: false,
)[
  ```typst
  /// tags = ["qft"]
  = 路径积分 <note-a>

  考虑一个经典场论 $phi : M -> X$，其中 $M$ 是时空流形而 $X$ 是靶空间，路径积分量子化指出理论的振幅可以被组织成泛函积分的形式：
  $
    Z = integral_(Gamma(M, X)) dif mu_(M)[phi] quad e^(i S[phi]),
  $ 
  其中 $S[phi]$ 是理论的@note-b[作用量]。
  ```
]

假设你新接触量子场论概念，但你已经有了牛顿力学基础 (这通常是学习量子场论之前需要学会的知识)，则你的笔记库中大概率会存有这样一份笔记：

#chunk(
  id: <file-examples-quickstart-minimal-b-typ>,
  target: "examples/quickstart/minimal/b.typ",
  noweb: false,
)[
  ```typst
  /// tags = ["mechanics"]
  = 作用量 <note-b>

  考虑一个经典场论 $phi : M -> X$，其中 $(M, g)$ 是时空流形 (我们假设它是一个黎曼流形) 而 $X$ 是靶空间，我们有作用量
  $
    S[phi] = integral_(M) dif op[vol]_(g) quad cal(L)[phi],
  $ 
  其中 $cal(L)[phi]$ 是理论的拉格朗日密度。
  ```
]

可想而知，这份卡片还可以与诸如“拉格朗日密度”, “最小作用量原理”, “黎曼流形”等卡片建立起直接关联。这样，虽然你只是在系统中添加了一张卡片，但伴随你或主动或被动地与笔记系统中既有的卡片建立联系，这个知识不会是孤立的个体，而是会时刻响应你输入，并辅助你自我思考与修正的有机整体。

然而，这种响应与组织模式若不通过某种恰当的方式约束，随着使用时间和笔记数量的增长，往往会遇到一些或局部或全局的不自洽性。这种不自洽性将可能导致笔记系统的失效。在笔者看来，一个笔记系统有如下两种失效模式，分别对应短周期和长周期的失效模式。

== 短周期失效模式 <meet-ospero:short>

伴随笔记数量的增多，在小尺度卡片聚类下可以工作的机制可能在数量增长后失效——或者单纯只是卡顿。遗憾的是，知识记录作为效率敏感的工作环境 (灵感有时确实稍纵即逝，或者只是想要在一个固定的编辑节奏中完成自己的知识生产)，即使是最轻微的卡顿都足以成为弃用这个系统——至少是这个系统与编辑相关部分——的理由。因此，如何在笔记数量增加时维持笔记知识功能的性能，是每一个面向长期知识构建所需的基本要求。

///
== 长周期失效模式 <meet-ospero:long>

当我们将对知识的组织视为以数十年为时间尺度的日常活动时，无论是观点的变迁所导致的知识组织方式重构，还是因为技术革新而导致的编辑环境等技术栈革新，能否在这些变化之下保证笔记系统仍然可被查阅和更改，将成为笔记系统是否能正常运转的重要甚至决定性因素。

这本质上是一种时间尺度上的 #link("http://www.incompleteideas.net/IncIdeas/BitterLesson.html")[_The Bitter Lesson_]：人的领域特定输入是某个时间段内已有认识的集合，但未来知识构建方式与技术的变革会导致这一输入极有可能被修正乃至重构。这要求我们不能将系统构建在某个源自特定时间段的领域经验 (包含知识在认识论层面的特定组织形式，例如使用函子观点而非 factorization algebra 观点来组织拓扑量子场论；与特定软件工程实现，例如使用 Org mode 而非 Typst 来组织笔记) 上，否则几乎必然会在未来面临因这一经验变动而发生的大规模基础性系统重构——在 #link("http://www.incompleteideas.net/IncIdeas/BitterLesson.html")[_The Bitter Lesson_] 的原始语境中，这对应着数据集或者问题潜在解空间的任意复杂度，而在我们这里，即所谓时间尺度上的 #link("http://www.incompleteideas.net/IncIdeas/BitterLesson.html")[_The Bitter Lesson_]，则对应着长时间下变化发生可能性的任意复杂度——而应该将重点放在发现并构建*那些能够发现并捕捉这种任意复杂性的元方法*上，并将其用于对“最优路径”的搜索和拟合。

在这里，搜索和拟合是两个步骤。一方面，这种元方法可以作为框架组织对于当前问题的搜索过程，并对不同搜索结果的优劣建立判别机制；另一方面，通过对元方法的组合，它可以作为对搜索得出的“最优路径”的有效拟合。

/// end

值得注意的是，对于@meet-ospero:long[]的观察会给出对@meet-ospero:short[]做优化的负面观点：根据摩尔定律，任何一种基于当前芯片制程而构建的优化模式都将在长时间看被更好的芯片性能给覆盖，因此，最“好”的应该是几乎不做任何基于当前硬件的优化而只专注于对于元方法的有效实现——这将产生当前最大且不退化的可用性，而伴随着时间尺度的拉长而自然获得更高性能。这正是 @home 所做且应做的事情。

当然，这个论断有意忽略了人决策的冲动性——尤其是在人工智能增强了人在这方面的“生产力”之后——人们对于软件的容忍程度变得足够低，以至于——无论是好是坏——只要一些足够小的性能延迟，都有可能成为人更换工具或者使用人工智能“fork”一份自己的版本来做点状优化的契机。因此，在可以预测的将来，软件的可自我优化和重组的能力将成为其抵御@meet-ospero:long[]的关键。

值得注意的是，这种个性化的优化更新，事实上只是一种“最优路径”的搜索结果。有鉴于 @home 的设计理念，即通过@model[可组合的元方法]来组织作为搜索得出的当前“最优路径”的拟合。这种更新操作不过是对于 @home 既有元方法的组合，来实现对用户需求输入下搜索得出“最优路径”的拟合。

上述观点的唯一局限性在于，我们仍然针对某一类特定的问题构建了固定的元方法集合，而当元方法本身被更新，@home 的组织模式也应该发生改变。然而，作为建立在既有元方法集合上的软件系统，将其迁移到新的元方法集合将具有天然的阻力。此时，所有原本作为对局部更新的优化的元方法都将成为后续维护的技术债。

我的建议是，当这种现象出现时，及时选择继承当前软件背后的构建思想，识别新旧两种元方法之间的差异，并转向适配于新的元方法的软件系统。@home 此时的意义将转换为，不让特定的元方法集合和通过其组合得到的特定方法成为@independence[]的障碍。我们希望 @home 的底层设计能支持你将数据的迁移组织成最后一个其元方法所构建的应用。

== 声明元数据与 Action <quickstart-minimal-schema>

字段与参数只在 @core:src:schema.mli[Schema] 与 @core:src:syntax.mli-input[Frontend_input] 中声明一次，供语法读取与前端解码共用：

#chunk(id: <chunk-quickstart-minimal-schema>)[
  ```ocaml
  open Ospero.Core
  open Frontend
  module Syntax = Ospero.Syntax

  type metadata = { tags : string list }
  type action = Cite of string Provenance.located

  let cite =
    Syntax.Action.declare ~name:"cite"
      Syntax.Args.(spec (let+ t = required "target" string ~get:Fun.id in t))

  let schema =
    Schema.(record (let+ tags = optional "tags" (list string) ~default:[] in { tags }))

  let input =
    Syntax.Frontend_input.create ~metadata:schema
      [ Syntax.Frontend_input.action cite ~decode:(fun t -> Ok (Cite t)) ]
  ```
]

== 组装适配器并观察知识图 <quickstart-minimal-observe>

叠加 `@ref` 语法糖，再通过 @core:src:frontend.mli-pipeline[FRONTEND] 把 `Cite` 解释为图边。`observe_sources` 接收 `(文件名, 源文)` 列表，可直接用于 REPL 交互求值：

#chunk(id: <chunk-quickstart-minimal-observe>)[
  ```ocaml
  module Typst = Syntax.Lang.Typst

  let config =
    Syntax.configure [
      Typst.adapter ~actions:(Typst.actions |> Typst.Sugar.references cite Fun.id) input
    ]

  module Observed = Frontend.Make (struct
    include Frontend.Decode (struct
      type nonrec metadata = metadata
      type nonrec action = action
      let decode_metadata = Syntax.Frontend_input.decode_metadata input
      let decode_action = Syntax.Frontend_input.decode_action input
    end)

    type relation = string
    type consumption = unit
    type error = Diagnostic.t

    let interpret (Cite target) =
      match Graph.Vertex_id.of_string target.value with
      | Ok id -> [ Observation.Relate { target = { target with value = id }; relation = "cite" } ]
      | Error msg -> [ Observation.Fail (Diagnostic.make ?span:target.span (Invalid msg)) ]
  end)

  let observe_sources docs =
    let docs = List.map (fun (file, native) -> { Syntax.file; language = Typst.language; native }) docs in
    let raw, unowned = Syntax.parse_project config docs in
    (Observed.observe raw, unowned)
  ```
]

== 运行入口 <quickstart-minimal-run>

读取两份笔记，打印组装出的顶点与边：

#chunk(id: <chunk-quickstart-minimal-run>)[
  ```ocaml
  let () =
    let read f = In_channel.with_open_text f In_channel.input_all in
    let obs, _ = observe_sources [ ("a.typ", read "a.typ"); ("b.typ", read "b.typ") ] in
    let g = Observation.graph obs in
    List.iter (fun (v : _ Graph.vertex) ->
      Printf.printf "vertex %s (%s)\n" (Graph.Vertex_id.to_string v.id) v.note.Graph.title.text)
      (Graph.vertices g);
    List.iter (fun (e : _ Graph.edge) ->
      Printf.printf "edge   %s --%s--> %s\n"
        (Graph.Vertex_id.to_string e.source) e.relation (Graph.Vertex_id.to_string e.target))
      (Graph.edges g)
  ```
]

#chunk(
  id: <file-examples-quickstart-minimal-dune>,
  target: "examples/quickstart/minimal/dune",
)[
  ```dune
  (executable
   (name main)
   (libraries ospero))
  ```
]

#chunk(
  id: <file-examples-quickstart-minimal-main>,
  target: "examples/quickstart/minimal/main.ml",
)[
  ```ocaml
  <<chunk-quickstart-minimal-schema>>
  <<chunk-quickstart-minimal-observe>>
  <<chunk-quickstart-minimal-run>>
  ```
]
