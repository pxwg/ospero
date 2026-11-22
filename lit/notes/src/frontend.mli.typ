#import "/reader/book.typ": card-source, chunk
#show: card-source

= 前端解码与解释契约 <core:src:frontend.mli>

在@local-data[]中，@core:src:syntax.mli[Syntax] 交出的只是按语言规则读出的原始结构，还未对齐项目自己的类型与语义。本模块负责把这一层原始输入解码为项目定义的类型化数据，再通过独立的解释器把单个行动翻译为局部贡献，交由 @core:src:observation.mli[Observation] 完成全局组装，具体实现见 @core:src:frontend.ml[frontend.ml]。

== 原始值与未解码调用 <core:src:frontend.mli-payload>

在进入项目类型系统之前，卡片元数据与行动参数共用同一种未解码值 `Payload`：字段保持源码顺序且不提前去重，每一处出现都独立附着 @core:src:provenance.mli[Provenance]，而需要延迟处理的嵌套正文或富文本字段则以 @core:src:text.mli[Text] 快照的形式留在 `Contents` 中。

#chunk(id: <source-core-src-frontend-mli-payload>)[
  ```ocaml
  (** Frontend contracts: decode raw Source into typed Source, then interpret
      typed actions. Syntax adapters produce the raw project; Observation
      expands and assembles the decoded project. *)

  (** Undecoded field values shared by metadata and invocation arguments.
      Decoding assigns them project-defined meaning. *)
  module Payload : sig
    (** A value occurrence. [None] means no direct source location is known. *)
    type t = value Provenance.located

    and value =
      | String of string
      | Bool of bool
      | Int of int
      | List of t list
      | Record of field list
          (** Fields keep their source order, including duplicate names. *)
      | Contents of Text.t
          (** Content kept for later processing, such as rich-text fields or
              nested note bodies. The text is the fixed snapshot taken by the
              current scan; the enclosing occurrence locates it in the source. *)

    and field = {
      name : string Provenance.located;
      value : t;
    }

    (** The constructor of a value, without its contents. *)
    module Kind : sig
      type t = String | Bool | Int | List | Record | Contents

      val of_value : value -> t
    end
  end
  ```
]

正文里无论是具名调用还是各种语法糖，经过 @syntax:rules.mli-action[行动规则表]后都归一为同一种未解码调用 `Invocation`，只记录行动名与有序的具名参数。

#chunk(id: <source-core-src-frontend-mli-invocation>)[
  ```ocaml
  (** An undecoded action call in a note body.
      The enclosing body occurrence locates the whole invocation. *)
  module Invocation : sig
    type t = {
      name : string Provenance.located;
      arguments : Payload.field list;
          (** Named payloads in source order, including duplicate names. *)
    }
  end
  ```
]

== 结构化诊断与就地定位 <core:src:frontend.mli-diagnostic>

语法读取与前端解码共享同一种诊断结构 `Diagnostic`。除了具体问题 `problem` (包含可供编辑器直接补全 ID 的 `Missing_identity`)，每条诊断还记录从当前对象指向出错位置的字段或下标路径 `path`，以及可选的源码范围 `span`；外层只在诊断本身缺少位置时通过 `with_fallback_span` 补上兜底范围。这样@error-handler-compiler[]与 @lsp[LSP] 就能复用同一份精确定位。

#chunk(id: <source-core-src-frontend-mli-diagnostic>)[
  ```ocaml
  (** A problem reported while extracting or decoding input. *)
  module Diagnostic : sig
    (** A step from the decoded value towards the offending occurrence. *)
    type segment =
      | Field of string
      | Index of int

    type problem =
      | Type_mismatch of { expected : Payload.Kind.t; given : Payload.Kind.t }
      | Missing_field of string
          (** Reported at the enclosing record. *)
      | Unknown_field of { name : string; known : string list }
      | Duplicate_field of string
      | Invalid_choice of { given : string; choices : string list }
      | Unknown_action of { name : string; known : string list }
      | Invalid of string
          (** A project-defined constraint rejected a well-formed value. *)
      | Missing_identity of { insertion : Provenance.span option; prefix : string; suffix : string }
          (** A card declaration without an ID. Writing [prefix ^ id ^ suffix] at
              the empty [insertion] span declares one. *)

    type t = {
      problem : problem;
      path : segment list;
          (** Outermost first; empty at the decoded value itself. *)
      span : Provenance.span option;
          (** The range to report, when known. This may be an enclosing range. *)
    }

    val make : ?path:segment list -> ?span:Provenance.span -> problem -> t

    (** Supply an enclosing range only when the diagnostic has no range. *)
    val with_fallback_span : Provenance.span option -> t -> t
  end
  ```
]

== 阶段参数化与组合提交 <core:src:frontend.mli-stages>

