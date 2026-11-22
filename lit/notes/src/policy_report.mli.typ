#import "/reader/book.typ": card-source, chunk
#show: card-source

= 末层失败汇总与影响子图 <core:src:policy_report.mli>

本模块是单次运行的纯汇总层，位于 @core:src:policy_wiring.mli[Policy_wiring] 求值之后：它既不触发任何策略回调，也不修改任何计算值，只把卡片外语法诊断、@core:src:observation.mli[Observation] 失败记录以及全部 @core:src:policy.mli[Policy] 调用记录按 @core:src:failure.mli[Failure.id] 收进同一张表，具体实现见 @core:src:policy_report.ml[policy_report.ml]。

== 快速开始 <core:src:policy_report.mli-quickstart>

通过 @source-core-src-policy-wiring-mli-run-obs[run_observation] 拿到 `report` 后，编辑器与编译期工具可以分别按卡片归属或根因影响消费同一份报告：

```ocaml
(* 编辑器侧：查询单张卡片关联的全部诊断与受影响产物 *)
let card_entries = Policy_report.for_card report card_id

(* 编译与调试侧：遍历所有根因，并展开每条根因的影响子图 *)
let impacts =
  Policy_report.roots report
  |> List.filter_map (fun root ->
         Policy_report.impact report (Policy_report.id root))
```

== 统一记录条目与构造 <core:src:policy_report.mli-types>

报告中的每条记录统一包装为 `entry`，分别保留三个阶段原有的类型化细节与直接原因列表：

- `Syntax`：卡片外无归属的语法抽取诊断 (例如卡片外缺 ID 的标题或缺少语言适配器的文档)，主体为 `unit`，没有上游原因，始终作为根因。
  #chunk(id: <source-core-src-policy-report-mli-entry-syntax>)[
    ```ocaml
    | Syntax of (unit, Frontend.Diagnostic.t) Failure.t
    ```
  ]
- `Observation`：展开与全局组装阶段产生的记录 (元数据失败、行动失败、重复定义、悬空引用等)，主体为卡片或引用边。
  #chunk(id: <source-core-src-policy-report-mli-entry-observation>)[
    ```ocaml
    | Observation of 'observation_error Observation.failure
    ```
  ]
- `Policy`：策略求值阶段产生的记录，覆盖整次调用失败/阻断以及单个产物的失败、阻断、兜底与降级派生。
  #chunk(id: <source-core-src-policy-report-mli-entry-policy>)[
    ```ocaml
    | Policy of 'policy_issue Policy.failure
    ```
  ]

#chunk(id: <source-core-src-policy-report-mli-entry>)[
  ```ocaml
  (** Terminal report for one project run. Records retain their typed details and
      direct causes. Report construction neither evaluates policies nor alters values. *)

  type ('observation_error, 'policy_issue) entry =
    <<source-core-src-policy-report-mli-entry-syntax>>
    <<source-core-src-policy-report-mli-entry-observation>>
    <<source-core-src-policy-report-mli-entry-policy>>
  ```
]

构造报告时还会对记录表自身做一致性检查，用 `integrity_issue` 区分两类内部异常：

- `Duplicate_record`：同一 `Failure.id` 在本轮汇总中出现了多次。
  #chunk(id: <source-core-src-policy-report-mli-integrity-dup>)[
    ```ocaml
    | Duplicate_record of Failure.id
    ```
  ]
- `Missing_cause`：某条记录在 `causes` 中引用了表里不存在的上游 `Failure.id`。
  #chunk(id: <source-core-src-policy-report-mli-integrity-missing>)[
    ```ocaml
    | Missing_cause of { record : Failure.id; cause : Failure.id }
    ```
  ]

