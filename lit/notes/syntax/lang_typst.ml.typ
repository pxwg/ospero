#import "/reader/book.typ": card-source, chunk
#show: card-source

= Typst 默认嵌入 DSL 的具体实现 <syntax:lang_typst.ml>

本节给出 @syntax:lang_typst.mli[] 的具体实现。

== 基础定义 <syntax:lang_typst.ml:types>

声明语言标识 `"typst"`、与接口对应的节点类型，以及直接复用的 `Value.rules`。

#chunk(id: <source-syntax-lang-typst-ml-types>)[
  ```ocaml
  open Ospero_kernel
  module Identity_rules = Rules.Identity_rules
  module Action_rules = Rules.Action_rules

  let language = Result.get_ok (Text.Language.of_string "typst")

  type value = Value.t

  type heading = {
    level : int;
    title : string Provenance.located;
    label : string Provenance.located option;
    metadata : Value.field list Frontend.read option;
  }

  type node =
    | Call of {
        name : string Provenance.located;
        arguments : argument list;
        trailing : Text.t Provenance.located list;
        inner : node Provenance.located list;
      }
    | Reference of {
        target : string Provenance.located;
        supplement : Text.t Provenance.located option;
      }
    | Card of Card.nested
    | Label of string
    | Statement of {
        keyword : string;
        path : string Provenance.located option;
      }

  and argument = {
    name : string Provenance.located option;
    value : value Provenance.located;
  }

  type context = value Card.context

  let values = Value.rules
  ```
]

== 身份识别规则 <syntax:lang_typst.ml:identities>

`identities` 注册默认规则 `"heading-label"`，按三种情况处理标题：

- 没有 `///` 元数据块：返回 `No_match`，该标题不声明卡片。
- 有 `///` 块但缺少 `<label>`：返回 `Invalid`，并附带 `Missing_identity` 诊断 (提示在标题末尾插入 ` <...>`)。
- 二者俱全：用 `Graph.Vertex_id.of_string` 校验 label 合法性。

#chunk(id: <source-syntax-lang-typst-ml-identities>)[
  ```ocaml
  let identities =
    Identity_rules.empty
    |> Identity_rules.register ~name:"heading-label" (fun (h : heading Provenance.located) ->
         match h.value.metadata, h.value.label with
         | None, _ -> Rules.No_match
         | Some _, None ->
             let insertion = Option.map (fun (s : Provenance.span) -> { s with start = s.stop })
               h.value.title.span in
             Rules.Invalid [ Frontend.Diagnostic.make ?span:h.span
               (Missing_identity { insertion; prefix = " <"; suffix = ">" }) ]
         | Some _, Some label ->
             match Graph.Vertex_id.of_string label.value with
             | Ok id -> Rules.Matched { label with value = id }
             | Error message -> Rules.Invalid [ Card.invalid ?span:label.span message ])
  ```
]

== 词法与大纲扫描 <syntax:lang_typst.ml:scan>

扫描器以字节偏移追踪源码位置，区分标记模式、代码模式、原始文本、数学公式与注释，只从真实标记中提取标题、`/// end` 关闭点与正文节点。

=== 扫描状态与基础跳读 <syntax:lang_typst.ml:scan-lex>

扫描过程中用 `st` 保存原始文本，并把一路上发现的标题 (`heads`) 与 `/// end` 关闭位置 (`closes`) 收集起来；所有位置都直接用原文件的字节偏移表示，方便诊断定位。

