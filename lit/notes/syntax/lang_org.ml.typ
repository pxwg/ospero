#import "/reader/book.typ": card-source, chunk
#show: card-source

= Org 默认嵌入 DSL 的具体实现 <syntax:lang_org.ml>

本节给出 @syntax:lang_org.mli[] 的具体实现。

== 基础定义与文本辅助 <syntax:lang_org.ml:types>

声明语言标识 `"org"`、接口对应的节点类型，以及行扫描与大小写无关前缀匹配的基础工具。

#chunk(id: <source-syntax-lang-org-ml-types>)[
  ```ocaml
  open Ospero_kernel
  module Payload_rules = Rules.Payload_rules
  module Identity_rules = Rules.Identity_rules
  module Action_rules = Rules.Action_rules

  let language = Result.get_ok (Text.Language.of_string "org")

  type value = string

  type heading = {
    level : int;
    title : string Provenance.located;
    properties : (string Provenance.located * value Provenance.located) list;
  }

  type node =
    | Keyword of {
        name : string Provenance.located;
        value : value Provenance.located;
        inner : node Provenance.located list;
      }
    | Block of {
        name : string Provenance.located;
        parameters : value Provenance.located;
        contents : Text.t Provenance.located;
        inner : node Provenance.located list;
      }
    | Link of {
        path : string Provenance.located;
        description : string Provenance.located option;
      }
    | Card of Card.nested

  type context = value Card.context
  ```
]

#chunk(id: <source-syntax-lang-org-ml-text-helpers>)[
  ```ocaml
  let is_space = function ' ' | '\t' | '\r' -> true | _ -> false
  let span file start stop = { Provenance.file; start; stop }
  let at file text start stop =
    Provenance.located ~span:(span file start stop) (String.sub text start (stop - start))

  let trim text start stop =
    let start = ref start and stop = ref stop in
    while !start < !stop && (is_space text.[!start] || text.[!start] = '\n') do incr start done;
    while !stop > !start && (is_space text.[!stop - 1] || text.[!stop - 1] = '\n') do decr stop done;
    !start, !stop

  let line_end text pos =
    match String.index_from_opt text pos '\n' with Some i -> i | None -> String.length text

  let next_line text pos = min (String.length text) (line_end text pos + 1)

  let prefixed ~prefix text pos stop =
    let n = String.length prefix in
    pos + n <= stop && String.lowercase_ascii (String.sub text pos n) = prefix

  let skip_blank text pos stop =
    let p = ref pos in
    while !p < stop && is_space text.[!p] do incr p done;
    !p
  ```
]

== 延迟类型化值与参数解析 <syntax:lang_org.ml:values>

Org 的属性值与参数表都是从原文切出的子串：

- 切片与顶层切分：`sub` 在切片时平移父值的 `Provenance.span`，保证子元素诊断指向原文件准确位置；`split_top` 只在引号和括号外切分分隔符，供列表项与 `:key value` 参数共用。
  #chunk(id: <source-syntax-lang-org-ml-value-helpers>)[
    ```ocaml
    let sub (v : value Provenance.located) start stop =
      let base = match v.span with Some s -> s.start | None -> 0 in
      let span = Option.map (fun (s : Provenance.span) ->
        { s with start = base + start; stop = base + stop }) v.span in
      Provenance.located ?span (String.sub v.value start (stop - start))

    let split_top ~separator s =
      let pieces = ref [] and depth = ref 0 and quoted = ref false and from = ref 0 in
      String.iteri (fun i c ->
        if !quoted then (if c = '"' && (i = 0 || s.[i - 1] <> '\\') then quoted := false)
        else match c with
          | '"' -> quoted := true
          | '[' | '(' -> incr depth
          | ']' | ')' -> decr depth
          | c when !depth = 0 && separator c ->
              pieces := (!from, i) :: !pieces; from := i + 1
          | _ -> ()) s;
      List.rev ((!from, String.length s) :: !pieces)

    let unquote s =
      let n = String.length s in
      if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then begin
        let b = Buffer.create n in
        let i = ref 1 in
        while !i < n - 1 do
          if s.[!i] = '\\' && !i + 1 < n - 1 then (Buffer.add_char b s.[!i + 1]; i := !i + 2)
          else (Buffer.add_char b s.[!i]; incr i)
        done;
        Some (Buffer.contents b)
      end else None
    ```
  ]
