#import "/reader/book.typ": card-source, chunk
#show: card-source

= 规则表契约 <syntax:rules.mli>

在@local-data[]中，同一段 markup 落在不同语境下可以有不同含义 (例如 Org 的 `[[id:b]]` 在正文中是一次引用调用，落在参数位上则只是字符串 `"b"`)，而同一种语义也常常有多种写法。为了在不写死解析器的前提下支持扩展与覆盖，我们将局部识别组织成三张可组合的规则表，具体实现见 @syntax:rules.ml[rules.ml]。

规则表本身是可选工具：如果某个语言适配器自己的 parser 已经直接产出 payload 与身份声明，可以跳过这一层，直接实现 @core:src:syntax.mli[Syntax] 契约。

== 三值匹配语义 <syntax:rules.mli-matched>

三张规则表共享同一种匹配结果 `matched`。它把“这段语法不归我处理” (`No_match`) 与“这段语法归我处理，但写坏了” (`Invalid`) 明确分开：规则表只有在遇到 `No_match` 时才继续尝试下一条规则；一旦某条规则认领了该节点并报告 `Invalid`，分派立刻停止并保留完整的诊断列表，不再静默回退。

#chunk(id: <source-syntax-rules-mli-matched>)[
  ```ocaml
  (** Rule tables for writing Syntax adapters. Optional: an adapter whose
      parser already yields payloads and identities may skip them. *)
  open Ospero_kernel
  open Frontend

  (** A rule can decline a node, accept it, or report why it is malformed.
      A rule table tries the next rule only after [No_match]. *)
  type 'a matched =
    | No_match
    | Matched of 'a
    | Invalid of Diagnostic.t list
  ```
]

== 值规则表 <syntax:rules.mli-payload>

值规则表负责在参数位或元数据位读取具体的值。规则按目标字段声明的载体类型 (`Syntax.Args.value`) 分派，因此同一段原始文本可以根据字段预期分别读成字符串、整数或列表。参数读取 (`read_arguments`) 与元数据读取 (`read_metadata`) 共用同一套 `reader`，并且只负责按声明转出带位置的 `Payload.field`，保留字段顺序与重复项，留给 @core:src:frontend.mli[Frontend] 做进一步校验。

#chunk(id: <source-syntax-rules-mli-payload>)[
  ```ocaml
  module Payload_rules : sig
    (** Value rules are selected by the carrier of the field being read. *)
    type 'node t
    type 'node reader

    val empty : 'node t

    (** Register a reading for one value type. Later registrations run first.
        Raises [Invalid_argument] if the name is taken. *)
    val register :
      name:string ->
      value:'a Syntax.Args.value ->
      ('node Provenance.located -> 'node reader -> 'a Provenance.located matched) ->
      'node t ->
      'node t

    (** Override the rule of this name in place. Raises [Invalid_argument] if
        there is none. *)
    val replace :
      name:string ->
      value:'a Syntax.Args.value ->
      ('node Provenance.located -> 'node reader -> 'a Provenance.located matched) ->
      'node t ->
      'node t

    (** Register a reading for lists of any item type: split the node into
        element nodes, each read with the item descriptor. Element diagnostics
        carry their index. Raises [Invalid_argument] if the name is taken. *)
    val register_items :
      name:string ->
      ('node Provenance.located -> 'node Provenance.located list Provenance.located matched) ->
      'node t ->
      'node t

    (** A rule can reuse the reader to extract values from child nodes. *)
    val read : 'node reader -> 'a Syntax.Args.value -> 'node Provenance.located ->
      'a Provenance.located matched

    val reader : 'node t -> 'node reader

    (** A named field before its value has been read. *)
    type 'node field = {
      name : string Provenance.located;
      value : 'node Provenance.located;
    }

    (** Read named fields using the declaration. Keep order and duplicates for
        Frontend decoding. Report unknown fields and unreadable values here. *)
    val read_arguments :
      'node reader -> 'args Syntax.Action.t -> 'node field list ->
      (Payload.field list, Diagnostic.t list) result

    (** Use the same readers for metadata fields described by a record schema.
        A dotted key such as [capture.type] writes a field of a record field,
        so [:CAPTURE.TYPE:] and [capture = { type = ... }] read alike. *)
    val read_metadata :
      'node reader -> Schema.field list -> 'node field list ->
      (Payload.field list, Diagnostic.t list) result
  end
  ```
]

== 身份规则表 <syntax:rules.mli-identity>

身份规则表运行在卡片声明处 (例如标题行或属性抽屉)，负责判断某个构造是否声明了一张卡片以及它的 ID 是什么。把身份提取独立成一张规则表，是为了让 @syntax:card.mli[Card] 能在解码元数据之前先收齐整批文档的卡片身份；即使项目元数据的解码依赖整批 ID，预登记也不会被阻塞。