#chunk(id: <source-syntax-lang-typst-ml-scan-state>)[
  ```ocaml
  type st = {
    file : string;
    text : string;
    len : int;
    mutable heads : (heading, value) Card.heading list;
    mutable closes : int list;
  }

  let span st start stop = { Provenance.file = st.file; start; stop }
  let at st start stop =
    Provenance.located ~span:(span st start stop) (String.sub st.text start (stop - start))
  let char st i = if i < st.len then st.text.[i] else '\000'
  let looking st i s =
    let n = String.length s in
    i + n <= st.len && String.sub st.text i n = s

  let is_alnum = function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' -> true | _ -> false
  let is_ident_start c = is_alnum c && not (c >= '0' && c <= '9') || c = '_'
  let is_ident c = is_alnum c || c = '_' || c = '-'
  let is_label c = is_alnum c || c = '_' || c = '-' || c = ':' || c = '.'
  let is_blank c = c = ' ' || c = '\t' || c = '\r'

  let span_while st i p = let j = ref i in while !j < st.len && p st.text.[!j] do incr j done; !j
  let line_end st i = match String.index_from_opt st.text i '\n' with Some e -> e | None -> st.len
  let line_begin st i = match String.rindex_from_opt st.text (i - 1) '\n' with
    | Some b when i > 0 -> b + 1 | _ -> 0
  ```
]

为了避免把注释、代码块、数学公式或字符串里的内容误当成正文标记，扫描器先准备一组基础跳读函数：

#chunk(id: <source-syntax-lang-typst-ml-scan-skip>)[
  ```ocaml
  let skip_line_comment st i = line_end st i

  let rec skip_block_comment st i depth =
    if i >= st.len then st.len
    else if looking st i "/*" then skip_block_comment st (i + 2) (depth + 1)
    else if looking st i "*/" then (if depth = 1 then i + 2 else skip_block_comment st (i + 2) (depth - 1))
    else skip_block_comment st (i + 1) depth

  let skip_raw st i =
    let n = span_while st i (fun c -> c = '`') - i in
    if n = 2 then i + 2
    else
      let fence = String.make n '`' in
      let rec find j = if j >= st.len then None else if looking st j fence then Some j else find (j + 1) in
      match find (i + n) with Some j -> j + n | None -> i + n

  let rec skip_math st i =
    if i >= st.len then st.len
    else match st.text.[i] with
      | '\\' -> skip_math st (i + 2)
      | '$' -> i + 1
      | _ -> skip_math st (i + 1)

  let string_literal st i =
    let b = Buffer.create 16 in
    let rec go j =
      if j >= st.len then None
      else match st.text.[j] with
        | '"' -> Some (j + 1, Buffer.contents b)
        | '\\' when j + 1 < st.len ->
            (match st.text.[j + 1] with
             | 'n' -> Buffer.add_char b '\n'; go (j + 2)
             | 't' -> Buffer.add_char b '\t'; go (j + 2)
             | 'r' -> Buffer.add_char b '\r'; go (j + 2)
             | 'u' when char st (j + 2) = '{' ->
                 (match String.index_from_opt st.text (j + 3) '}' with
                  | Some k ->
                      (match int_of_string_opt ("0x" ^ String.sub st.text (j + 3) (k - j - 3)) with
                       | Some code when Uchar.is_valid code ->
                           Buffer.add_utf_8_uchar b (Uchar.of_int code); go (k + 1)
                       | _ -> go (k + 1))
                  | None -> None)
             | c -> Buffer.add_char b c; go (j + 2))
        | c -> Buffer.add_char b c; go (j + 1)
    in
    go (i + 1)

  let skip_string st i = match string_literal st i with Some (j, _) -> j | None -> st.len

  let content_text st start stop =
    Provenance.located ~span:(span st start stop)
      { Text.text = String.sub st.text start (stop - start); language }
  ```
]

=== 标题边界 <syntax:lang_typst.ml:scan-heading>

`heading_marker` 统计行首连续 `=` 的个数 (后接空格或换行才算标题)。`heading_end` 决定标题在哪一行结束：普通标题到行尾即止；如果标题行上打开了函数调用 (例如 `= #text(\n  "Title",\n) <id>`)，则继续追踪括号深度直到闭合后再在行尾结束。空白后的括号按普通正文处理，不计入调用；未闭合的调用退回单行标题。

