#import "/reader/book.typ": card-source, chunk
#show: card-source

= 策略接线与求值契约 <core:src:policy_wiring.mli>

本模块负责把一组带名字的 @core:src:policy.mli[Policy] 调用校验并编译为 @lawvere-theory-dag[Lawvere 理论] 中的单个结果空间态射，再按依赖层次求值并交由 @core:src:policy_report.mli[Policy_report] 汇总，具体实现见 @core:src:policy_wiring.ml[policy_wiring.ml]。

== 快速开始 <core:src:policy_wiring.mli-quickstart>

在完整管线中，通常直接通过 `run_observation` 把语法诊断、@core:src:observation.mli[Observation] 与策略列表接在一起：

```ocaml
let input = Result.get_ok (Policy.Invocation_id.of_string "input")
let tags_id = Result.get_ok (Policy.Invocation_id.of_string "tags")

let result =
  Policy_wiring.run_observation
    ~syntax:syntax_diagnostics
    ~observation
    ~input
    ~calls:(fun obs ->
      [ { Policy.id = tags_id; inputs = [ input ]; definition = tags_policy obs } ])
```

== 结构校验与编译态射 <core:src:policy_wiring.mli-compile>

编译阶段不执行任何策略回调，只检查接线图的结构不变量 (重名调用、端口数不匹配、引用了不存在的上游、依赖环路)，并把初始图捕获在抽象类型 `compiled` 内部，防止调用方在求值时替换外部图。允许前向引用、同一上游接到多个端口、零输入调用以及未被下游消费的调用。

#chunk(id: <source-core-src-policy-wiring-mli-types>)[
  ```ocaml
  (** Compile named policy calls into a single result-space morphism. *)

  type issue =
    | Duplicate_identity of Policy.Invocation_id.t
    | Port_count_mismatch of {
        invocation : Policy.Invocation_id.t;
        expected : int;
        actual : int;
      }
    | Missing_input of {
        invocation : Policy.Invocation_id.t;
        port : int;
        source : Policy.Invocation_id.t;
      }
    | Cyclic_dependencies of Policy.Invocation_id.t list
        (** Unresolved calls, including descendants waiting on cycles. *)

  (** A compiled morphism bound to its initial state.
      The morphism is hidden so callers cannot substitute an external graph. *)
  type ('vertex, 'edge, 'issue) compiled
  ```
]

编译提供两个入口：

- `compile`：直接绑定一张初始 `Graph.t` 与命名调用列表，将其编译为结果空间态射。
  #chunk(id: <source-core-src-policy-wiring-mli-compile>)[
    ```ocaml
    (** Compile without executing policy callbacks or assignment providers.
        [input] names the single external input and shares the calls' namespace.
        Forward references, repeated ports, zero-input calls and unused results
        are allowed. All calls are included, not just ancestors of a final output.

        Compilation captures [initial] as the sole external input and fixes
        the topology used to materialize every policy output.
        With no calls the morphism is identity on the initial result.
        Structural errors return no partial compilation. *)
    val compile :
      initial:('vertex, 'edge) Graph.t ->
      input:Policy.Invocation_id.t ->
      ('vertex, 'edge, 'issue) Policy.invocation list ->
      (('vertex, 'edge, 'issue) compiled, issue list) result
    ```
  ]
- `compile_observation`：将策略定义绑定到提供初始图的 `Observation.t`；初始状态端口同时暴露源级产物失败的 `Failure.id`，使下游策略在 `Observation` 存在局部缺口时仍可正常编译并精细追踪原因。
  #chunk(id: <source-core-src-policy-wiring-mli-compile-obs>)[
    ```ocaml
    (** Bind policy definitions to the observation that supplies the initial graph.
        The observation retains source declarations and full diagnostics. The initial
        state port exposes IDs for source product failures, and later state ports
        expose availability and IDs for computed products. Local observation
        failures leave the initial state available. *)
    val compile_observation :
      observation:('metadata, 'relation, 'consumption, 'error) Observation.t ->
      input:Policy.Invocation_id.t ->
      calls:(('metadata, 'relation, 'consumption, 'error) Observation.t ->
        ('metadata Graph.note, 'relation, 'issue) Policy.invocation list) ->
      (('metadata Graph.note, 'relation, 'issue) compiled, issue list) result
    ```
  ]

== 分层求值与末层串联 <core:src:policy_wiring.mli-evaluate>

- `evaluate`：在已捕获的初始状态上求值一次，按“初始输入优先、其余按依赖层与调用身份排序”的确定顺序返回各调用的 `Policy.outcome`；每次求值中每条策略只执行一次。
  #chunk(id: <source-core-src-policy-wiring-mli-evaluate>)[
    ```ocaml
    (** Evaluate on the captured initial state and associate results with identities.
        The initial input comes first, followed by dependency layers, each ordered
        by invocation identity. Each call is evaluated once per evaluation;
        separate evaluations rerun the computation. Each outcome contains its own
        policy records. Callback exceptions propagate. *)
    val evaluate :
      ('vertex, 'edge, 'issue) compiled ->
      (Policy.Invocation_id.t * ('vertex, 'edge, 'issue) Policy.outcome) list
    ```
  ]
- `run_observation`：一次完成编译、求值与末层汇总，同时返回全部策略结果与 @core:src:policy_report.mli[Policy_report.t]，包括独立失败或未被消费的调用。
  #chunk(id: <source-core-src-policy-wiring-mli-run-obs>)[
    ```ocaml
    (** Compile and evaluate once, then collect the terminal report from the
        syntax diagnostics, the same observation and every outcome, including
        independent and failed calls. *)
    val run_observation :
      syntax:Frontend.Diagnostic.t list ->
      observation:('metadata, 'relation, 'consumption, 'error) Observation.t ->
      input:Policy.Invocation_id.t ->
      calls:(('metadata, 'relation, 'consumption, 'error) Observation.t ->
        ('metadata Graph.note, 'relation, 'issue) Policy.invocation list) ->
      ((Policy.Invocation_id.t * ('metadata Graph.note, 'relation, 'issue) Policy.outcome) list *
        ('error, 'issue) Policy_report.t, issue list) result
    ```
  ]

#chunk(
  id: <file-core-src-policy-wiring-mli>,
  target: "core/src/policy_wiring.mli",
)[
  ```ocaml
  <<source-core-src-policy-wiring-mli-types>>
  <<source-core-src-policy-wiring-mli-compile>>
  <<source-core-src-policy-wiring-mli-compile-obs>>
  <<source-core-src-policy-wiring-mli-evaluate>>
  <<source-core-src-policy-wiring-mli-run-obs>>
  ```
]
