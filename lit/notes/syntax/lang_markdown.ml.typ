#import "/reader/book.typ": card-source, chunk
#show: card-source

= Markdown 默认嵌入 DSL 的具体实现 <syntax:lang_markdown.ml>

本节给出 @syntax:lang_markdown.mli[] 的具体实现。

== 基础定义 <syntax:lang_markdown.ml:types>

声明语言标识 `"markdown"`、接口对应的类型，并直接复用 `Value.rules`。

#chunk(id: <source-syntax-lang-markdown-ml-types>)[
  ```ocaml
  open Ospero_kernel
  module Identity_rules = Rules.Identity_rules
  module Action_rules = Rules.Action_rules

  let language = Result.get_ok (Text.Language.of_string "markdown")

  type value = Value.t

  type metadata = {
    fields : Value.field list;
    diagnostics : Frontend.Diagnostic.t list;
    insertion : Provenance.span;
  }

  type heading = {
    level : int;
    title : string Provenance.located;
    metadata : metadata option;
  }

  type node =
    | Directive of {
        name : string Provenance.located;
        arguments : Value.field list Frontend.read;
        body : Text.t Provenance.located option;
        inner : node Provenance.located list;
      }
    | Card of Card.nested

  type context = value Card.context

  let values = Value.rules
  ```
]

== 身份识别规则 <syntax:lang_markdown.ml:identities>

`"meta-id"` 只在标题附带 `zk-meta` 时触发。若围栏里同时存在已解析字段和 TOML 语法错误，校验失败会一并附带 `diagnostics`；缺失 `id` 且无语法错误时，给出指向围栏首行的 `Missing_identity` 插入建议。

#chunk(id: <source-syntax-lang-markdown-ml-identities>)[
  ```ocaml
  let identities =
    Identity_rules.empty
    |> Identity_rules.register ~name:"meta-id" (fun (h : heading Provenance.located) ->
         match h.value.metadata with
         | None -> Rules.No_match
         | Some { fields; diagnostics; insertion } ->
             match List.find_opt (fun ((k : string Provenance.located), _) -> k.value = "id") fields with
             | Some (_, { value = String s; span }) ->
                 (match Graph.Vertex_id.of_string s with
                  | Ok id -> Rules.Matched (Provenance.located ?span id)
                  | Error message -> Rules.Invalid (Card.invalid ?span message :: diagnostics))
             | Some (_, v) ->
                 Rules.Invalid (Card.invalid ?span:v.span "id must be a quoted string" :: diagnostics)
             | None ->
                 match diagnostics with
                 | [] ->
                     Rules.Invalid [ Frontend.Diagnostic.make ?span:h.span
                       (Missing_identity { insertion = Some insertion; prefix = "id = \""; suffix = "\"\n" }) ]
                 | _ -> Rules.Invalid diagnostics)
  ```
]

== 块级扫描 <syntax:lang_markdown.ml:scan>

Markdown 适配器按行扫描块级结构，不解析行内语法。围栏代码块的优先级高于标题与指令容器，防止示例代码里的 `#` 或 `:::` 误触发结构识别。

=== 行与围栏边界 <syntax:lang_markdown.ml:scan-fence>

CommonMark 允许块标记前出现至多三个空格缩进，`indent` 统一处理这一点。

