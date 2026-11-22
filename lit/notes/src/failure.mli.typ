#import "/reader/book.typ": card-source, chunk
#show: card-source

= 失败记录与因果身份 <core:src:failure.mli>

为了把卡片外语法诊断、@core:src:observation.mli[Observation] 组装失败与 @core:src:policy.mli[Policy] 求值中的异常贯通成一张因果图，本模块为单次运行中的所有失败与降级记录提供统一身份 `id` 与记录骨架 `t`，具体实现见 @core:src:failure.ml[failure.ml]。

每条记录只通过 `causes` 引用直接导致它的上游记录身份 (空列表表示根因)，而不在每一步复制整条错误链；末层的 @core:src:policy_report.mli[Policy_report] 据此即可还原任意根因的影响子图。

#chunk(id: <source-core-src-failure-mli>)[
  ```ocaml
  (** Record identities scoped to one project run. *)
  type id

  val compare : id -> id -> int
  val syntax : int -> id

  (** Use the occurrence ordinal in the assembled observation. *)
  val observation : int -> id

  (** Identify the record for the invocation as a whole. *)
  val policy : string -> id

  type target = Vertex of Graph.Vertex_id.t | Edge of Graph.Edge_id.t

  (** Identify the record for one product. [None] denotes the primary output. *)
  val policy_product : invocation:string -> output:string option -> target -> id

  type ('subject, 'detail) t = {
    id : id;
    subject : 'subject;
    detail : 'detail;
    causes : id list;
        (** The IDs of directly responsible records. An empty list marks a root. *)
  }
  ```
]

#chunk(id: <file-core-src-failure-mli>, target: "core/src/failure.mli")[
  ```ocaml
  <<source-core-src-failure-mli>>
  ```
]
