#import "/reader/book.typ": card-source, chunk
#show: card-source

= 语法接入契约 <core:src:syntax.mli>

在@local-data[]中，一份笔记文档在逻辑上由@core:src:text.mli[普通文本]与嵌入其中的@source-core-src-syntax-mli-action[行动调用]交错构成。如何把这两部分从不同 @lml[] 的源码中稳定地识别并提取出来，是本模块要解决的核心问题，具体实现见 @core:src:syntax.ml[syntax.ml]。

面对用户自定义语义，如果所有行动都靠手写专用语法解析，每新增一种语义就要改动各个语言的 parser；反之，如果只允许冗长的具名调用 (例如 `#zk.cite(target: "b")`)，笔记的日常书写体验又会变差。因此，我们让*通用具名调用*与*语言特定的语法糖* (例如 `@b`、`[[id:b]]` 或嵌套标题) 共用同一套行动声明：通用规则覆盖项目注册的全部行动作为保底，语法糖按需叠加并把结果归一为同一种未解码调用。

== 参数与值描述 <core:src:syntax.mli-args>

语法层在读取参数或元数据时，往往需要知道字段的预期类型才能决定如何解释原始文本 (例如同一串数字按字段要求可以读成字符串或整数)；前端在解码时又需要同一份字段结构来做校验。`Args` 把值类型与记录字段的描述同时用作“读取指引”与“写入编码”：语法糖构造出带源码位置的类型化参数后，通过 `encode` 与 `spec` 转成统一的 `Payload`，不会丢失原始位置，也不必在语法层与前端之间维护两份字段定义。

#chunk(id: <source-core-src-syntax-mli-args>)[
  ```ocaml
  (** The Syntax contract: how language adapters hand the current layer to the
      core, and how each action declares its arguments once for both Syntax and
      Frontend. Rule tables for writing adapters are in [Ospero.Syntax]. *)
  open Frontend

  module Args : sig
    (** The descriptor of a value expected at a parameter or metadata field.
        For example, a rule registered for [string] must return a string. *)
    type 'a value

    val string : string value
    val bool : bool value
    val int : int value
    val contents : Text.t value
    val list : 'a value -> 'a Provenance.located list value
    val record : Payload.field list value

    (** A closed vocabulary of [values], written as [spell value]. Decoding
        accepts exactly these spellings; values themselves are never compared.
        Raises [Invalid_argument] when two values share a spelling. *)
    val choice : spell:('a -> string) -> 'a list -> 'a value

    (** A value checked when decoding; [encode] writes it back. *)
    val refine :
      ('a -> ('b, string) result) -> encode:('b -> 'a) -> 'a value -> 'b value

    (** Convert the extracted value to Payload without changing its location. *)
    val encode : 'a value -> 'a Provenance.located -> Payload.t

    (** The item descriptor of a list descriptor, which refines the value type.
        Rules that read a list of any item type use it. *)
    type _ items = Items : 'b value -> 'b Provenance.located list items

    val items : 'a value -> 'a items option

    (** A descriptor whose value type is hidden. *)
    type packed = Value : 'a value -> packed

    (** The descriptor of the payload that carries a value. Choices and
        refinements are carried by the value they refine. *)
    val carrier : 'a value -> packed

    (** The carrier able to hold a value of this shape. *)
    val of_shape : Schema.shape -> packed

    type (_, _) equality = Equal : ('a, 'a) equality

    (** Equal carriers prove equal value types. Refined values never compare
        equal; compare their carriers instead. *)
    val equal : 'a value -> 'b value -> ('a, 'b) equality option

    (** Declare record fields once for both reading and writing typed arguments.
        Getters preserve the source positions supplied by a syntax rule. *)
    type ('args, 'a) fields
    type 'args t

    val empty : ('args, unit) fields

    val required :
      string -> 'a value -> get:('args -> 'a Provenance.located) ->
      ('args, 'a Provenance.located) fields

    val optional :
      string -> 'a value -> get:('args -> 'a Provenance.located option) ->
      ('args, 'a Provenance.located option) fields

    val ( let+ ) : ('args, 'a) fields -> ('a -> 'b) -> ('args, 'b) fields
    val ( and+ ) : ('args, 'a) fields -> ('args, 'b) fields -> ('args, 'a * 'b) fields
    val spec : ('args, 'args) fields -> 'args t
  end
  ```
]

== 行动声明与语法糖桥接 <core:src:syntax.mli-action>

`Action.t` 是连接通用规则、语法糖与前端解码的公共锚点。具名调用规则按行动名查找 `Action.packed`，根据 `parameters` 依次调用 @syntax:rules.mli-payload[值规则表]读取参数；语法糖规则则在注册时直接绑定具体的 `'args Action.t`，由 OCaml 类型系统约束必填字段与类型，再通过 `invocation` 写出同一种 `Invocation.t`。这样无论用户写的是通用调用还是某种语言特有的简写，进入正文序列的都是统一的调用对象。

#chunk(id: <source-core-src-syntax-mli-action>)[
  ```ocaml
  module Action : sig
    (** A named input declaration shared by the frontend and syntax rules. *)
    type 'args t
    type packed = Pack : 'args t -> packed

    val declare : name:string -> 'args Args.t -> 'args t
    val name : 'args t -> string
    val describe : 'args t -> Schema.shape

    (** Parameter names and their declared descriptors, in declaration order. *)
    val parameters : 'args t -> (string * Args.packed) list

    (** Write typed arguments as an undecoded call, named at [span]. *)
    val invocation : ?span:Provenance.span -> 'args t -> 'args -> Invocation.t
  end
  ```
]