#chunk(id: <source-syntax-lang-typst-ml-scan-heading>)[
  ```ocaml
  let heading_marker st i =
    let j = span_while st i (fun c -> c = '=') in
    if j > i && (j >= st.len || st.text.[j] = ' ' || st.text.[j] = '\n') then Some (j - i) else None

  let heading_end st i =
    let line = line_end st i in
    let rec go i depth =
      if i >= st.len then line
      else
        match st.text.[i] with
        | '\n' when depth = 0 -> i
        | '\\' -> go (i + 2) depth
        | '"' when depth > 0 -> go (skip_string st i) depth
        | ('(' | '[' | '{') when depth > 0 || (i > 0 && (is_ident st.text.[i - 1]
                                               || st.text.[i - 1] = ')' || st.text.[i - 1] = ']')) ->
            go (i + 1) (depth + 1)
        | (')' | ']' | '}') when depth > 0 -> go (i + 1) (depth - 1)
        | _ -> go (i + 1) depth
    in
    go i 0
  ```
]

=== 代码跳读与正文扫描 <syntax:lang_typst.ml:scan-markup>

代码模式与正文模式相互递归：`skip_code` 在代码模式里一路跳到顶层满足 `stop` 的字符或未匹配的闭合括号，但只要遇到内容块 `[...]`，就切回 `markup` 把里面的正文节点收集出来 (因为表达式会在原位渲染这些内容块)。

#chunk(id: <source-syntax-lang-typst-ml-scan-skip-code>)[
  ```ocaml
  let rec skip_code st i ~stop =
    let rec go i closers found =
      if i >= st.len then st.len, found
      else
        let c = st.text.[i] in
        if closers = [] && stop c then i, found
        else match c with
          | '"' -> go (skip_string st i) closers found
          | '/' when char st (i + 1) = '/' -> go (skip_line_comment st i) closers found
          | '/' when char st (i + 1) = '*' -> go (skip_block_comment st i 0) closers found
          | '(' -> go (i + 1) (')' :: closers) found
          | '{' -> go (i + 1) ('}' :: closers) found
          | '[' -> let q, nodes = markup st ~top:false (i + 1) in go (q + 1) closers (found @ nodes)
          | ')' | '}' | ']' ->
              (match closers with
               | c' :: rest when c' = c -> go (i + 1) rest found
               | _ -> i, found)
          | _ -> go (i + 1) closers found
    in
    go i [] []

  ```
]

`markup` 从位置 `i` 开始扫描正文。非顶层 (`top = false`) 遇到未匹配的 `]` 即停止并返回其位置；顶层还会识别 `/// end`、`///` 元数据块与标题。几个细节值得留意：

- 裸 URL (`http://`、`https://`) 先于 `//` 注释匹配，避免把协议里的双斜杠误当成行注释。
- 连续的 `///` 行只有在紧跟标题时才按 TOML 解析；解析前把每行开头的 `///` 原位替换成三个空格并在前面补齐偏移，使 TOML 报错位置与原文件字节偏移完全一致。
- `heading` 会把标题末尾的 `<label>` 从标题文本里剥离出来，并将标题连同元数据区间记入 `st.heads`。

