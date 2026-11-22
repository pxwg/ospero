#import "/reader/book.typ": card-source, chunk
#show: card-source

= 策略定义与产物状态契约 <core:src:policy.mli>

本模块在固定拓扑的知识图 @core:src:graph.mli[Graph] 上定义纯函数策略及其扩张结果空间，对应 @lawvere-theory-space[扩张结果空间与策略提升] 以及 @global-data-errors[全局错误语义管理] 的接口落点，具体实现见 @core:src:policy.ml[policy.ml]。

== 快速开始 <core:src:policy.mli-quickstart>

编写一条策略通常有两种粒度。如果规则只在整张输入图都完好时运行，可以直接用 `make` 配合 `Cons` 读取裸图：

```ocaml
let simple_policy =
  Policy.make (Cons Nil) (fun (g, ()) ->
    {
      vertex = (fun id -> (* 计算节点新载荷 *));
      edge = (fun id -> (* 计算边新载荷 *));
    })
```

如果需要卡片级容错 (例如某张卡的元数据失败时只阻塞或降级受影响的下游，不影响无关卡片)，则使用 `make_deciding`、`Cons_state` 与 `Product` 组合子逐项产出决策：

```ocaml
let resilient_policy =
  Policy.make_deciding (Cons_state Nil) (fun (state, ()) ->
    let primary : _ Policy.product_assignment = {
      vertex = (fun id ->
        Policy.Product.(
          let+ v = vertex state id in
          transform v)
        |> Policy.Product.decide);
      edge = (fun id ->
        Policy.Product.(edge state id) |> Policy.Product.decide);
    } in
    Policy.Publish { primary; named = [] })
```

== 调用身份与产物可用性 <core:src:policy.mli-state>

每次策略调用在接线图里拥有唯一的 `Invocation_id`。与早期只交付裸图的设计不同，如今一次成功调用交付的是 `State.t`：图的拓扑固定不变，但每个顶点或边上的产物各自带有 `availability` 状态 (`Ready` 正常可用、`Degraded` 降级可用并附带直接原因 ID、`Unavailable` 不可用并附带原因 ID)。

`State` 支持主输出以及多个按名字寻址的附加输出 (`?name`)。当调用方确实要求整张图完好时，`State.graph` 会在所有产物都可用时返回裸图；而当初始端口绑定了 @core:src:observation.mli[Observation] 时，规则还可以通过 `observation_causes` 直接查询某张卡的元数据、正文或出边是否存在源级缺口。

#chunk(id: <source-core-src-policy-mli-state>)[
  ```ocaml
  (** Policy definitions over a common fixed-topology state space. *)

  module Invocation_id : sig
    type t

    (** Accept any non-empty string. Wiring checks uniqueness. *)
    val of_string : string -> (t, string) result
    val to_string : t -> string
    val compare : t -> t -> int
  end

  (** An exceptional product carries the ID of its own record. *)
  type 'a availability =
    | Ready of 'a
    | Degraded of 'a * Failure.id
    | Unavailable of Failure.id

  module State : sig
    type ('vertex, 'edge) t

    (** With no [name], read the primary output. An unknown output or identity
        returns [None]. Unavailable products retain their place in the topology. *)
    val vertex : ?name:string -> ('vertex, 'edge) t -> Graph.Vertex_id.t -> 'vertex availability option
    val edge : ?name:string -> ('vertex, 'edge) t -> Graph.Edge_id.t -> 'edge availability option
    val products : ?name:string -> ('vertex, 'edge) t ->
      ('vertex availability, 'edge availability) Graph.t option

    (** A payload-only view exists if every product in the output is available.
        Use product queries when availability and provenance matter. *)
    val graph : ?name:string -> ('vertex, 'edge) t -> ('vertex, 'edge) Graph.t option

    (** Direct failure IDs for a source product. Available on the initial port
        of a compilation bound to an observation. *)
    val observation_causes :
      ('vertex, 'edge) t -> Observation.product -> Graph.Vertex_id.t -> Failure.id list option
  end
  ```
]

== 调用级错误与结果记录 <core:src:policy.mli-outcome>

每次策略调用的最终产物是 `outcome`，由 `result` 与 `records` 两部分组成：

- `result` 区分调用级的 `Success state` 与 `Error (Failure | Blocked)`。即使 `result` 是 `Success`，其中的个别顶点或边产物仍可能处于降级或不可用状态。
- `records` 只收集本次调用新产生的 @core:src:failure.mli[Failure] 记录 (涵盖整次调用失败、产物失败、产物阻断、使用兜底值以及消费了降级输入)，供末层的 @core:src:policy_report.mli[Policy_report] 统一汇总。