#chunk(id: <source-core-src-policy-report-mli-types>)[
  ```ocaml
  <<source-core-src-policy-report-mli-entry>>

  type integrity_issue =
    <<source-core-src-policy-report-mli-integrity-dup>>
    <<source-core-src-policy-report-mli-integrity-missing>>

  type ('observation_error, 'policy_issue) t

  type ('observation_error, 'policy_issue) impact = {
    entries : ('observation_error, 'policy_issue) entry list;
    edges : (Failure.id * Failure.id) list;
        (** Direct edges oriented from cause to effect. *)
  }

  (** Supply the observation and all the outcomes from its associated evaluation.
      [syntax] holds the extraction diagnostics no card owns; each is a root. *)
  val of_evaluation :
    syntax:Frontend.Diagnostic.t list ->
    observation:('metadata, 'relation, 'consumption, 'error) Observation.t ->
    outcomes:(Policy.Invocation_id.t * ('metadata Graph.note, 'relation, 'issue) Policy.outcome) list ->
    ('error, 'issue) t
  ```
]

== 诊断查询与根因影响子图 <core:src:policy_report.mli-queries>

报告围绕同一批记录提供四组查询接口：

- 基础读取与按 ID 查找：`id` 与 `causes` 读取单条记录的身份与直接原因；`entries` 返回全部条目；`find` 按 `Failure.id` 精确查找单条记录。
  #chunk(id: <source-core-src-policy-report-mli-query-basic>)[
    ```ocaml
    val id : ('error, 'issue) entry -> Failure.id
    val causes : ('error, 'issue) entry -> Failure.id list
    val entries : ('error, 'issue) t -> ('error, 'issue) entry list
    val find : ('error, 'issue) t -> Failure.id -> ('error, 'issue) entry option
    ```
  ]
- 根因与表完整性：`roots` 返回所有 `causes` 为空的根因条目 (包括没有下游消费者的独立错误)；`integrity_issues` 返回构造时检出的记录表一致性问题。
  #chunk(id: <source-core-src-policy-report-mli-query-roots>)[
    ```ocaml
    val roots : ('error, 'issue) t -> ('error, 'issue) entry list
    val integrity_issues : ('error, 'issue) t -> integrity_issue list
    ```
  ]
- 按归属查诊断：`for_card` 返回归属到指定卡片的全部条目 (包含该卡的 `Observation` 失败、由该卡发出的失效引用，以及目标落在该卡上的 `Policy` 产物记录)，供@error-handler-editor[]与 @lsp[LSP] 展示局部问题；`for_invocation` 返回指定策略调用关联的全部记录 (包括整次调用级失败与该调用产出的各条产物记录)。
  #chunk(id: <source-core-src-policy-report-mli-query-owner>)[
    ```ocaml
    val for_card : ('error, 'issue) t -> Graph.Vertex_id.t -> ('error, 'issue) entry list
    val for_invocation :
      ('error, 'issue) t -> Policy.Invocation_id.t -> ('error, 'issue) entry list
    ```
  ]
- 按根因查影响子图：`impact` 从给定的起始 `Failure.id` 出发，沿直接因果边 (由原因指向结果) 遍历所有可达受影响条目；每个节点只收录一次，但多条路径汇合到同一结果的所有边都会保留。若起始 ID 不存在于报告中，返回 `None`。
  #chunk(id: <source-core-src-policy-report-mli-query-impact>)[
    ```ocaml
    (** Return the origin and all its reachable effects, each once. Includes all
        direct edges encountered, including separate paths to a shared effect.
        An unknown origin returns [None]. *)
    val impact : ('error, 'issue) t -> Failure.id -> ('error, 'issue) impact option
    ```
  ]

#chunk(id: <source-core-src-policy-report-mli-queries>)[
  ```ocaml
  <<source-core-src-policy-report-mli-query-basic>>
  <<source-core-src-policy-report-mli-query-roots>>
  <<source-core-src-policy-report-mli-query-owner>>
  <<source-core-src-policy-report-mli-query-impact>>
  ```
]

#chunk(
  id: <file-core-src-policy-report-mli>,
  target: "core/src/policy_report.mli",
)[
  ```ocaml
  <<source-core-src-policy-report-mli-types>>
  <<source-core-src-policy-report-mli-queries>>
  ```
]