#chunk(id: <source-syntax-lang-typst-ml-scan-markup>)[
  ```ocaml
  and markup st ~top i =
    let nodes = ref [] in
    let add n = nodes := n :: !nodes in
    let rec go i depth line_start =
      if i >= st.len then st.len
      else
        let c = st.text.[i] in
        if line_start && is_blank c then go (i + 1) depth true
        else if top && line_start && looking st i "///" && closing i then begin
          st.closes <- line_begin st i :: st.closes;
          go (line_end st i) depth false
        end
        else if top && line_start && looking st i "///" then go (metadata_block i) depth false
        else if top && line_start && heading_marker st i <> None then go (heading i None) depth false
        else match c with
          | '\n' -> go (i + 1) depth true
          | '\\' -> go (i + 2) depth false
          | 'h' when (looking st i "https://" || looking st i "http://")
                     && (i = 0 || not (is_alnum st.text.[i - 1])) ->
              (* A bare URL runs to the next blank; its slashes are not a comment. *)
              go (span_while st i (fun c -> not (is_blank c || c = '\n' || c = ']'))) depth false
          | '/' when char st (i + 1) = '/' && (i = 0 || st.text.[i - 1] <> ':') ->
              go (skip_line_comment st i) depth false
          | '/' when char st (i + 1) = '*' -> go (skip_block_comment st i 0) depth false
          | '`' -> go (skip_raw st i) depth false
          | '$' -> go (skip_math st (i + 1)) depth false
          | '#' -> let j, found = code st ~top i in List.iter add found; go j depth false
          | '<' when is_label (char st (i + 1)) ->
              let e = span_while st (i + 1) is_label in
              if char st e = '>' then begin
                add (Provenance.located ~span:(span st i (e + 1)) (Label (String.sub st.text (i + 1) (e - i - 1))));
                go (e + 1) depth false
              end
              else go (i + 1) depth false
          | '@' when (i = 0 || not (is_alnum st.text.[i - 1])) && is_label (char st (i + 1)) ->
              go (reference i) depth false
          | '[' when not top -> go (i + 1) (depth + 1) false
          | ']' when not top -> if depth = 0 then i else go (i + 1) (depth - 1) false
          | _ -> go (i + 1) depth false
    and reference i =
      let j = span_while st (i + 1) is_label in
      let j = let j = ref j in while !j > i + 1 && (st.text.[!j - 1] = '.' || st.text.[!j - 1] = ':') do decr j done; !j in
      (* Empty brackets delimit the target without overriding its default label. *)
      let supplement, stop =
        if char st j = '[' then
          let q, _ = markup st ~top:false (j + 1) in
          let supplement = if q = j + 1 then None else Some (content_text st (j + 1) q) in
          supplement, min st.len (q + 1)
        else None, j
      in
      add (Provenance.located ~span:(span st i stop)
             (Reference { target = at st (i + 1) j; supplement }));
      stop
    (* [/// end], optionally [/// end <id>], closes the innermost card. *)
    and closing i =
      let s = span_while st (i + 3) is_blank in
      looking st s "end"
      && (let e = s + 3 in e >= st.len || is_blank st.text.[e] || st.text.[e] = '\n')
    (* Consecutive /// lines; metadata only when a heading follows directly. *)
    and metadata_block i =
      let block_start = line_begin st i in
      let rec lines j =
        let s = span_while st j is_blank in
        if looking st s "///" then lines (min st.len (line_end st s + 1)) else j, s
      in
      let block_stop, next = lines block_start in
      match heading_marker st next with
      | Some _ ->
          let blanked = Bytes.of_string (String.sub st.text block_start (block_stop - block_start)) in
          let rec blank j =
            if j < Bytes.length blanked then begin
              let s = ref j in
              while !s < Bytes.length blanked && is_blank (Bytes.get blanked !s) do incr s done;
              Bytes.blit_string "   " 0 blanked !s 3;
              match Bytes.index_from_opt blanked !s '\n' with Some e -> blank (e + 1) | None -> ()
            end
          in
          blank 0;
          let padded = String.make block_start ' ' ^ Bytes.to_string blanked in
          let fields = Toml.parse ~file:st.file padded ~start:block_start ~stop:block_stop in
          let stop = if block_stop > block_start && st.text.[block_stop - 1] = '\n' then block_stop - 1 else block_stop in
          heading next (Some (block_start, stop, fields))
      | None -> block_stop
    and heading i metadata =
      let level = Option.get (heading_marker st i) in
      let e = heading_end st (i + level) in
      let t0 = span_while st (i + level) is_blank in
      let t1 = ref e in
      while !t1 > t0 && is_blank st.text.[!t1 - 1] do decr t1 done;
      let label, t1 =
        if !t1 > t0 && st.text.[!t1 - 1] = '>' then
          let l1 = !t1 - 1 in
          let l0 = ref l1 in
          while !l0 > t0 && is_label st.text.[!l0 - 1] do decr l0 done;
          if !l0 > t0 && st.text.[!l0 - 1] = '<' && !l0 < l1 then begin
            let stop = ref (!l0 - 1) in
            while !stop > t0 && is_blank st.text.[!stop - 1] do decr stop done;
            Some (at st !l0 l1), !stop
          end else None, !t1
        else None, !t1
      in
      let title = at st t0 t1 in
      let start, metadata_span, fields =
        match metadata with
        | Some (s, stop, fields) -> s, Some (span st s stop), Some fields
        | None -> line_begin st i, None, None
      in
      st.heads <-
        { Card.level;
          identity = Provenance.located ~span:(span st i e) { level; title; label; metadata = fields };
          title = span st t0 t1;
          metadata = Option.fold fields ~none:(Ok []) ~some:(Result.map Value.fields);
          metadata_span; start; body_start = min st.len (e + 1) }
        :: st.heads;
      i + level
    in
    let stop = go i 0 true in
    stop, List.rev !nodes

  ```
]

=== 嵌入代码与参数列表 <syntax:lang_typst.ml:scan-code>

正文里遇到 `#` 就进入 `code`。如果紧跟的是 `let`、`set`、`show`、`import` 等语句关键字，则跳过整条语句体不读取内部内容，仅在文档顶层记为 `Statement` (对 `import` 额外提取字面路径)；否则读取由 `.` 连接的调用路径，并连续收集后面的 `(...)` 参数列表与 `[...]` 尾随内容块，构成 `Call`。

#chunk(id: <source-syntax-lang-typst-ml-scan-code>)[
  ```ocaml
  and code st ~top i =
    let j = i + 1 in
    let c = char st j in
    if is_ident_start c then begin
      let rec path k =
        let e = span_while st k is_ident in
        if char st e = '.' && is_ident_start (char st (e + 1)) then path (e + 1) else e
      in
      let e = path j in
      let first = String.sub st.text j (span_while st j is_ident - j) in
      if List.mem first [ "let"; "set"; "show"; "import"; "include"; "if"; "for"; "while"; "context"; "return" ]
      (* A statement defines rather than shows: its content is not read. *)
      then
        let q = fst (skip_code st e ~stop:(fun c -> c = '\n')) in
        let path =
          let s = skip_space st e in
          match first, string_literal st s with
          | "import", Some (stop, value) -> Some (Provenance.located ~span:(span st s stop) value)
          | _ -> None
        in
        q, if top then [ Provenance.located ~span:(span st i q) (Statement { keyword = first; path }) ] else []
      else
        let rec postfix p arguments trailing inner =
          match char st p with
          | '(' ->
              let q, args, nodes = arguments_list st (p + 1) in
              postfix q (arguments @ args) trailing (inner @ nodes)
          | '[' ->
              let q, nodes = markup st ~top:false (p + 1) in
              postfix (min st.len (q + 1)) arguments (trailing @ [ content_text st (p + 1) q ]) (inner @ nodes)
          | _ -> p, arguments, trailing, inner
        in
        let p, arguments, trailing, inner = postfix e [] [] [] in
        if p = e then e, []
        else [ Provenance.located ~span:(span st i p) (Call { name = at st j e; arguments; trailing; inner }) ]
             |> fun nodes -> p, nodes
    end
    else match c with
      | '[' -> let q, nodes = markup st ~top:false (j + 1) in min st.len (q + 1), nodes
      | '(' | '{' -> let q, nodes = skip_code st j ~stop:(fun _ -> false) in min st.len (q + 1), nodes
      | _ -> j, []

  ```
]

`arguments_list` 读取括号内的逗号分隔参数列表，支持标识符键 (`key: val`) 与字符串键 (`"key": val`)；`skip_space` 跳过空白及代码注释。

#chunk(id: <source-syntax-lang-typst-ml-scan-args>)[
  ```ocaml
  and arguments_list st i =
    let rec items i acc nodes =
      let i = skip_space st i in
      if i >= st.len then st.len, List.rev acc, nodes
      else if st.text.[i] = ')' then i + 1, List.rev acc, nodes
      else
        let name, i =
          let e = span_while st i is_ident in
          let colon = skip_space st e in
          if is_ident_start (char st i) && char st colon = ':' then Some (at st i e), skip_space st (colon + 1)
          else if char st i = '"' then
            match string_literal st i with
            | Some (e, key) when char st (skip_space st e) = ':' ->
                Some (Provenance.located ~span:(span st i e) key), skip_space st (skip_space st e + 1)
            | _ -> None, i
          else None, i
        in
        let i, value, found = expr st i in
        let i = skip_space st i in
        let acc = { name; value } :: acc in
        match char st i with
        | ',' -> items (i + 1) acc (nodes @ found)
        | ')' -> i + 1, List.rev acc, nodes @ found
        | _ ->
            let q, skipped = skip_code st i ~stop:(fun c -> c = ',' || c = ')') in
            items (if char st q = ',' then q + 1 else q) acc (nodes @ found @ skipped)
    in
    items i [] []

  and skip_space st i =
    let i = span_while st i (fun c -> is_blank c || c = '\n') in
    if looking st i "//" then skip_space st (skip_line_comment st i)
    else if looking st i "/*" then skip_space st (skip_block_comment st i 0)
    else i

  ```
]

=== 静态字面量与扫描入口 <syntax:lang_typst.ml:scan-expr>

`expr` 尝试按静态字面量读取单个参数：双引号字符串、`<label>`、`[...]` 内容块、`(...)` 数组或字典 (空字典写作 `(:)`，单元素加尾逗号写作 `(x,)`)、整数和布尔值。凡是后面还有运算符或无法静态归约的表达式，一律跳到下一个 `,` 或 `)` 并原样记作 `Value.Other`。

#chunk(id: <source-syntax-lang-typst-ml-scan-expr>)[
  ```ocaml
  and expr st i =
    let located start stop v = Provenance.located ~span:(span st start stop) v in
    let atom, nodes =
      match char st i with
      | '"' ->
          (match string_literal st i with
           | Some (e, s) -> Some (e, Value.String s), []
           | None -> None, [])
      | '<' ->
          let e = span_while st (i + 1) is_label in
          if e > i + 1 && char st e = '>' then Some (e + 1, Value.Label (String.sub st.text (i + 1) (e - i - 1))), []
          else None, []
      | '[' ->
          let q, nodes = markup st ~top:false (i + 1) in
          Some (min st.len (q + 1), Value.Contents (content_text st (i + 1) q).value), nodes
      | '(' ->
          let e, items, nodes = arguments_list st (i + 1) in
          let named = List.filter (fun a -> a.name <> None) items in
          let raw = String.sub st.text i (e - i) in
          let trailing_comma = let k = ref (e - 2) in while !k > i && (is_blank st.text.[!k] || st.text.[!k] = '\n') do decr k done; st.text.[!k] = ',' in
          let value =
            if String.trim (String.sub raw 1 (String.length raw - 2)) = ":" then Value.Table []
            else if items <> [] && List.length named = List.length items then
              Value.Table (List.map (fun a -> Option.get a.name, a.value) items)
            else if named <> [] then Value.Other raw
            else match items with
              | [ single ] when not trailing_comma -> single.value.value
              | _ -> Value.Array (List.map (fun a -> a.value) items)
          in
          Some (e, value), nodes
      | c when (c >= '0' && c <= '9') || (c = '-' && let d = char st (i + 1) in d >= '0' && d <= '9') ->
          let e = span_while st (i + 1) (fun c -> is_alnum c || c = '.' || c = '_' || c = '%') in
          let raw = String.sub st.text i (e - i) in
          Some (e, match int_of_string_opt raw with Some n when not (String.contains raw '.') -> Value.Int n | _ -> Value.Other raw), []
      | c when is_ident_start c ->
          let e = span_while st i is_ident in
          (match String.sub st.text i (e - i) with
           | "true" -> Some (e, Value.Bool true), []
           | "false" -> Some (e, Value.Bool false), []
           | _ -> None, [])
      | _ -> None, []
    in
    let stops c = c = ',' || c = ')' in
    match atom with
    | Some (e, v) when stops (char st (skip_space st e)) || skip_space st e >= st.len -> e, located i e v, nodes
    | _ ->
        let q, skipped = skip_code st i ~stop:stops in
        let q' = let k = ref q in while !k > i && (is_blank st.text.[!k - 1] || st.text.[!k - 1] = '\n') do decr k done; !k in
        q, located i q' (Value.Other (String.sub st.text i (q' - i))), nodes @ skipped

  ```
]