- `values`: 按声明的字段类型解析字符串、整数、布尔与列表。
  #chunk(id: <source-syntax-lang-org-ml-values>)[
    ```ocaml
    let values =
      let open Payload_rules in
      let scalar read (v : value Provenance.located) _ =
        match read (String.trim v.value) with
        | Some x -> Rules.Matched { v with value = x }
        | None -> Rules.No_match
      in
      let items (v : value Provenance.located) =
        let s = v.value in
        let start, stop = trim s 0 (String.length s) in
        let pieces, offset, separator =
          if stop - start >= 2 && s.[start] = '[' && s.[stop - 1] = ']' then
            String.sub s (start + 1) (stop - start - 2), start + 1, (fun c -> c = ',')
          else String.sub s start (stop - start), start, is_space
        in
        let elements =
          split_top ~separator pieces
          |> List.filter_map (fun (a, b) ->
               let a, b = trim pieces a b in
               if a = b then None else Some (sub v (offset + a) (offset + b)))
        in
        Rules.Matched { v with value = elements }
      in
      empty
      |> register ~name:"string" ~value:Syntax.Args.string
           (scalar (fun s -> Some (Option.value (unquote s) ~default:s)))
      |> register ~name:"int" ~value:Syntax.Args.int (scalar int_of_string_opt)
      |> register ~name:"bool" ~value:Syntax.Args.bool
           (scalar (function "true" -> Some true | "false" -> Some false | _ -> None))
      |> register_items ~name:"list" items
    ```
  ]
- `arguments`: 把参数串按顶层 `:key` 切成键值段，每个值延伸到下一个顶层 `:key`。
  #chunk(id: <source-syntax-lang-org-ml-arguments>)[
    ```ocaml
    let arguments (v : value Provenance.located) =
      let s = v.value in
      let keys =
        split_top ~separator:is_space s
        |> List.filter (fun (a, b) -> b > a + 1 && s.[a] = ':')
      in
      let leading =
        let first = match keys with (a, _) :: _ -> a | [] -> String.length s in
        let a, b = trim s 0 first in
        if a < b then [ Card.invalid ?span:(sub v a b).span "expected :key before this value" ] else []
      in
      let rec fields = function
        | [] -> []
        | (a, b) :: rest ->
            let stop = match rest with (next, _) :: _ -> next | [] -> String.length s in
            let va, vb = trim s b stop in
            { Payload_rules.name = sub v (a + 1) b; value = sub v va vb } :: fields rest
      in
      match leading with [] -> Ok (fields keys) | errors -> Error errors
    ```
  ]

== 身份识别规则 <syntax:lang_org.ml:identities>

`"id-property"` 大小写无关地查找 `:ID:` 属性，并用 `Graph.Vertex_id.of_string` 校验。

#chunk(id: <source-syntax-lang-org-ml-identities>)[
  ```ocaml
  let identities =
    Identity_rules.empty
    |> Identity_rules.register ~name:"id-property" (fun (h : heading Provenance.located) ->
         match List.find_opt (fun ((k : string Provenance.located), _) ->
                 String.lowercase_ascii k.value = "id") h.value.properties with
         | None -> Rules.No_match
         | Some (_, v) ->
             match Graph.Vertex_id.of_string (String.trim v.value) with
             | Ok id -> Rules.Matched { v with value = id }
             | Error message -> Rules.Invalid [ Card.invalid ?span:v.span message ])
  ```
]

== 大纲与区域扫描 <syntax:lang_org.ml:scan>

=== 链接与块边界 <syntax:lang_org.ml:scan-links-blocks>

`links` 提取行内的 `[[path]]` 与 `[[path][desc]]`；`block_end` 配对 `#+end_<name>`；`verbatim` 列出内部不递归扫描的逐字块。