== 单一输入表 <core:src:syntax.mli-input>

`Frontend_input` 把项目的元数据 @core:src:schema.mli[Schema] 与全部行动条目收进同一张表：语法层从表中查行动名与元数据形状，前端层直接复用表上的 `decode_metadata` 与 `decode_action` 实现 `Frontend.DECODING`。通过 `add` 与 `replace` 扩展或覆盖行动时，重名与误拼都会被立即拦下。

#chunk(id: <source-core-src-syntax-mli-input>)[
  ```ocaml
  module Frontend_input : sig
    (** A single table supplies both Syntax lookup and Frontend decoding. *)
    type ('metadata, 'action) t

    (** An action declaration with the decoder constructing a project action. *)
    type 'action entry

    val action :
      'args Action.t -> decode:('args -> ('action, Diagnostic.t list) result) ->
      'action entry

    (** The metadata schema and the action table. Raises [Invalid_argument]
        when two entries share a name. *)
    val create : metadata:'metadata Schema.t -> 'action entry list -> ('metadata, 'action) t

    (** Add an action. Raises [Invalid_argument] if its name is taken. *)
    val add : 'action entry -> ('metadata, 'action) t -> ('metadata, 'action) t

    (** Override an action of the same name. Raises [Invalid_argument] if
        there is none, so a misspelled override cannot pass silently. *)
    val replace : 'action entry -> ('metadata, 'action) t -> ('metadata, 'action) t

    val find_action : ('metadata, 'action) t -> string -> Action.packed option
    val action_names : ('metadata, 'action) t -> string list
    val metadata_shape : ('metadata, 'action) t -> Schema.shape

    (** Use these two functions to implement [Frontend.DECODING]. *)
    val decode_metadata :
      ('metadata, 'action) t -> Payload.t -> ('metadata, Diagnostic.t list) result

    val decode_action :
      ('metadata, 'action) t -> Invocation.t -> ('action, Diagnostic.t list) result
  end
  ```
]

== 跨语言适配器与两处数据入口 <core:src:syntax.mli-adapter>

多语言混排的项目通过 `configure` 为每种语言挂接一个 `adapter`：

#chunk(id: <source-core-src-syntax-mli-adapter-types>)[
  ```ocaml
  (** A source document in the adapter's own representation, such as an
      already parsed and cached tree. *)
  type 'native document = {
    file : string;
    language : Text.Language.t;
    native : 'native;
  }

  type raw_note = Frontend.raw_note

  (** What an adapter read from one document. A problem owned by a card stays
      inside its note, as unreadable metadata or an unreadable action at its
      place. [diagnostics] holds only problems no card owns, such as a heading
      outside every card. Root IDs come from the notes; [declared] lists the
      identities that become notes only during expansion. *)
  type extracted = {
    notes : raw_note Provenance.located list;
    declared : Graph.Vertex_id.t Provenance.located list;
    diagnostics : Diagnostic.t list;
  }

  (** An adapter reads one source language at both entry points of the data
      flow: whole documents, and Contents retained by an action. *)
  type 'native adapter = {
    language : Text.Language.t;
    extract : 'native document -> extracted;
    contents :
      Text.t Provenance.located -> (raw_note Provenance.located, Diagnostic.t list) result;
        (** The note defined by these Contents, as its current layer. [Error]
            only when the Contents define no single card. *)
  }

  type 'native config

  (** One adapter per language. Raises [Invalid_argument] when two adapters
      share a language. *)
  val configure : 'native adapter list -> 'native config
  ```
]

它在数据流的两个入口工作：

- `parse_project` 在前端解码之前处理整批文档，把各适配器抽出的根卡片按顺序汇入 `raw_project`，并合并 `declared` 中预扫描出的嵌套定义 ID。属于某张卡片的读取失败留在卡片内部，只有卡片外无归属的问题 (或缺少适配器的文档) 进入文档级诊断。
  #chunk(id: <source-core-src-syntax-mli-parse-project>)[
    ```ocaml
    (** Extract the batch before any frontend decoding, keeping note order. Every
        readable card contributes, whatever fails around it. The diagnostics are
        the problems no card owns, including documents without an adapter. *)
    val parse_project :
      'native config -> 'native document list -> Frontend.raw_project * Diagnostic.t list
    ```
  ]
- `parse_contents` 供行动解释器在展开携带 `Contents` 的调用时按其语言标签再读下一层，产出该层 `raw_note` 供前端解码；因为整批身份在 `parse_project` 时已经冻结，此处不再新增身份。
  #chunk(id: <source-core-src-syntax-mli-parse-contents>)[
    ```ocaml
    (** The next layer inside Contents, read by the adapter for their language.
        An interpreter decodes it with [Frontend.DECODER.decode_source]; the
        identities were frozen with the project and none are added here. *)
    val parse_contents :
      'native config -> Text.t Provenance.located ->
      (raw_note Provenance.located, Diagnostic.t list) result
    ```
  ]

#chunk(id: <source-core-src-syntax-mli-adapter>)[
  ```ocaml
  <<source-core-src-syntax-mli-adapter-types>>
  <<source-core-src-syntax-mli-parse-project>>
  <<source-core-src-syntax-mli-parse-contents>>
  ```
]

#chunk(id: <file-core-src-syntax-mli>, target: "core/src/syntax.mli")[
  ```ocaml
  <<source-core-src-syntax-mli-args>>
  <<source-core-src-syntax-mli-action>>
  <<source-core-src-syntax-mli-input>>
  <<source-core-src-syntax-mli-adapter>>
  ```
]