最后由 `read` / `scan` 构造扫描状态并返回大纲，`children` 暴露 `Call` 内容块里的子节点：

#chunk(id: <source-syntax-lang-typst-ml-scan-entry>)[
  ```ocaml
  let read ~file text ~start =
    let st = { file; text; len = String.length text; heads = []; closes = [] } in
    let _, nodes = markup st ~top:true start in
    { Card.headings = List.rev st.heads; nodes; closes = List.rev st.closes }

  let scan ~file text = read ~file text ~start:0

  let children = function
    | Call { inner; _ } -> inner
    | Reference _ | Card _ | Label _ | Statement _ -> []
  ```
]

#chunk(id: <source-syntax-lang-typst-ml-scan>)[
  ```ocaml
  <<source-syntax-lang-typst-ml-scan-state>>
  <<source-syntax-lang-typst-ml-scan-skip>>
  <<source-syntax-lang-typst-ml-scan-heading>>
  <<source-syntax-lang-typst-ml-scan-skip-code>>
  <<source-syntax-lang-typst-ml-scan-markup>>
  <<source-syntax-lang-typst-ml-scan-code>>
  <<source-syntax-lang-typst-ml-scan-args>>
  <<source-syntax-lang-typst-ml-scan-expr>>
  <<source-syntax-lang-typst-ml-scan-entry>>
  ```
]