#chunk(id: <source-syntax-lang-org-ml-scan-links-blocks>)[
  ```ocaml
  let links file text start stop =
    let rec go pos acc =
      match String.index_from_opt text pos '[' with
      | Some i when i + 1 < stop && text.[i + 1] = '[' ->
          (match String.index_from_opt text (i + 2) ']' with
           | Some j when j < stop ->
               let path = at file text (i + 2) j in
               if j + 1 < stop && text.[j + 1] = ']' then
                 go (j + 2) (Provenance.located ~span:(span file i (j + 2))
                               (Link { path; description = None }) :: acc)
               else if j + 1 < stop && text.[j + 1] = '[' then
                 match String.index_from_opt text (j + 2) ']' with
                 | Some k when k + 1 < stop && text.[k + 1] = ']' ->
                     let description = Some (at file text (j + 2) k) in
                     go (k + 2) (Provenance.located ~span:(span file i (k + 2))
                                   (Link { path; description }) :: acc)
                 | _ -> go (j + 1) acc
               else go (j + 1) acc
           | _ -> List.rev acc)
      | Some i when i < stop -> go (i + 1) acc
      | _ -> List.rev acc
    in
    if start >= stop then [] else go start []

  let verbatim = [ "src"; "example"; "export"; "comment" ]

  let block_end text name from stop =
    let close = "#+end_" ^ String.lowercase_ascii name in
    let rec go pos =
      if pos >= stop then None
      else
        let s = skip_blank text pos stop in
        let e = line_end text pos in
        if prefixed ~prefix:close text s e && String.trim (String.sub text s (e - s)) |> String.length
           = String.length close
        then Some (pos, e)
        else go (next_line text pos)
    in
    go from

  let keyword_name text pos stop =
    let i = ref pos in
    while !i < stop && not (is_space text.[!i]) && text.[!i] <> ':' do incr i done;
    !i
  ```
]

=== 任务关键字与标题前缀 <syntax:lang_org.ml:scan-todo>

`todo_keywords` 从文件里的 `#+TODO:` / `#+SEQ_TODO:` / `#+TYP_TODO:` 收集任务状态词 (过滤快捷键如 `(t)` 与分隔符 `|`)，未声明时退回 `TODO` 与 `DONE`；`after_task` 在读取标题前跳过任务关键字和优先级标记。

#chunk(id: <source-syntax-lang-org-ml-scan-todo>)[
  ```ocaml
  let todo_keywords text =
    let sequence line =
      List.find_map (fun key ->
        if prefixed ~prefix:key line 0 (String.length line) then
          Some (String.sub line (String.length key) (String.length line - String.length key))
        else None) [ "#+todo:"; "#+seq_todo:"; "#+typ_todo:" ]
    in
    let words value =
      String.split_on_char ' ' value
      |> List.filter_map (fun word ->
          let word = match String.index_opt word '(' with
            | Some i -> String.sub word 0 i | None -> String.trim word in
          if word = "" || word = "|" then None else Some word)
    in
    match List.filter_map sequence (List.map String.trim (String.split_on_char '\n' text)) with
    | [] -> [ "TODO"; "DONE" ]
    | sequences -> List.concat_map words sequences

  let after_task ~keywords text start stop =
    let word_end = ref start in
    while !word_end < stop && not (is_space text.[!word_end]) do incr word_end done;
    let start =
      if List.mem (String.sub text start (!word_end - start)) keywords then
        skip_blank text !word_end stop
      else start
    in
    if start + 4 <= stop && String.sub text start 2 = "[#" && text.[start + 3] = ']' then
      skip_blank text (start + 4) stop
    else start
  ```
]

=== 区域、标题与抽屉 <syntax:lang_org.ml:scan-region>

`region` 逐行分派标题、注释行、块、关键字行和普通正文链接。带 `COMMENT` 的标题连同整棵子树跳过；标题行后允许一行计划时间戳 (`SCHEDULED:` / `DEADLINE:` / `CLOSED:`)，再解析紧随的 `:PROPERTIES:` 抽屉。

