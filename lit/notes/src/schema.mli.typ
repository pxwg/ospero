#import "/reader/book.typ": card-source, chunk
#show: card-source

= 结构描述与解码模式 <core:src:schema.mli>

为了让元数据校验、语法层值读取与编辑器补全共享同一份字段定义，`Schema.t` 通过 applicative 组合子把结构描述 (`shape`) 与解码函数 (`decode`) 绑定在一起构造。记录字段在解码时会收集全部独立诊断，嵌套字段与列表项的错误由外层组合子自动补全字段名或下标路径，具体实现见 @core:src:schema.ml[schema.ml]。

#chunk(id: <source-core-src-schema-mli>)[
  ```ocaml
  (** Applicative schemas over Frontend payloads.
      Each combinator builds its structural description and its decoder together.
      Records accumulate independent diagnostics; nested diagnostics receive
      their field and index path from the enclosing combinator. *)
  open Frontend

  (** The structure a schema accepts, for completion and documentation.
      A plain string has no [choices]. *)
  type shape =
    | String of { choices : string list }
    | Bool
    | Int
    | Contents
    | List of shape
    | Record of field list

  and field = {
    name : string;
    shape : shape;
    required : bool;
  }

  type 'a t

  (** Fields of one record, combined with [let+] and [and+]. *)
  type 'a fields

  val describe : 'a t -> shape
  val decode : 'a t -> Payload.t -> ('a, Diagnostic.t list) result

  val string : string t
  val bool : bool t
  val int : int t

  (** Retain contents with the location of their occurrence. *)
  val contents : Text.t Provenance.located t

  (** Item diagnostics are prefixed with their zero-based index. *)
  val list : 'a t -> 'a list t

  (** Decode a string by exact spelling. *)
  val choice : (string * 'a) list -> 'a t

  (** Keep the source span alongside the decoded value. *)
  val located : 'a t -> 'a Provenance.located t

  val map : ('a -> 'b) -> 'a t -> 'b t

  (** Reject a decoded value with [Invalid], located at the value's occurrence. *)
  val refine : ('a -> ('b, string) result) -> 'a t -> 'b t

  (** Repeated fields are reported by [record]; the first occurrence is decoded. *)
  val required : string -> 'a t -> 'a fields

  val optional : string -> 'a t -> default:'a -> 'a fields
  val option : string -> 'a t -> 'a option fields

  (** A record with no declared fields. *)
  val no_fields : unit fields

  val ( let+ ) : 'a fields -> ('a -> 'b) -> 'b fields
  val ( and+ ) : 'a fields -> 'b fields -> ('a * 'b) fields

  (** The declared fields are the only ones accepted. *)
  val record : 'a fields -> 'a t

  (** Read raw record fields. The caller supplies their field validation. *)
  val record_payload : Payload.field list t

  (** Select a schema by invocation name and decode the arguments as a record
      located at the name. Usable directly as [DECODING.decode_action]. *)
  val actions :
    (string * 'a t) list -> Invocation.t -> ('a, Diagnostic.t list) result
  ```
]

#chunk(id: <file-core-src-schema-mli>, target: "core/src/schema.mli")[
  ```ocaml
  <<source-core-src-schema-mli>>
  ```
]