== 具名调用与适配器 <syntax:lang_typst.ml:actions>

- `needs_evaluation`: 递归检查参数值，收集需要运行期求值的 `Other` 与 `Label` 节点。
  #chunk(id: <source-syntax-lang-typst-ml-needs-eval>)[
    ```ocaml
    let rec needs_evaluation (v : value Provenance.located) =
      match v.value with
      | Other _ | Label _ -> [ v ]
      | Array items -> List.concat_map needs_evaluation items
      | Table fields -> List.concat_map (fun (_, v) -> needs_evaluation v) fields
      | String _ | Int _ | Bool _ | Contents _ -> []
    ```
  ]
- `actions`: 注册 `"named-call"`，匹配 `zk.` 前缀调用，去掉前缀并修正位置跨度；一次性汇总位置参数、需运行期求值参数和多余尾随块的错误，通过后交给 `context.named` 解码。
  #chunk(id: <source-syntax-lang-typst-ml-actions>)[
    ```ocaml
    let actions =
      Action_rules.empty
      |> Action_rules.register ~sugar:"named-call" (fun node (context : context) ->
           match node.Provenance.value with
           | Call { name; arguments; trailing; _ }
             when String.length name.value > 3 && String.sub name.value 0 3 = "zk." ->
               let name =
                 { Provenance.value = String.sub name.value 3 (String.length name.value - 3);
                   span = Option.map (fun (s : Provenance.span) -> { s with start = s.start + 3 }) name.span }
               in
               let positional = List.filter (fun a -> a.name = None) arguments in
               let evaluated = List.concat_map (fun a -> needs_evaluation a.value) arguments in
               let problems =
                 List.map (fun a -> Card.invalid ?span:a.value.span "named calls take named arguments only") positional
                 @ List.map (fun (v : _ Provenance.located) ->
                     Card.invalid ?span:v.span "this argument needs evaluation; only literals are read") evaluated
                 @ (match trailing with
                    | _ :: extra :: _ -> [ Card.invalid ?span:extra.span "a named call takes one body" ]
                    | _ -> [])
               in
               if problems <> [] then Rules.Invalid problems
               else
                 let fields =
                   List.filter_map (fun a -> Option.map (fun n -> n, a.value) a.name) arguments
                 in
                 let body = match trailing with [ b ] -> Some b | _ -> None in
                 (match context.named ~name ?body (Value.fields fields) with
                  | Ok call ->
                      Rules.Matched
                        { Action_rules.call = Provenance.located ?span:node.span call; taken = node.span }
                  | Error errors -> Rules.Invalid errors)
           | _ -> Rules.No_match)
    ```
  ]