#chunk(id: <source-core-src-policy-mli-outcome>)[
  ```ocaml
  (** These errors describe calls that could not deliver a state. *)
  type 'issue error =
    | Failure of {
        invocation : Invocation_id.t;
        issues : 'issue list;
      }
    | Blocked of {
        invocation : Invocation_id.t;
        dependencies : Invocation_id.t list;
      }

  (** [Success] delivers a state whose individual products can be unavailable. *)
  type ('vertex, 'edge, 'issue) status =
    | Success of ('vertex, 'edge) State.t
    | Error of 'issue error

  type product = {
    output : string option;
    target : Failure.target;
    card : Graph.Vertex_id.t;
        (** The vertex itself, or the source card of an edge product. *)
  }

  type subject = Invocation of Invocation_id.t | Product of Invocation_id.t * product

  type 'issue failure_detail =
    | Failed of 'issue error
    | Used_fallback
    | Used_degraded_input
    | Product_failed of 'issue list
    | Product_blocked

  type 'issue failure = (subject, 'issue failure_detail) Failure.t

  type ('vertex, 'edge, 'issue) outcome = private {
    result : ('vertex, 'edge, 'issue) status;
    records : 'issue failure list;
  }
  ```
]

== 产物构造与自动因果追踪 <core:src:policy.mli-product>

在产物级计算中，每个顶点或边通过 `product_decision` 明确声明自己的结论：正常产出 (`Produce`)、依赖了降级输入但仍算出值 (`Derive`)、主动采用兜底值 (`Recover_product`)、独立报错 (`Reject_product`) 或因上游缺失而阻断 (`Block_product`)。后三者与 `Derive` 都要求至少引用一条直接原因 `Failure.id`。

为了避免策略作者手动拼凑原因列表，`Product` 提供了 applicative / monadic 组合子：通过 `Product.vertex` 与 `Product.edge` 读取输入产物后，`let+` / `and+` / `let*` 会自动累积消费到的降级与不可用原因，最后由 `Product.decide` 一次性转成对应的 `product_decision`。需要显式兜底或自报业务错误时，再直接构造 `Recover_product` 或 `Reject_product` 即可。

#chunk(id: <source-core-src-policy-mli-product>)[
  ```ocaml
  (** A payload provider for each identity in the initial topology. *)
  type ('vertex, 'edge) assignment = {
    vertex : Graph.Vertex_id.t -> 'vertex;
    edge : Graph.Edge_id.t -> 'edge;
  }

  (** Cite the IDs of the exceptional inputs actually used by this product.
      [Derive] keeps a computed value that depends on degraded inputs.
      [Recover_product] supplies a fallback value. [Block_product] supplies no
      value. Each of these decisions requires at least one cause.
      [Reject_product] records an independent failure. *)
  type ('value, 'issue) product_decision =
    | Produce of 'value
    | Derive of 'value * Failure.id list
    | Recover_product of 'value * Failure.id list
    | Reject_product of 'issue list
    | Block_product of Failure.id list

  (** A product under construction: a value together with the exceptional inputs
      it used, or the causes that leave it unavailable. Reading inputs through
      these combinators records their causes; [decide] turns the result into the
      matching decision, so a policy states only how a value is computed. *)
  module Product : sig
    type 'a t

    val return : 'a -> 'a t

    (** Unavailable for these causes. Raises [Invalid_argument] on an empty list. *)
    val unavailable : Failure.id list -> 'a t

    val of_availability : 'a availability -> 'a t

    (** Read an input product. Raises [Invalid_argument] for an unknown identity
        or output, which the fixed topology rules out. *)
    val vertex :
      ?name:string -> ('vertex, 'edge) State.t -> Graph.Vertex_id.t -> 'vertex t

    val edge : ?name:string -> ('vertex, 'edge) State.t -> Graph.Edge_id.t -> 'edge t

    val map : ('a -> 'b) -> 'a t -> 'b t
    val bind : 'a t -> ('a -> 'b t) -> 'b t

    (** Combine independent products. When several are unavailable, all their
        causes are kept. *)
    val both : 'a t -> 'b t -> ('a * 'b) t

    val all : 'a t list -> 'a list t
    val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
    val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
    val ( let* ) : 'a t -> ('a -> 'b t) -> 'b t
    val ( and* ) : 'a t -> 'b t -> ('a * 'b) t

    (** [Produce] without causes, [Derive] with degraded ones, otherwise
        [Block_product] citing every unavailable input. *)
    val decide : 'a t -> ('a, 'issue) product_decision
  end

  type ('vertex, 'edge, 'issue) product_assignment =
    (('vertex, 'issue) product_decision, ('edge, 'issue) product_decision) assignment

  type ('vertex, 'edge, 'issue) outputs = {
    primary : ('vertex, 'edge, 'issue) product_assignment;
    named : (string * ('vertex, 'edge, 'issue) product_assignment) list;
        (** Optional, independently addressable outputs of the same payload types.
            Names must be unique within the call. *)
  }
  ```
]

== 端口声明、策略定义与提升 <core:src:policy.mli-lift>

