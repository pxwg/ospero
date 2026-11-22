#import "/reader/book.typ": card-source, chunk
#show: card-source

= 知识图契约 <core:src:graph.mli>

在@global-data-observation[]中，笔记库经过全局组装后落为一张有向多重图 $Gamma = (V, E, s, t)$。本模块定义这张图的纯语义表示，不携带正文与源码溯源，具体实现见 @core:src:graph.ml[graph.ml]。

== 身份、声明与图骨架 <core:src:graph.mli-types>

顶点与边的身份均由调用方提供，分别占用独立的命名空间，允许平行边与自环 (同一张卡片中指向同一目标的多次引用各自保留为独立的边)。`knowledge_graph` 的顶点载荷 `note` 只保留标题与元数据，把正文与 @core:src:provenance.mli[源码位置] 留给 @core:src:observation.mli[Observation] 单独管理。

#chunk(id: <source-core-src-graph-mli-types>)[
  ```ocaml
  (** A directed multigraph with opaque payloads.
      Vertex and edge identities are supplied by the caller.
      Parallel edges and cycles are allowed. *)

  module Vertex_id : sig
    type t

    (** Accept any non-empty string. Graph-wide uniqueness is not checked here. *)
    val of_string : string -> (t, string) result

    val to_string : t -> string

    (** A total order for indexing, with no domain-specific ordering semantics. *)
    val compare : t -> t -> int
  end

  module Edge_id : sig
    type t

    (** Accept any non-empty string. Graph-wide uniqueness is not checked here. *)
    val of_string : string -> (t, string) result

    val to_string : t -> string

    (** A total order for indexing, with no domain-specific ordering semantics. *)
    val compare : t -> t -> int
  end

  (** A vertex declaration. Identity uniqueness is checked during assembly. *)
  type 'note vertex = {
    id : Vertex_id.t;
    note : 'note;
  }

  (** An edge declaration. Its endpoints need not exist yet. *)
  type 'relation edge = {
    id : Edge_id.t;
    source : Vertex_id.t;
    target : Vertex_id.t;
    relation : 'relation;
  }

  (** A valid graph has unique vertex identities, unique edge identities,
      and existing endpoints for every edge.
      Vertex and edge identities occupy separate namespaces. *)
  type ('note, 'relation) t

  (** A note payload, excluding identity, body, and provenance. *)
  type 'metadata note = {
    title : Text.t;
    metadata : 'metadata;
  }

  type ('metadata, 'relation) knowledge_graph =
    ('metadata note, 'relation) t

  type endpoint = Source | Target

  type issue =
    | Duplicate_vertex of Vertex_id.t
    | Duplicate_edge of Edge_id.t
    | Missing_endpoint of Edge_id.t * endpoint * Vertex_id.t
        (** The edge identity, endpoint direction, and referenced vertex identity. *)
  ```
]

== 组装、保拓扑变换与索引查询 <core:src:graph.mli-ops>

`assemble` 检查顶点与边身份的唯一性以及所有端点的存在性，确保进入后续阶段的图满足结构不变量。`map` 则体现“拓扑与赋值分离”的核心约束：它按输入顺序逐一替换顶点与边的载荷，同时直接共享原有的拓扑与邻接索引，这正是 @core:src:policy.mli[Policy] 在固定拓扑上演化状态的基础原语。

#chunk(id: <source-core-src-graph-mli-ops>)[
  ```ocaml
  (** Check duplicate identities and missing endpoints.
      Return a complete graph on success, or diagnostics without a partial graph
      on failure. If both endpoints of an edge are missing, report each separately.
      Edges are not deduplicated by endpoints or relation payloads. *)
  val assemble :
    'note vertex list ->
    'relation edge list ->
    (('note, 'relation) t, issue list) result

  (** Transform payloads while sharing the original topology and adjacency indexes.
      Callbacks receive original declarations and return only new payloads.
      They run once per vertex, then once per edge, in assembly input order.
      Payload types may change; identities, endpoints and order are preserved. *)
  val map :
    vertex:('note vertex -> 'new_note) ->
    edge:('relation edge -> 'new_relation) ->
    ('note, 'relation) t ->
    ('new_note, 'new_relation) t

  (** Return vertices in their assembly input order. *)
  val vertices :
    ('note, 'relation) t -> 'note vertex list

  (** Return edges in their assembly input order, preserving parallel edges. *)
  val edges :
    ('note, 'relation) t -> 'relation edge list

  (** Return the complete vertex, or [None] if its identity is unknown. *)
  val find_vertex :
    ('note, 'relation) t -> Vertex_id.t -> 'note vertex option

  (** Return the complete edge, or [None] if its identity is unknown. *)
  val find_edge :
    ('note, 'relation) t -> Edge_id.t -> 'relation edge option

  (** Return complete incoming edges in relative edge input order,
      preserving parallel edges.
      [None] denotes an unknown vertex; [Some []] denotes a known vertex
      with no incoming edges. A self-loop is both incoming and outgoing. *)
  val incoming :
    ('note, 'relation) t -> Vertex_id.t -> 'relation edge list option

  (** Return complete outgoing edges in relative edge input order,
      preserving parallel edges.
      [None] denotes an unknown vertex; [Some []] denotes a known vertex
      with no outgoing edges. A self-loop is both incoming and outgoing. *)
  val outgoing :
    ('note, 'relation) t -> Vertex_id.t -> 'relation edge list option
  ```
]

#chunk(id: <file-core-src-graph-mli>, target: "core/src/graph.mli")[
  ```ocaml
  <<source-core-src-graph-mli-types>>
  <<source-core-src-graph-mli-ops>>
  ```
]