- `adapter`: 将语言定义、扫描函数与三张规则表接入 `Card.adapter`。
  #chunk(id: <source-syntax-lang-typst-ml-adapter>)[
    ```ocaml
    let adapter ?(values = values) ?(identities = identities) ?(actions = actions)
        ?(define = "define") frontend =
      Card.adapter
        { Card.language; source = Fun.id; scan = (fun ~file text -> scan ~file text);
          read; nested = (fun n -> Card n); children }
        ~values ~identities ~actions ~define frontend
    ```
  ]

== 语法糖实现 <syntax:lang_typst.ml:sugar>

- `references`: 绑定 `"at-reference"` 与 `"ref-call"`；后者匹配 `#ref(<label>)` 时会将位置跨度收缩到尖括号内部。
  #chunk(id: <source-syntax-lang-typst-ml-sugar-references>)[
    ```ocaml
    let references action make rules =
      rules
      |> Action_rules.bind ~sugar:"at-reference" action (fun node _ ->
           match node.Provenance.value with
           | Reference { target; _ } -> Rules.Matched (make target)
           | _ -> Rules.No_match)
      |> Action_rules.bind ~sugar:"ref-call" action (fun node _ ->
           match node.Provenance.value with
           | Call { name = { value = "ref"; _ }; arguments = [ { name = None; value = { value = Label l; span } } ]; trailing = []; _ } ->
               let span = Option.map (fun (s : Provenance.span) -> { s with start = s.start + 1; stop = s.stop - 1 }) span in
               Rules.Matched (make (Provenance.located ?span l))
           | _ -> Rules.No_match)
    ```
  ]