#chunk(id: <source-syntax-lang-org-ml-scan-region>)[
  ```ocaml
  let rec region ~file ~headings ~keywords text start stop =
    let heads = ref [] and nodes = ref [] in
    let add n = nodes := n :: !nodes in
    let rec go pos =
      if pos >= stop then ()
      else
        let e = min stop (line_end text pos) in
        let s = skip_blank text pos e in
        let stars = let i = ref pos in while !i < e && text.[!i] = '*' do incr i done; !i - pos in
        if headings && stars > 0 && pos + stars < e && text.[pos + stars] = ' ' then
          go (if commented pos e stars then subtree_end pos stars else heading pos e stars)
        else if s < e && text.[s] = '#' && (s + 1 = e || text.[s + 1] = ' ') then
          go (next_line text pos)
        else if prefixed ~prefix:"#+begin_" text s e then begin
          let n0 = s + 8 in
          let n1 = keyword_name text n0 e in
          match block_end text (String.sub text n0 (n1 - n0)) (next_line text pos) stop with
          | None -> List.iter add (links file text s e); go (next_line text pos)
          | Some (close, close_end) ->
              let name = at file text n0 n1 in
              let pa, pb = trim text n1 e in
              let inner_start = min close (next_line text pos) in
              let inner =
                if List.mem (String.lowercase_ascii name.value) verbatim then []
                else snd (region ~file ~headings:false ~keywords text inner_start close)
              in
              add (Provenance.located ~span:(span file pos close_end)
                     (Block { name; parameters = at file text pa (max pa pb);
                              contents = Provenance.located ~span:(span file inner_start close)
                                  { Text.text = String.sub text inner_start (close - inner_start);
                                    language };
                              inner }));
              go (next_line text close)
        end
        else if prefixed ~prefix:"#+" text s e then begin
          let n0 = s + 2 in
          let n1 = keyword_name text n0 e in
          if n1 < e && text.[n1] = ':' && n1 > n0 then begin
            let va, vb = trim text (n1 + 1) e in
            let value = at file text va (max va vb) in
            add (Provenance.located ~span:(span file pos e)
                   (Keyword { name = at file text n0 n1; value; inner = links file text va vb }))
          end;
          go (next_line text pos)
        end
        else (List.iter add (links file text s e); go (next_line text pos))
    and commented pos e stars =
      let t0 = after_task ~keywords text (skip_blank text (pos + stars) e) e in
      prefixed ~prefix:"comment" text t0 e && (t0 + 7 = e || is_space text.[t0 + 7])
    and subtree_end pos stars =
      let rec next p =
        if p >= stop then stop
        else
          let e = line_end text p in
          let n = let i = ref p in while !i < e && text.[!i] = '*' do incr i done; !i - p in
          if n > 0 && n <= stars && p + n < e && text.[p + n] = ' ' then p else next (next_line text p)
      in
      next (next_line text pos)
    and heading pos e stars =
      let t0 = after_task ~keywords text (skip_blank text (pos + stars) e) e in
      let t1 =
        (* Trailing tags such as :a:b: are not part of the title. *)
        let _, b = trim text t0 e in
        let i = ref (b - 1) in
        if b > t0 && text.[b - 1] = ':' then begin
          while !i > t0 && not (is_space text.[!i]) do decr i done;
          if !i > t0 && text.[b - 1] = ':' && text.[!i + 1] = ':' then snd (trim text t0 !i) else b
        end else b
      in
      List.iter add (links file text t0 t1);
      let after = next_line text pos in
      let after =
        let s = skip_blank text after stop in
        if List.exists (fun p -> prefixed ~prefix:p text s stop) [ "scheduled:"; "deadline:"; "closed:" ]
        then next_line text after else after
      in
      let properties, metadata_span, body_start =
        let s = skip_blank text after stop in
        if after < stop && prefixed ~prefix:":properties:" text s stop then
          let rec props pos acc =
            if pos >= stop then None
            else
              let e = line_end text pos in
              let s = skip_blank text pos e in
              if prefixed ~prefix:":end:" text s e then Some (List.rev acc, e, next_line text pos)
              else if s < e && text.[s] = ':' then
                match String.index_from_opt text (s + 1) ':' with
                | Some k when k < e && k > s + 1 ->
                    let va, vb = trim text (k + 1) e in
                    props (next_line text pos) ((at file text (s + 1) k, at file text va (max va vb)) :: acc)
                | _ -> props (next_line text pos) acc
              else props (next_line text pos) acc
          in
          match props (next_line text after) [] with
          | Some (properties, drawer_end, body) -> properties, Some (span file s drawer_end), body
          | None -> [], None, after
        else [], None, after
      in
      let title = at file text t0 (max t0 t1) in
      heads :=
        { Card.level = stars;
          identity = Provenance.located ~span:(span file pos e) { level = stars; title; properties };
          title = Option.get title.span;
          metadata =
            Ok (List.map (fun ((k : string Provenance.located), v) ->
              { Payload_rules.name = { k with value = String.lowercase_ascii k.value }; value = v })
              properties);
          metadata_span; start = pos; body_start }
        :: !heads;
      body_start
    in
    go start;
    List.rev !heads, List.rev !nodes
  ```
]

