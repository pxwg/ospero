#import "/reader/book.typ": card-source, chunk
#show: card-source

= 卡片结构骨架 <syntax:card.mli>

不同@lml[]的标题、元数据与正文写法各不相同，但卡片的@syntax:card.mli-context[层级嵌套]、@syntax:card.mli-language[元数据挂载]、@syntax:rules.mli-action[正文组装]与@syntax:card.mli-adapter[身份预登记]遵循相同的结构逻辑。为了避免每个语言适配器重复实现这些流程，本模块把卡片层的公共骨架抽离出来，具体实现见 @syntax:card.ml[card.ml]。

接入一种新语言 (或复用外部 parser 缓存的语法树) 时，适配器只需要提供自己的 `language` 扫描器并组合 @syntax:rules.mli[Rules] 中的三张规则表，其余流程由本层统一完成。

== 嵌套卡片与正文上下文 <syntax:card.mli-context>

在正文视角下，一张嵌套子卡片也被视作一个普通的正文节点 `nested`，其范围从子卡片的首行元数据 (或标题) 一直延续到最后一个后代的结尾。这样嵌套子卡片就可以与其他正文语法糖一样，经由 @syntax:rules.mli-action[行动规则表]统一处理。

`context` 则是正文规则在读取节点时可以依赖的适配器能力：它把当前适配器自己的 `values` 读取器与 `named` 具名调用解析一并传给规则，确保各种语法糖在读取参数值时与具名调用保持完全一致。

#chunk(id: <source-syntax-card-mli-context>)[
  ```ocaml
  (** The card structure shared by language adapters. A scanner reports
      headings and body nodes; this layer decides which headings declare cards,
      nests them, reads metadata and assembles bodies with the rule tables.
      Contents of a [define] call are read back by the same language, so
      pre-registration and expansion take the ID from the same declaration.
      An adapter over another parser, such as a cached Org tree, supplies its
      own [language] and reuses the rest. *)
  open Ospero_kernel
  open Frontend

  (** A nested card seen as a body node. [extent] runs from the card's first
      metadata line, or its heading, to the end of its last descendant. *)
  type nested = { level : int; extent : Provenance.span }

  (** What a body rule may use. [values] and [named] are the adapter's own, so a
      sugar reads values exactly as named calls do. *)
  type 'value context = {
    level : int;  (** The heading level of the card whose body is read. *)
    slice : Provenance.span -> Text.t Provenance.located;
        (** Source text of a span, tagged with the adapter's language. *)
    values : 'value Rules.Payload_rules.reader;
    named :
      name:string Provenance.located -> ?body:Text.t Provenance.located ->
      'value Rules.Payload_rules.field list -> (Invocation.t, Diagnostic.t list) result;
        (** Resolve a named call. A trailing body is passed to the one parameter
            the action declares with [Args.contents]. *)
  }
  ```
]

== 语言扫描器契约 <syntax:card.mli-language>

语言扫描器不负责决定哪些标题是卡片、也不做类型解码，它只按源码顺序报告三类事实：标题候选 `headings`、正文节点 `nodes` 以及显式的卡片结束标记 `closes`。其中，即使某条标题的元数据本身无法被扫描器读出，该标题仍会作为 `Error` 携带诊断向上报告，而不中断整份文档的扫描。

`language` 同时要求提供 `scan` (读取整份文档) 与 `read` (在原偏移处读取 `Contents`) 两个入口。后者通过对前缀做换行填充，使二次读取 `Contents` 时得到的源码位置仍然与原文件的字节偏移保持一致。