原始输入 (`raw_note` / `raw_project`) 与解码后的输入共享同一套 `Observation.Source.note` 和 `Observation.project` 骨架，只替换其中的 `metadata` 与 `action` 类型参数。卡片的元数据与正文中的每一条行动各自保留自己的 `read` / `decoded` / `decoded_action` 结果，局部失败不会中断同张卡片其余内容的传递；对于行动，`action_failure` 还保留了失败发生在语法读取 (`Unread`) 还是前端解码 (`Undecoded`) 的区分。

#chunk(id: <source-core-src-frontend-mli-stages>)[
  ```ocaml
  (** Project-supplied rules for the values occurring in the current layer. *)
  module type DECODING = sig
    type metadata
    type action

    val decode_metadata :
      Payload.t -> (metadata, Diagnostic.t list) result

    (** Construct an action without executing its interpretation. *)
    val decode_action :
      Invocation.t -> (action, Diagnostic.t list) result
  end

  (** What Syntax read from the source: a value for later decoding, or the
      diagnostics explaining why the construct could not be read. *)
  type 'a read = ('a, Diagnostic.t list) result

  (** A note as Syntax hands it over. Metadata and each action keep their own
      reading outcome, so one unreadable construct degrades only its card. *)
  type raw_note = (Payload.value read, Invocation.t read) Observation.Source.note

  type raw_project = (Payload.value read, Invocation.t read) Observation.project

  type 'a decoded = ('a, Diagnostic.t list) result

  (** Why an action is unavailable: Syntax could not read the call, or the
      call was read but did not decode. *)
  type action_failure =
    | Unread of Diagnostic.t list
    | Undecoded of Invocation.t * Diagnostic.t list

  type 'a decoded_action = ('a, action_failure) result

  type 'error failure =
    | Metadata_decode of Diagnostic.t list
        (** Unreadable or undecodable metadata. *)
    | Action_decode of action_failure
    | Interpretation of 'error
  ```
]

== 解码与独立解释 <core:src:frontend.mli-pipeline>

解码与解释被明确拆成两步。`DECODER` 只对当前层的元数据与行动构造类型化数据，保留身份、原文、位置与顺序，不执行行动也不提前展开 `Contents`；项目通常直接用 @core:src:syntax.mli-input[Frontend_input] 实现 `DECODING`，再经由 `Decode` 派生出两处解码入口。

`FRONTEND` 在此之上提供独立的 `interpret`，将单条已解码的行动翻译为有序的 `Observation.contribution`；若行动携带 `Contents`，解释器在需要时调用 @source-core-src-syntax-mli-parse-contents[parse_contents] 与 `decode_source` 懒展开下一层。最后，`Make.observe` 把整条解码、展开与组装管线接起来，返回同时携带图与全部失败贡献的 `Observation.t`。

#chunk(id: <source-core-src-frontend-mli-pipeline>)[
  ```ocaml
  (** Decode the current Source layer. Identity, text, provenance and order
      are preserved. Metadata and each action retain their own outcome; reading
      failures pass through unchanged. Contents retained by an action are not
      decoded here. *)
  module type DECODER = sig
    type metadata
    type action

    val decode_source :
      raw_note Provenance.located ->
      (metadata decoded, action decoded_action) Observation.Source.note Provenance.located

    val decode_project :
      raw_project -> (metadata decoded, action decoded_action) Observation.project
  end

  (** Derive both decoding entries from the same current-layer traversal. *)
  module Decode (Rules : DECODING) :
    DECODER
      with type metadata = Rules.metadata
       and type action = Rules.action

  (** A complete frontend: decoding plus an independent interpreter.
      An interpreter handling Contents obtains the next typed Source layer with
      [Syntax.parse_contents] followed by [decode_source]. *)
  module type FRONTEND = sig
    include DECODER

    type relation
    type consumption
    type error

    (** Interpret a decoded action into ordered contributions. A generated note
        can itself carry decoding failures. *)
    val interpret :
      action ->
      (metadata decoded, relation, action decoded_action, consumption, error)
        Observation.contribution list
  end

  module Make (Frontend : FRONTEND) : sig
    (** Decode, expand, and assemble a graph together with all failure contributions. *)
    val observe :
      raw_project ->
      (Frontend.metadata decoded, Frontend.relation, Frontend.consumption,
       Frontend.error failure) Observation.t
  end
  ```
]

#chunk(id: <file-core-src-frontend-mli>, target: "core/src/frontend.mli")[
  ```ocaml
  <<source-core-src-frontend-mli-payload>>
  <<source-core-src-frontend-mli-invocation>>
  <<source-core-src-frontend-mli-diagnostic>>
  <<source-core-src-frontend-mli-stages>>
  <<source-core-src-frontend-mli-pipeline>>
  ```
]