- `include_note`: 绑定 `"include-note"`，支持尾随内容块和首位位置内容块两种形式，要求块内恰好只有一个 `Reference` 节点。
  #chunk(id: <source-syntax-lang-typst-ml-sugar-include-note>)[
    ```ocaml
    let include_note action make =
      Action_rules.bind ~sugar:"include-note" action (fun node _ ->
        match node.Provenance.value with
        | Call { name = { value = "include-note"; _ }; trailing; arguments; inner; _ }
          when List.length trailing = 1
               || (match arguments with
                   | { name = None; value = { value = Value.Contents _; _ } } :: _ -> true
                   | _ -> false) ->
            (match inner with
             | [ { value = Reference { target; _ }; _ } ] -> Rules.Matched (make target)
             | _ -> Rules.Invalid [ Card.invalid ?span:node.span "include-note takes one @reference" ])
        | _ -> Rules.No_match)
    ```
  ]
- `nested_card`: 直接委托给 `Card.nested_card`，从 `Card` 节点提取嵌套卡片。
  #chunk(id: <source-syntax-lang-typst-ml-sugar-nested-card>)[
    ```ocaml
    let nested_card action make =
      Card.nested_card (function Card n -> Some n | _ -> None) action make
    ```
  ]

组装为 `Sugar` 模块：

#chunk(id: <source-syntax-lang-typst-ml-sugar>)[
  ```ocaml
  module Sugar = struct
    <<source-syntax-lang-typst-ml-sugar-references>>
    <<source-syntax-lang-typst-ml-sugar-include-note>>
    <<source-syntax-lang-typst-ml-sugar-nested-card>>
  end
  ```
]

按顺序组合为 `syntax/lang_typst.ml`：

#chunk(id: <file-syntax-lang-typst-ml>, target: "syntax/lang_typst.ml")[
  ```ocaml
  <<source-syntax-lang-typst-ml-types>>
  <<source-syntax-lang-typst-ml-identities>>
  <<source-syntax-lang-typst-ml-scan>>
  <<source-syntax-lang-typst-ml-needs-eval>>
  <<source-syntax-lang-typst-ml-actions>>
  <<source-syntax-lang-typst-ml-adapter>>
  <<source-syntax-lang-typst-ml-sugar>>
  ```
]