#chunk(id: <source-syntax-card-mli-language>)[
  ```ocaml
  (** A heading reported by a scanner. Identity rules read [identity]; when one
      matches, the heading declares a card. Metadata the scanner could not read
      is [Error]; the card is still declared and its metadata reported. *)
  type ('heading, 'value) heading = {
    level : int;
    identity : 'heading Provenance.located;
    title : Provenance.span;
    metadata : 'value Rules.Payload_rules.field list Frontend.read;
    metadata_span : Provenance.span option;
    start : int;  (** Where the card begins, including metadata written before it. *)
    body_start : int;  (** Where the body begins, after heading and metadata. *)
  }

  (** Everything a scanner finds in one text, in source order. [nodes] contains
      the nodes outside headings' metadata, nested nodes being reachable through
      [children]. *)
  type ('heading, 'value, 'node) outline = {
    headings : ('heading, 'value) heading list;
    nodes : 'node Provenance.located list;
    closes : int list;
        (** Explicit card ends, in source order; each closes the innermost card
            still open where it stands. *)
  }

  type ('native, 'heading, 'value, 'node) language = {
    language : Text.Language.t;
    source : 'native -> string;
        (** The text the native document was read from. Spans index it. *)
    scan : file:string -> 'native -> ('heading, 'value, 'node) outline;
        (** Read a whole document. A scanner reports problems in the construct
            they belong to, such as unreadable metadata, and never gives up on
            the document. *)
    read : file:string -> string -> start:int -> ('heading, 'value, 'node) outline;
        (** Read Contents in place: scan from [start] to the end of the text,
            which is padded with newlines so that spans stay file offsets. *)
    nested : nested -> 'node;
    children : 'node -> 'node Provenance.located list;
        (** Nodes inside a node, read in its place when no body rule takes it. *)
  }
  ```
]

== 卡片组装与预登记 <syntax:card.mli-adapter>

`adapter` 将 `language`、三张规则表与 @core:src:syntax.mli[Frontend_input] 组装为一个标准的 `Syntax.adapter`。

对于名为 `define` 的行动调用，`adapter` 会用同一个语言的 `read` 回读其 `Contents` 参数，提前抽出其中声明的卡片 ID 加入预登记集合；等后续展开真正读取这份 `Contents` 时，使用的仍然是同一份声明，从而保证预登记与内容绑定同源。`nested_card` 则把嵌套子卡片直接绑定到同一个 `define` 行动上，作为名为 `"nested-card"` 的语法糖。

失败同样在卡片粒度就地隔离：身份规则返回 `Invalid` 的标题不会声明卡片，而是留在外层卡片中作为一条不可读的行动记录 (若位于所有卡片之外，则归入文档级诊断)；坏元数据与坏正文构造则留在各自所属的卡片中，不影响其余卡片的抽取。

#chunk(id: <source-syntax-card-mli-adapter>)[
  ```ocaml
  (** Calls of the action named [define] have their Contents arguments read
      as cards whose IDs are pre-registered. With [~unknown_metadata:`Ignore],
      metadata fields the schema does not declare are dropped instead of
      reported.

      Failures degrade only their card. A heading whose identity rule answers
      [Invalid] declares no card and stays a section of the enclosing card,
      where its diagnostics stand as an unreadable action; outside every card
      they are document diagnostics. Unreadable metadata and body constructs
      stay in their note. Raises [Invalid_argument] unless the metadata schema
      describes a record. *)
  val adapter :
    ('native, 'heading, 'value, 'node) language ->
    ?unknown_metadata:[ `Ignore | `Report ] ->
    values:'value Rules.Payload_rules.t ->
    identities:'heading Rules.Identity_rules.t ->
    actions:('node, 'value context) Rules.Action_rules.t ->
    define:string ->
    ('metadata, 'action) Syntax.Frontend_input.t ->
    'native Syntax.adapter

  (** Bind nested cards to a define action, as the sugar ["nested-card"]. The
      Contents cover the card's metadata, heading and body; the depth is the
      difference of heading levels. *)
  val nested_card :
    ('node -> nested option) ->
    'args Syntax.Action.t ->
    (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
    ('node, 'value context) Rules.Action_rules.t ->
    ('node, 'value context) Rules.Action_rules.t

  (** A diagnostic at a span. *)
  val invalid : ?span:Provenance.span -> string -> Diagnostic.t
  ```
]

#chunk(id: <file-syntax-card-mli>, target: "syntax/card.mli")[
  ```ocaml
  <<source-syntax-card-mli-context>>

  <<source-syntax-card-mli-language>>

  <<source-syntax-card-mli-adapter>>
  ```
]