#chunk(id: <source-syntax-lang-markdown-ml-scan-fence>)[
  ```ocaml
  let span file start stop = { Provenance.file; start; stop }
  let at file text start stop =
    Provenance.located ~span:(span file start stop) (String.sub text start (stop - start))
  let line_end text pos =
    match String.index_from_opt text pos '\n' with Some i -> i | None -> String.length text
  let next_line text pos = min (String.length text) (line_end text pos + 1)
  let indent text pos stop =
    let i = ref pos in
    while !i < stop && !i - pos < 3 && text.[!i] = ' ' do incr i done;
    !i
  let run text pos stop c =
    let i = ref pos in
    while !i < stop && text.[!i] = c do incr i done;
    !i - pos
  let blank text pos stop = String.trim (String.sub text pos (stop - pos)) = ""

  let fence text pos e =
    let s = indent text pos e in
    if s >= e then None
    else
      let c = text.[s] in
      let n = run text s e c in
      if (c = '`' || c = '~') && n >= 3 then
        Some (c, n, String.trim (String.sub text (s + n) (e - s - n)))
      else None

  let fence_close text (c, n) from stop =
    let rec go pos =
      if pos >= stop then stop, stop
      else
        let e = min stop (line_end text pos) in
        let s = indent text pos e in
        if s < e && text.[s] = c && run text s e c >= n && blank text (s + run text s e c) e
        then pos, next_line text pos
        else go (next_line text pos)
    in
    go from
  ```
]

=== 指令容器边界 <syntax:lang_markdown.ml:scan-directive>

`directive_end` 配对闭合 `:::` 时跳过内部围栏并追踪嵌套深度；未闭合的指令延伸到区域末尾。

#chunk(id: <source-syntax-lang-markdown-ml-scan-directive>)[
  ```ocaml
  let directive_open text pos e =
    let s = indent text pos e in
    let n = run text s e ':' in
    if n < 3 then None
    else
      let n0 = s + n in
      let n1 = ref n0 in
      let name_char = function
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true | _ -> false
      in
      while !n1 < e && name_char text.[!n1] do incr n1 done;
      if !n1 = n0 then None else Some (n0, !n1)

  let directive_close text pos e =
    let s = indent text pos e in
    let n = run text s e ':' in
    n >= 3 && blank text (s + n) e

  let directive_end text from stop =
    let rec go pos depth =
      if pos >= stop then Some (stop, stop)
      else
        let e = min stop (line_end text pos) in
        match fence text pos e with
        | Some (c, n, _) -> go (snd (fence_close text (c, n) (next_line text pos) stop)) depth
        | None ->
            if directive_open text pos e <> None then go (next_line text pos) (depth + 1)
            else if directive_close text pos e then
              if depth = 0 then Some (pos, e) else go (next_line text pos) (depth - 1)
            else go (next_line text pos) depth
    in
    go from 0

  let toml ~file text start stop = Toml.parse ~file text ~start ~stop
  ```
]

=== 区域、标题与扫描入口 <syntax:lang_markdown.ml:scan-region>

`region` 根据 `headings` 开关在顶层识别标题与指令，在指令正文中关闭标题识别、只递归收集内部指令。标题后允许空行再接 `zk-meta`，并用 `Toml.parse_prefix` 保留不完整输入时的前缀字段；指令内首个非空行若为 `zk-args` 围栏则解析为参数，其余非空文本作为 `body`。

#chunk(id: <source-syntax-lang-markdown-ml-scan-region>)[
  ```ocaml
  let rec region ~file ~headings text start stop =
    let heads = ref [] and nodes = ref [] in
    let rec go pos =
      if pos >= stop then ()
      else
        let e = min stop (line_end text pos) in
        match fence text pos e with
        | Some (c, n, _) -> go (snd (fence_close text (c, n) (next_line text pos) stop))
        | None ->
            let s = indent text pos e in
            let level = run text s e '#' in
            if headings && level >= 1 && level <= 6 && (s + level = e || text.[s + level] = ' ')
            then go (heading pos s e level)
            else
              match directive_open text pos e with
              | Some (n0, n1) ->
                  (match directive_end text (next_line text pos) stop with
                   | None -> go (next_line text pos)
                   | Some (close, close_end) ->
                       directive pos (n0, n1) close close_end;
                       go (if close >= stop then stop else next_line text close))
              | None -> go (next_line text pos)
    and heading pos s e level =
      let t0 = ref (s + level) in
      while !t0 < e && text.[!t0] = ' ' do incr t0 done;
      let t1 = ref e in
      while !t1 > !t0 && (text.[!t1 - 1] = ' ' || text.[!t1 - 1] = '\r') do decr t1 done;
      (* A closing run of # preceded by a space is not part of the title. *)
      let k = ref !t1 in
      while !k > !t0 && text.[!k - 1] = '#' do decr k done;
      if !k < !t1 && (!k = !t0 || text.[!k - 1] = ' ') then begin
        t1 := !k;
        while !t1 > !t0 && text.[!t1 - 1] = ' ' do decr t1 done
      end;
      let rec skip_blank p = if p < stop && blank text p (min stop (line_end text p)) then skip_blank (next_line text p) else p in
      let m = skip_blank (next_line text pos) in
      let metadata, metadata_span, body_start =
        let me = min stop (line_end text m) in
        match if m < stop then fence text m me else None with
        | Some (c, n, "zk-meta") ->
            let inner = next_line text m in
            let close, after = fence_close text (c, n) inner stop in
            let fields, diagnostics = Toml.parse_prefix ~file text ~start:inner ~stop:close in
            Some { fields; diagnostics; insertion = span file inner inner }, Some (span file m (min stop (max close (line_end text close)))), after
        | _ -> None, None, next_line text pos
      in
      let title = at file text !t0 !t1 in
      heads :=
        { Card.level;
          identity = Provenance.located ~span:(span file pos e) { level; title; metadata };
          title = Option.get title.span;
          metadata = (match metadata with
            | None -> Ok []
            | Some { fields; diagnostics = []; _ } -> Ok (Value.fields fields)
            | Some { diagnostics; _ } -> Error diagnostics);
          metadata_span; start = pos; body_start }
        :: !heads;
      body_start
    and directive pos (n0, n1) close close_end =
      let rec skip_blank p = if p < close && blank text p (min close (line_end text p)) then skip_blank (next_line text p) else p in
      let first = skip_blank (next_line text pos) in
      let fe = min close (line_end text first) in
      let arguments, body_start =
        match if first < close then fence text first fe else None with
        | Some (c, n, info) when List.mem "zk-args" (String.split_on_char ' ' info) ->
            let inner = next_line text first in
            let fclose, after = fence_close text (c, n) inner close in
            toml ~file text inner fclose, after
        | _ -> Ok [], next_line text pos
      in
      let body_start = min body_start close in
      let body =
        if blank text body_start close then None
        else
          Some (Provenance.located ~span:(span file body_start close)
                  { Text.text = String.sub text body_start (close - body_start); language })
      in
      let _, inner = region ~file ~headings:false text body_start close in
      nodes :=
        Provenance.located ~span:(span file pos close_end)
          (Directive { name = at file text n0 n1; arguments; body; inner })
        :: !nodes
    in
    go start;
    List.rev !heads, List.rev !nodes
  ```
]

#chunk(id: <source-syntax-lang-markdown-ml-scan-entry>)[
  ```ocaml
  let scan ~file text ~start =
    let headings, nodes = region ~file ~headings:true text start (String.length text) in
    { Card.headings; nodes; closes = [] }

  let children = function Directive { inner; _ } -> inner | Card _ -> []
  ```
]

#chunk(id: <source-syntax-lang-markdown-ml-scan>)[
  ```ocaml
  <<source-syntax-lang-markdown-ml-scan-fence>>
  <<source-syntax-lang-markdown-ml-scan-directive>>
  <<source-syntax-lang-markdown-ml-scan-region>>
  <<source-syntax-lang-markdown-ml-scan-entry>>
  ```
]

== 具名调用与适配器 <syntax:lang_markdown.ml:actions>

- `actions`: 注册 `"named-directive"`，剥离 `zk-` 前缀并前移位置跨度，再交给 `context.named` 解码。
  #chunk(id: <source-syntax-lang-markdown-ml-actions>)[
    ```ocaml
    let actions =
      Action_rules.empty
      |> Action_rules.register ~sugar:"named-directive" (fun node (context : context) ->
           match node.Provenance.value with
           | Directive { name; arguments; body; _ }
             when String.length name.value > 3 && String.sub name.value 0 3 = "zk-" ->
               let name =
                 { Provenance.value = String.sub name.value 3 (String.length name.value - 3);
                   span = Option.map (fun (s : Provenance.span) -> { s with start = s.start + 3 }) name.span }
               in
               (match Result.bind arguments (fun arguments -> context.named ~name ?body (Value.fields arguments)) with
                | Ok call ->
                    Rules.Matched
                      { Action_rules.call = Provenance.located ?span:node.span call; taken = node.span }
                | Error errors -> Rules.Invalid errors)
           | _ -> Rules.No_match)
    ```
  ]
- `adapter`: 将语言定义、扫描函数与三张规则表接入 `Card.adapter`。
  #chunk(id: <source-syntax-lang-markdown-ml-adapter>)[
    ```ocaml
    let adapter ?(values = values) ?(identities = identities) ?(actions = actions)
        ?(define = "define") frontend =
      Card.adapter
        { Card.language; source = Fun.id; scan = (fun ~file text -> scan ~file text ~start:0);
          read = scan; nested = (fun n -> Card n); children }
        ~values ~identities ~actions ~define frontend
    ```
  ]

== 语法糖实现 <syntax:lang_markdown.ml:sugar>

- `nested_card`: 直接委托给 `Card.nested_card`，从 `Card` 节点提取嵌套卡片。
  #chunk(id: <source-syntax-lang-markdown-ml-sugar-nested-card>)[
    ```ocaml
    let nested_card action make =
      Card.nested_card (function Card n -> Some n | _ -> None) action make
    ```
  ]

组装为 `Sugar` 模块：

#chunk(id: <source-syntax-lang-markdown-ml-sugar>)[
  ```ocaml
  module Sugar = struct
    <<source-syntax-lang-markdown-ml-sugar-nested-card>>
  end
  ```
]

按顺序组合为 `syntax/lang_markdown.ml`：

#chunk(id: <file-syntax-lang-markdown-ml>, target: "syntax/lang_markdown.ml")[
  ```ocaml
  <<source-syntax-lang-markdown-ml-types>>
  <<source-syntax-lang-markdown-ml-identities>>
  <<source-syntax-lang-markdown-ml-scan>>
  <<source-syntax-lang-markdown-ml-actions>>
  <<source-syntax-lang-markdown-ml-adapter>>
  <<source-syntax-lang-markdown-ml-sugar>>
  ```
]