#chunk(id: <source-syntax-lang-org-ml-scan-entry>)[
  ```ocaml
  let read ~keywords ~file text ~start =
    let headings, nodes =
      region ~file ~headings:true ~keywords text start (String.length text)
    in
    { Card.headings; nodes; closes = [] }

  let scan ~file text = read ~keywords:(todo_keywords text) ~file text ~start:0

  let children = function
    | Keyword { inner; _ } | Block { inner; _ } -> inner
    | Link _ | Card _ -> []
  ```
]

#chunk(id: <source-syntax-lang-org-ml-scan>)[
  ```ocaml
  <<source-syntax-lang-org-ml-scan-links-blocks>>
  <<source-syntax-lang-org-ml-scan-todo>>
  <<source-syntax-lang-org-ml-scan-region>>
  <<source-syntax-lang-org-ml-scan-entry>>
  ```
]

== 具名调用与适配器 <syntax:lang_org.ml:actions>

- `action_name` 与 `occurrence`: Org 关键字大小写无关，剥离 `zk_` 前缀后统一转小写并平移跨度。
  #chunk(id: <source-syntax-lang-org-ml-action-helpers>)[
    ```ocaml
    let action_name (name : string Provenance.located) =
      if String.length name.value > 3 && String.lowercase_ascii (String.sub name.value 0 3) = "zk_"
      then
        Some { Provenance.value = String.lowercase_ascii (String.sub name.value 3 (String.length name.value - 3));
               span = Option.map (fun (s : Provenance.span) -> { s with start = s.start + 3 }) name.span }
      else None

    let occurrence (node : node Provenance.located) result =
      match result with
      | Ok call ->
          Rules.Matched
            { Action_rules.call = Provenance.located ?span:node.span call; taken = node.span }
      | Error errors -> Rules.Invalid errors
    ```
  ]
- `actions`: 注册 `"named-keyword"` 与 `"named-block"`，用 `arguments` 切分参数后交给 `context.named`。
  #chunk(id: <source-syntax-lang-org-ml-actions>)[
    ```ocaml
    let actions =
      Action_rules.empty
      |> Action_rules.register ~sugar:"named-keyword" (fun node (context : context) ->
           match node.value with
           | Keyword { name; value; _ } ->
               (match action_name name with
                | None -> Rules.No_match
                | Some name ->
                    occurrence node (Result.bind (arguments value) (context.named ~name)))
           | _ -> Rules.No_match)
      |> Action_rules.register ~sugar:"named-block" (fun node (context : context) ->
           match node.value with
           | Block { name; parameters; contents; _ } ->
               (match action_name name with
                | None -> Rules.No_match
                | Some name ->
                    let body = if String.trim contents.value.text = "" then None else Some contents in
                    occurrence node (Result.bind (arguments parameters) (context.named ~name ?body)))
           | _ -> Rules.No_match)
    ```
  ]