#chunk(id: <source-syntax-rules-mli-identity>)[
  ```ocaml
  module Identity_rules : sig
    (** Identity rules run at declarations, such as a note heading. *)
    type 'node t

    val empty : 'node t

    (** Raises [Invalid_argument] if the name is taken. *)
    val register :
      name:string ->
      ('node Provenance.located -> Graph.Vertex_id.t Provenance.located matched) ->
      'node t ->
      'node t

    (** Raises [Invalid_argument] if there is no rule of this name. *)
    val replace :
      name:string ->
      ('node Provenance.located -> Graph.Vertex_id.t Provenance.located matched) ->
      'node t ->
      'node t

    val read : 'node t -> 'node Provenance.located -> Graph.Vertex_id.t Provenance.located matched
  end
  ```
]

== 行动规则表与正文组装 <syntax:rules.mli-action>

行动规则表运行在卡片正文中，每条规则对应一种语法糖 (例如 `"at-reference"`)，通用具名调用 (`named`) 也只是其中的一条规则。通过 `bind` 注册语法糖时直接绑定到类型化的 `Syntax.Action.t`，由 OCaml 类型系统保证参数齐全，最终与具名调用归一为同一种 `Invocation.t`。

`body` 体现了正文层的组合提交：它按节点顺序把原文切片与识别出的行动交错拼成正文；当某个节点本身不可读、规则返回 `Invalid`，或行动范围越界重叠时，该位置会保留原文并在原地落下一条可读失败记录，而不影响同张卡片里其他行动的提取。

#chunk(id: <source-syntax-rules-mli-action>)[
  ```ocaml
  module Action_rules : sig
    (** An action found in a body, and the source it takes out of the
        surrounding text. [taken = None] takes nothing. *)
    type occurrence = {
      call : Invocation.t Provenance.located;
      taken : Provenance.span option;
    }

    (** Action rules run in a note body. Each rule is a syntax sugar, named for
        the form it reads, such as ["at-reference"]; several sugars may write
        the same action. The context supplies the lookups and value readers the
        adapter makes available to its rules. Later rules run first. *)
    type ('node, 'context) t

    val empty : ('node, 'context) t

    (** Raises [Invalid_argument] if the sugar is taken. *)
    val register :
      sugar:string ->
      ('node Provenance.located -> 'context -> occurrence matched) ->
      ('node, 'context) t ->
      ('node, 'context) t

    (** Override a sugar in place. Raises [Invalid_argument] if there is none,
        so a misspelled override cannot pass silently. *)
    val replace :
      sugar:string ->
      ('node Provenance.located -> 'context -> occurrence matched) ->
      ('node, 'context) t ->
      ('node, 'context) t

    (** Register a sugar that reads the arguments of an action. The call is
        located at the node; it takes [taken node], the node's span by default. *)
    val bind :
      sugar:string ->
      ?taken:('node Provenance.located -> Provenance.span option) ->
      'args Syntax.Action.t ->
      ('node Provenance.located -> 'context -> 'args matched) ->
      ('node, 'context) t ->
      ('node, 'context) t

    (** [bind], overriding an existing sugar. *)
    val rebind :
      sugar:string ->
      ?taken:('node Provenance.located -> Provenance.span option) ->
      'args Syntax.Action.t ->
      ('node Provenance.located -> 'context -> 'args matched) ->
      ('node, 'context) t ->
      ('node, 'context) t

    val read : ('node, 'context) t -> 'context -> 'node Provenance.located ->
      occurrence matched

    (** A body span of [source]: verbatim text around the actions read from its
        nodes, in node order. An action stands at the start of what it takes;
        with nothing taken, at its call's position, keeping the text there; an
        unlocated call follows the preceding content.

        A node may arrive already known to be unreadable ([Error]). Such a node,
        a rule answering [Invalid], or an action placed outside the body or over
        a preceding one becomes an unreadable action at its start, keeping its
        text. The body is always assembled; its failures stay in place. *)
    val body :
      ('node, 'context) t -> 'context -> source:Text.t -> Provenance.span ->
      ('node, Diagnostic.t list) result Provenance.located list ->
      Invocation.t Frontend.read Observation.Source.content Provenance.located list

    (** Resolve the name and extract the arguments of a named call. *)
    val named :
      ('metadata, 'action) Syntax.Frontend_input.t ->
      'node Payload_rules.reader ->
      name:string Provenance.located ->
      'node Payload_rules.field list ->
      (Invocation.t, Diagnostic.t list) result
  end
  ```
]

#chunk(id: <file-syntax-rules-mli>, target: "syntax/rules.mli")[
  ```ocaml
  <<source-syntax-rules-mli-matched>>
  <<source-syntax-rules-mli-payload>>
  <<source-syntax-rules-mli-identity>>
  <<source-syntax-rules-mli-action>>
  ```
]