`ports` 用 GADT 在类型层声明策略接收的有序输入端口：`Cons` 要求该端口的整张主图都可用 (有不可用产物时直接阻断本次调用)，`Cons_state` 则把完整的 `State.t` 交给策略，允许逐项读取可用性。`decision` 给出整次调用的五种可能结论 (`Apply` / `Recover` / `Reject` / `Block_on` / `Publish`)。

#chunk(id: <source-core-src-policy-mli-ports>)[
  ```ocaml
  (** Ordered input states decoded into nested pairs ending in unit.
      [Cons_state] exposes individual products. [Cons] consumes the complete
      primary graph, including its degraded inputs, and blocks if it is incomplete.
      For both constructors, a call-level input error blocks the receiving call. *)
  type (_, 'vertex, 'edge) ports =
    | Nil : (unit, 'vertex, 'edge) ports
    | Cons :
        ('p, 'vertex, 'edge) ports ->
        (('vertex, 'edge) Graph.t * 'p, 'vertex, 'edge) ports
    | Cons_state :
        ('p, 'vertex, 'edge) ports ->
        (('vertex, 'edge) State.t * 'p, 'vertex, 'edge) ports

  type ('vertex, 'edge, 'issue) decision =
    | Apply of ('vertex, 'edge) assignment
    | Recover of ('vertex, 'edge) assignment * Failure.id list
    | Reject of 'issue list
    | Block_on of Failure.id list
    | Publish of ('vertex, 'edge, 'issue) outputs

  type ('vertex, 'edge, 'issue) t

  val arity : ('vertex, 'edge, 'issue) t -> int

  type ('vertex, 'edge, 'issue) invocation = {
    id : Invocation_id.t;
    inputs : Invocation_id.t list;
    definition : ('vertex, 'edge, 'issue) t;
  }
  ```
]

四处核心构造入口分工如下：

- `make`：声明最常见的整图纯函数策略，可选附带 `check` 校验输入；不立即执行回调。
  #chunk(id: <source-core-src-policy-mli-make>)[
    ```ocaml
    (** Declare a pure policy without running its callbacks. *)
    val make :
      ('p, 'vertex, 'edge) ports ->
      ?check:('p -> 'issue list) ->
      ('p -> ('vertex, 'edge) assignment) ->
      ('vertex, 'edge, 'issue) t
    ```
  ]
- `make_deciding`：声明可直接引用上游 `Failure.id` 或 `Observation` 源缺口、并产出 `decision` (包括产物级 `Publish`) 的策略。
  #chunk(id: <source-core-src-policy-mli-make-deciding>)[
    ```ocaml
    (** Declare a pure policy that can cite direct causes from input products or
        from the observation bound by [Policy_wiring.compile_observation]. Empty
        cause lists on blocking, recovery, or derivation raise [Invalid_argument]. *)
    val make_deciding :
      ('p, 'vertex, 'edge) ports ->
      ('p -> ('vertex, 'edge, 'issue) decision) ->
      ('vertex, 'edge, 'issue) t
    ```
  ]
- `initial`：把初始知识图包装成全部产物均为 `Ready` 的起始 `outcome`，并可挂载 `observation_causes` 供下游查询源缺口。
  #chunk(id: <source-core-src-policy-mli-initial>)[
    ```ocaml
    (** Wrap the initial graph as a successful primary output with ready products. *)
    val initial :
      ?observation_causes:(Observation.product -> Graph.Vertex_id.t -> Failure.id list) ->
      ('vertex, 'edge) Graph.t -> ('vertex, 'edge, 'issue) outcome
    ```
  ]
- `lift`：把策略提升为 @core:src:clone.mli[Clone.operation]，固定捕获初始拓扑并在求值时按先顶点后边的顺序物化输出，供 @core:src:policy_wiring.mli[Policy_wiring] 统一接线。
  #chunk(id: <source-core-src-policy-mli-lift>)[
    ```ocaml
    (** Build an operation without invoking callbacks. Each output is materialized
        over the captured topology once per evaluation, in vertex-then-edge order.
        Only records created by this invocation are returned. Exceptions propagate. *)
    val lift :
      initial:('vertex, 'edge) Graph.t ->
      id:Invocation_id.t ->
      ('vertex, 'edge, 'issue) t ->
      ('vertex, 'edge, 'issue) outcome Clone.operation
    ```
  ]

#chunk(id: <source-core-src-policy-mli-lift-all>)[
  ```ocaml
  <<source-core-src-policy-mli-ports>>
  <<source-core-src-policy-mli-make>>
  <<source-core-src-policy-mli-make-deciding>>
  <<source-core-src-policy-mli-initial>>
  <<source-core-src-policy-mli-lift>>
  ```
]

#chunk(id: <file-core-src-policy-mli>, target: "core/src/policy.mli")[
  ```ocaml
  <<source-core-src-policy-mli-state>>
  <<source-core-src-policy-mli-outcome>>
  <<source-core-src-policy-mli-product>>
  <<source-core-src-policy-mli-lift-all>>
  ```
]