- `adapter`: 按文件路径缓存整文件扫描得到的 `todo_keywords`，因为后续单独重读卡片正文切片时不再包含文件头部的 `#+TODO:` 声明。
  #chunk(id: <source-syntax-lang-org-ml-adapter>)[
    ```ocaml
    let adapter ?(values = values) ?(identities = identities) ?(actions = actions)
        ?(define = "define") ?(unknown_properties = `Ignore) frontend =
      let files = Hashtbl.create 16 in
      let scan_document ~file text =
        let keywords = todo_keywords text in
        Hashtbl.replace files file keywords;
        read ~keywords ~file text ~start:0
      in
      let read ~file text ~start =
        let keywords =
          match Hashtbl.find_opt files file with Some k -> k | None -> todo_keywords text
        in
        read ~keywords ~file text ~start
      in
      Card.adapter ~unknown_metadata:unknown_properties
        { Card.language; source = Fun.id; scan = scan_document; read;
          nested = (fun n -> Card n); children }
        ~values ~identities ~actions ~define frontend
    ```
  ]

== 语法糖实现 <syntax:lang_org.ml:sugar>

- `id_link`: 剥离 `id:` 前缀并收缩位置跨度到目标 ID。
  #chunk(id: <source-syntax-lang-org-ml-sugar-id-link>)[
    ```ocaml
    let id_target (path : string Provenance.located) =
      if String.length path.value > 3 && String.sub path.value 0 3 = "id:" then
        Some { Provenance.value = String.sub path.value 3 (String.length path.value - 3);
               span = Option.map (fun (s : Provenance.span) -> { s with start = s.start + 3 }) path.span }
      else None

    let id_link action make =
      Action_rules.bind ~sugar:"id-link" action (fun node _ ->
        match node.Provenance.value with
        | Link { path; _ } ->
            (match id_target path with Some t -> Rules.Matched (make t) | None -> Rules.No_match)
        | _ -> Rules.No_match)
    ```
  ]
- `include_keyword`: 匹配 `#+zk_include: :target <id>`，要求仅含 `:target` 参数。
  #chunk(id: <source-syntax-lang-org-ml-sugar-include-keyword>)[
    ```ocaml
    let include_keyword action make =
      Action_rules.bind ~sugar:"zk-include" action (fun node (context : context) ->
        match node.Provenance.value with
        | Keyword { name; value; _ } when String.lowercase_ascii name.value = "zk_include" ->
            (match arguments value with
             | Error errors -> Rules.Invalid errors
             | Ok [ { name = { value = "target"; _ }; value } ] ->
                 (match Payload_rules.read context.values Syntax.Args.string value with
                  | Rules.Matched target -> Rules.Matched (make target)
                  | Rules.Invalid errors -> Rules.Invalid errors
                  | Rules.No_match -> Rules.Invalid [ Card.invalid ?span:value.span "expected a note ID" ])
             | _ -> Rules.Invalid [ Card.invalid ?span:value.span "expected only :target" ])
        | _ -> Rules.No_match)
    ```
  ]
- `nested_card`: 直接委托给 `Card.nested_card`，从 `Card` 节点提取嵌套卡片。
  #chunk(id: <source-syntax-lang-org-ml-sugar-nested-card>)[
    ```ocaml
    let nested_card action make =
      Card.nested_card (function Card n -> Some n | _ -> None) action make
    ```
  ]

组装为 `Sugar` 模块：

#chunk(id: <source-syntax-lang-org-ml-sugar>)[
  ```ocaml
  module Sugar = struct
    <<source-syntax-lang-org-ml-sugar-id-link>>
    <<source-syntax-lang-org-ml-sugar-include-keyword>>
    <<source-syntax-lang-org-ml-sugar-nested-card>>
  end
  ```
]

按顺序组合为 `syntax/lang_org.ml`：

#chunk(id: <file-syntax-lang-org-ml>, target: "syntax/lang_org.ml")[
  ```ocaml
  <<source-syntax-lang-org-ml-types>>
  <<source-syntax-lang-org-ml-text-helpers>>
  <<source-syntax-lang-org-ml-value-helpers>>
  <<source-syntax-lang-org-ml-values>>
  <<source-syntax-lang-org-ml-arguments>>
  <<source-syntax-lang-org-ml-identities>>
  <<source-syntax-lang-org-ml-scan>>
  <<source-syntax-lang-org-ml-action-helpers>>
  <<source-syntax-lang-org-ml-actions>>
  <<source-syntax-lang-org-ml-adapter>>
  <<source-syntax-lang-org-ml-sugar>>
  ```
]
