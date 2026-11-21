#import "/reader/book.typ": chunk

= 文学编程的 Ospero 模型 <lit:engine:lit_model.ml>

这份模型是 tangle、weave 和 LSP 的共用入口。

== 声明动作的参数

参数规格定义代码块、普通链接和嵌入动作的输入。

#chunk(id: <source-lit-engine-lit-model-ml-schema>)[
```ocaml
open Ospero.Core
module Syntax = Ospero.Syntax
module Typst = Syntax.Lang.Typst
module Files = Map.Make (String)
module Args = Syntax.Args
module Value = Syntax.Lang.Value
module O = Observation
module P = Provenance

let fail format = Printf.ksprintf failwith format
let id_name = Graph.Vertex_id.to_string
let pos ?span value = P.located ?span value

let diagnostic ?span message = Frontend.Diagnostic.make ?span (Invalid message)

type code_metadata = { language : string; target : string option }
type metadata = code_metadata option
let metadata_schema = Schema.(map (fun () -> None) (record no_fields))

type block = {
  id : string P.located;
  contents : Text.t P.located;
  language : string P.located;
  target : string P.located option;
  noweb : bool P.located;
  margin : int P.located option;
}

type relation = Link | Embed | Splice

type action =
  | Define of Text.t P.located
  | Block of block
  | Code_body of block
  | Reference of relation * string P.located

let define = Syntax.Action.declare ~name:"define"
  Args.(spec (let+ body = required "contents" contents ~get:Fun.id in body))

let code_block = Syntax.Action.declare ~name:"code-block" Args.(spec (
  let+ id = required "id" string ~get:(fun b -> b.id)
  and+ contents = required "contents" contents ~get:(fun b -> b.contents)
  and+ language = required "language" string ~get:(fun b -> b.language)
  and+ target = optional "target-file" string ~get:(fun b -> b.target)
  and+ noweb = required "noweb" bool ~get:(fun b -> b.noweb)
  and+ margin = optional "margin" int ~get:(fun b -> b.margin) in
  { id; contents; language; target; noweb; margin }))

```
]

== 把 Typst 标记绑定到动作

复用 Typst 适配器和引用语法糖，再为具名代码块增加一条规则。它保留原始代码字节的源码坐标，并记录围栏所在的列。解释正文时，以围栏为第零列，以引用行的缩进为插入位置。

#chunk(id: <source-lit-engine-lit-model-ml-typst>)[
```ocaml
let reference name = Syntax.Action.declare ~name
  Args.(spec (let+ target = required "target" string ~get:Fun.id in target))

let link = reference "link"
let embed = reference "embed"

let input = Syntax.Frontend_input.create ~metadata:metadata_schema
  [ Syntax.Frontend_input.action define ~decode:(fun body -> Ok (Define body));
    Syntax.Frontend_input.action code_block ~decode:(fun block -> Ok (Block block));
    Syntax.Frontend_input.action link ~decode:(fun target -> Ok (Reference (Link, target)));
    Syntax.Frontend_input.action embed ~decode:(fun target -> Ok (Reference (Embed, target))) ]

(* Keep code in source coordinates until observation reads its lines. *)
let fenced_code (body : Text.t P.located) =
  let text = body.value.text in
  let opening = Str.regexp "[ \t\r\n]*\\(\x60\x60\x60+\\)\\([^ \t\r\n]+\\)[ \t\r]*\n" in
  let locate start stop value =
    let span = Option.map (fun (s : P.span) ->
      { s with start = s.start + start; stop = s.start + stop }) body.span in
    pos ?span value in
  let invalid () = Error (diagnostic ?span:body.span "expected one fenced code block with a language") in
  if not (Str.string_match opening text 0) then invalid () else
  let delimiter = Str.matched_group 1 text in
  let fence_start = Str.group_beginning 1 in
  let language = locate (Str.group_beginning 2) (Str.group_end 2) (Str.matched_group 2 text) in
  let code_start = Str.match_end () in
  let line_start = match String.rindex_from_opt text (fence_start - 1) '\n' with
    | None -> 0 | Some newline -> newline + 1 in
  let padding = String.sub text line_start (fence_start - line_start) in
  let closing = Str.regexp ("^\\([ \t]*\\)" ^ delimiter ^ "[ \t\r]*$") in
  match Str.search_forward closing text code_start with
  | exception Not_found -> invalid ()
  | code_stop ->
      let tail = Str.match_end () in
      let closing_padding = Str.matched_group 1 text in
      if String.trim (String.sub text tail (String.length text - tail)) <> "" then invalid ()
      else if not (String.for_all ((=) ' ') padding) then
        Error (diagnostic ?span:(locate line_start fence_start ()).span "indent the code fence with spaces")
      else if closing_padding <> padding then
        Error (diagnostic ?span:(locate code_stop tail ()).span "align the closing code fence with its opening fence")
      else
        let contents = locate code_start code_stop
          { Text.text = String.sub text code_start (code_stop - code_start); language = Typst.language } in
        Ok (language, contents, locate line_start fence_start (String.length padding))

let chunk (node : Typst.node P.located) _ =
  match node.value with
  | Typst.Call { name = { value = "chunk"; _ }; arguments; trailing = [ body ]; _ } ->
      let rec fields id target noweb = function
        | [] ->
            (match id, fenced_code body with
             | None, _ -> Syntax.Invalid [diagnostic ?span:node.span "chunk needs id: <label>"]
             | _, Error problem -> Syntax.Invalid [problem]
             | Some id, Ok (language, contents, margin) ->
                 Syntax.Matched { id; target; contents; language; margin = Some margin;
                   noweb = Option.value noweb ~default:(pos true) })
        | ({ Typst.name; value } : Typst.argument) :: rest ->
            (match name, value.value with
             | Some { value = "id"; _ }, Value.Label label when id = None ->
                 fields (Some (pos ?span:value.span label)) target noweb rest
             | Some { value = "target"; _ }, Value.String path when target = None ->
                 fields id (Some (pos ?span:value.span path)) noweb rest
             | Some { value = "noweb"; _ }, Value.Bool flag when noweb = None ->
                 fields id target (Some (pos ?span:value.span flag)) rest
             | _ -> Syntax.Invalid [diagnostic ?span:value.span "invalid or duplicate chunk argument"]) in
      fields None None None arguments
  | Typst.Call { name = { value = "chunk"; _ }; _ } ->
      Syntax.Invalid [diagnostic ?span:node.span "chunk takes one content block"]
  | _ -> Syntax.No_match

let config =
  let identities = Typst.identities
    |> Syntax.Identity_rules.register ~name:"lit-labelled-heading" (fun heading ->
         match heading.P.value with
         | { Typst.metadata = None; label = Some label; _ } ->
             (match Graph.Vertex_id.of_string label.value with
              | Ok id -> Syntax.Matched { label with value = id }
              | Error message -> Syntax.Invalid [diagnostic ?span:label.span message])
         | _ -> Syntax.No_match) in
  let actions = Typst.actions
    |> Typst.Sugar.nested_card define (fun ~contents ~depth:_ -> contents)
    |> Typst.Sugar.references link Fun.id
    |> Typst.Sugar.include_note embed Fun.id
    |> Syntax.Action_rules.bind ~sugar:"lit-chunk" code_block chunk in
  Syntax.configure [Typst.adapter ~identities ~actions input]

```
]

== 解释局部声明

代码块生成代码卡。拼接既建立引用关系，也在正文的原位置留下消费者可用的片段。

#chunk(id: <source-lit-engine-lit-model-ml-interpret>)[
```ocaml
module Decoder = Frontend.Decode (struct
  type nonrec metadata = metadata
  type nonrec action = action
  let decode_metadata = Syntax.Frontend_input.decode_metadata input
  let decode_action = Syntax.Frontend_input.decode_action input
end)

type piece =
  | Code of string P.located list
  | Include_code of { target : Graph.Vertex_id.t P.located; padding : string }

type consumption =
  | Code_piece of piece
  | Chunk_ref of Graph.Vertex_id.t
  | Nested_card of Graph.Vertex_id.t
  | Embed_card of Graph.Vertex_id.t
  | Link_ref of Graph.Vertex_id.t

(* Each line is read in file coordinates. Drop the Typst margin before
   interpreting a whole-line splice and keep the splice's own indentation. *)
let pieces block =
  let text = block.contents.value.text in
  let length = String.length text in
  let margin = Option.fold ~none:0 ~some:(fun n -> max 0 n.P.value) block.margin in
  let rec after_margin i stop =
    if i < stop && text.[i] = ' ' then after_margin (i + 1) stop else i in
  let slice start stop value =
    let span = Option.map (fun (s : P.span) ->
      { s with start = s.start + start; stop = s.start + stop }) block.contents.span in
    pos ?span value in
  let emit piece = O.Emit (O.Observed.Consume (Code_piece piece)) in
  let flush lines acc =
    if lines = [] then acc else emit (Code (List.rev lines)) :: acc in
  let rec scan from lines acc =
    if from = length then List.rev (flush lines acc) else
    let stop = Option.value (String.index_from_opt text from '\n') ~default:length in
    let next = min (stop + 1) length in
    let line = String.sub text from (stop - from) in
    let trimmed = String.trim line in
    let first = after_margin from (from + min margin (stop - from)) in
    if trimmed <> "" && first - from < margin then
      let loc = slice from stop () in
      scan next [] (O.Fail (diagnostic ?span:loc.span "code line starts to the left of its fence") :: flush lines acc)
    else if block.noweb.value && String.starts_with ~prefix:"<<" trimmed
         && String.ends_with ~suffix:">>" trimmed && String.length trimmed >= 4 then
      let marker = String.index line '<' in
      let padding = String.sub line margin (marker - margin) in
      let raw = String.sub trimmed 2 (String.length trimmed - 4) in
      let start = from + marker + 2 in
      let target = slice start (start + String.length raw) raw in
      let acc = flush lines acc in
      let acc = match Graph.Vertex_id.of_string raw with
        | Ok id when not (String.exists (function ' ' | '\t' | '<' | '>' -> true | _ -> false) raw) ->
            let target = { target with value = id } in
            emit (Include_code { target; padding }) :: O.Relate { target; relation = Splice } :: acc
        | _ -> O.Fail (diagnostic ?span:target.span "expected <<card-id>>") :: acc in
      scan next [] acc
    else
      let line = slice first next (String.sub text first (next - first)) in
      scan next (line :: lines) acc in
  scan 0 [] []

module Observe = Frontend.Make (struct
  include Decoder
  type nonrec relation = relation
  type nonrec consumption = consumption
  type error = Frontend.Diagnostic.t
  let interpret = function
    | Reference (relation, target) ->
        (match Graph.Vertex_id.of_string target.value with
         | Ok id ->
             let emit = match relation with
               | Link -> [O.Emit (O.Observed.Consume (Link_ref id))]
               | Embed -> [O.Emit (O.Observed.Consume (Embed_card id))]
               | Splice -> [] in
             O.Relate { target = { target with value = id }; relation } :: emit
         | Error message -> [O.Fail (diagnostic ?span:target.span message)])
    | Code_body block -> pieces block
    | Block block ->
        let span = block.contents.span in
        let title = { Text.text = block.id.value; language = Typst.language } in
        let metadata = Some { language = block.language.value;
                              target = Option.map (fun path -> path.P.value) block.target } in
        let body = pos ?span [pos ?span (O.Source.Action (Ok (Code_body block)))] in
        (match Graph.Vertex_id.of_string block.id.value with
         | Ok id ->
             [O.Define (pos ?span { O.Source.id = { block.id with value = id };
                                    title = pos title; metadata = pos (Ok metadata); body });
              O.Emit (O.Observed.Consume (Chunk_ref id))]
         | Error error -> [O.Fail (diagnostic ?span:block.id.span error)])
    | Define body ->
        match Syntax.parse_contents config body with
        | Ok note ->
            let decoded = Decoder.decode_source note in
            [O.Define decoded; O.Emit (O.Observed.Consume (Nested_card decoded.value.id.value))]
        | Error errors -> List.map (fun error -> O.Fail error) errors
end)

```
]

== 读取并验证代码卡

诊断保留原文位置。构建再检查拼接目标、语言、循环和输出路径。

#chunk(id: <source-lit-engine-lit-model-ml-diagnostics>)[
```ocaml
let read file = In_channel.with_open_bin file In_channel.input_all

let diagnostic_text (d : Frontend.Diagnostic.t) =
  let detail = match d.problem with
    | Invalid text -> text
    | Missing_field name -> "missing " ^ name
    | Duplicate_field name -> "duplicate " ^ name
    | Unknown_action { name; _ } -> "unknown action " ^ name
    | Invalid_choice { given; _ } -> "invalid value " ^ given
    | _ -> "could not read declaration" in
  detail

let issue_messages (item : _ P.located) =
  let located (d : Frontend.Diagnostic.t) =
    (match d.span with Some _ -> d.span | None -> item.span), diagnostic_text d in
  match item.value with
  | O.Metadata_error (_, Frontend.Metadata_decode errors)
  | O.Action_error (_, Frontend.Action_decode (Unread errors | Undecoded (_, errors))) ->
      List.map located errors
  | O.Action_error (_, Frontend.Interpretation error) -> [located error]
  | O.Duplicate_definition id -> [item.span, "duplicate card " ^ id_name id]
  | O.Reference_error { problem = Graph.Missing_endpoint (_, _, id); _ } ->
      [item.span, "unresolved reference " ^ id_name id]
  | _ -> [item.span, "invalid card contribution"]

type card = { id : Graph.Vertex_id.t; title : string; language : string; target : string option; pieces : piece list }

let code_cards obs =
  O.graph obs |> Graph.vertices |> List.filter_map (fun ({ Graph.id; note } : metadata Frontend.decoded Graph.note Graph.vertex) ->
    match note.metadata with
    | Ok (Some metadata) ->
        let pieces = Option.value (O.body obs id) ~default:[] |> List.filter_map (fun item ->
          match item.P.value with
          | O.Observed.Consume (Code_piece piece) -> Some piece
          | O.Observed.Consume _ | O.Observed.Text _ -> None) in
        Some { id; title = note.title.text; language = metadata.language; target = metadata.target; pieces }
    | Ok None | Error _ -> None)

let output_path path =
  let parts = String.split_on_char '/' path |> List.filter (fun p -> p <> "" && p <> ".") in
  if not (Filename.is_relative path) || parts = [] || List.mem ".." parts
     || String.ends_with ~suffix:"/" path then
    fail "invalid :target-file: %s (expected a relative file path inside out/)" path;
  String.concat "/" parts

exception Invalid_code of Graph.Vertex_id.t * string

let reject card format = Printf.ksprintf (fun text -> raise (Invalid_code (card.id, text))) format

let validate cards =
  let index = Hashtbl.create (List.length cards) in
  List.iter (fun card -> Hashtbl.add index card.id card) cards;
  let outputs = Hashtbl.create 8 in
  let plan = List.filter_map (fun card ->
    Option.map (fun target ->
      let path = try output_path target with Failure text -> reject card "%s" text in
      if Hashtbl.mem outputs path then
        reject card "%s and %s both declare %s" (Hashtbl.find outputs path) (id_name card.id) path;
      Hashtbl.add outputs path (id_name card.id);
      path, card) card.target) cards in
  List.iter (fun card ->
    List.iter (function
      | Code _ -> ()
      | Include_code { target; _ } ->
          match Hashtbl.find_opt index target.value with
          | None -> reject card "%s: %s is not a code card" (id_name card.id) (id_name target.value)
          | Some included when included.language <> card.language ->
              reject card "%s: incompatible language in %s" (id_name card.id) (id_name target.value)
          | Some _ -> ()) card.pieces) cards;
  let checked = Hashtbl.create (List.length cards) in
  let rec check_cycles stack card =
    if List.mem card.id stack then
      reject card "code inclusion cycle: %s" (String.concat " -> " (List.rev_map id_name (card.id :: stack)));
    if not (Hashtbl.mem checked card.id) then begin
      List.iter (function
        | Code _ -> ()
        | Include_code { target; _ } -> check_cycles (card.id :: stack) (Hashtbl.find index target.value)) card.pieces;
      Hashtbl.add checked card.id ()
    end
  in
  List.iter (check_cycles []) cards;
  List.iter (fun (path, card) ->
    let rec check_parent dir =
      if dir <> "." then begin
        if Hashtbl.mem outputs dir then reject card "conflicting output paths: %s and %s" dir path;
        check_parent (Filename.dirname dir)
      end in
    check_parent (Filename.dirname path)) plan;
  index, plan

(* Register block IDs from the same calls that will define them. The Typst
   adapter handles heading IDs, including headings nested in a define. *)
```
]

== 从项目文档取得观察结果

把代码块的 ID 与 Typst 标题的 ID 预先登记，再解释项目中的动作。

#chunk(id: <source-lit-engine-lit-model-ml-observe>)[
```ocaml
let rec code_ids (note : Syntax.raw_note P.located) =
  List.concat_map (fun item -> match item.P.value with
    | O.Source.Action (Ok (call : Frontend.Invocation.t)) ->
        let field key = List.find_map (fun (f : Frontend.Payload.field) ->
          if f.name.value = key then Some f.value else None) call.arguments in
        (match call.name.value with
         | "code-block" ->
             (match field "id" with
              | Some { value = String id; _ } -> Result.to_list (Graph.Vertex_id.of_string id)
              | _ -> [])
         | "define" ->
             (match field "contents" with
              | Some { value = Contents body; span } ->
                  (match Syntax.parse_contents config (pos ?span body) with
                   | Ok child -> code_ids child
                   | Error _ -> [])
              | _ -> [])
         | _ -> [])
    | _ -> []) note.value.body.value

let parse_source file native =
  let project, diagnostics = Syntax.parse_project config [{ Syntax.file; language = Typst.language; native }] in
  let identities = project.identities @ List.concat_map code_ids project.notes in
  { project with identities }, diagnostics

let observe_parsed files =
  let batches = List.map snd (Files.bindings files) in
  let projects, diagnostics = List.split batches in
  let notes = List.concat_map (fun project -> project.O.notes) projects in
  let identities = List.concat_map (fun project -> project.O.identities) projects in
  Observe.observe { O.notes; identities }, List.concat diagnostics

```
]

== 供构建和编辑器共享的入口

磁盘文件与未保存缓冲区使用同一种输入格式。输出文件由已验证的代码卡逐层展开。

#chunk(id: <source-lit-engine-lit-model-ml-workspace>)[
```ocaml
let guide workspace = Filename.concat workspace "index.typ"

let is_source workspace file =
  file = guide workspace ||
  (String.starts_with ~prefix:(Filename.concat workspace "notes" ^ "/") file
   && Filename.check_suffix file ".typ")

let sources ?(buffers = Files.empty) workspace =
  let rec walk files path =
    match (Unix.lstat path).st_kind with
    | Unix.S_DIR -> Sys.readdir path |> Array.fold_left (fun files name ->
        walk files (Filename.concat path name)) files
    | Unix.S_REG when is_source workspace path && not (Files.mem path files) ->
        Files.add path (read path) files
    | _ -> files
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> files in
  walk (walk buffers (Filename.concat workspace "notes")) (guide workspace)

let observe_sources files =
  Files.mapi parse_source files |> observe_parsed

let definition_spans obs id =
  O.definitions obs id |> List.filter_map (fun (d : _ O.definition) ->
    if d.rejected = [] then d.id.span else None)

let title obs id =
  Graph.find_vertex (O.graph obs) id |> Option.map (fun (v : _ Graph.note Graph.vertex) -> v.note.title.text)

let problems obs diagnostics =
  let invalid_embed (reference : _ O.reference) =
    match reference.edges, Graph.find_vertex (O.graph obs) reference.target.value with
    | [{ Graph.relation = Embed; _ }], Some { note = { metadata = Ok (Some _); _ }; _ } ->
        Some (reference.target.span, "include-note needs a prose card")
    | _ -> None in
  let issues = List.map (fun (d : Frontend.Diagnostic.t) -> d.span, diagnostic_text d) diagnostics
    @ List.concat_map issue_messages (O.issues obs)
    @ List.filter_map invalid_embed (O.references obs) in
  if issues <> [] then issues else
  try ignore (validate (code_cards obs)); [] with
  | Invalid_code (id, message) -> [List.nth_opt (definition_spans obs id) 0, message]

type segment = {
  generated_start : int;
  origin : P.span;
  splices : P.span list;  (* Nearest splice first. *)
}

type output = { text : string; segments : segment list }

let project cards =
  let index, plan = validate cards in
  let render root =
    let text = Buffer.create 256 in
    let segments = ref [] in
    let rec expand padding splices card =
      List.iter (function
        | Code lines -> List.iter (fun (line : string P.located) ->
            if padding <> "" && String.trim line.value <> "" then Buffer.add_string text padding;
            Option.iter (fun origin ->
              segments := { generated_start = Buffer.length text; origin; splices } :: !segments) line.span;
            Buffer.add_string text line.value) lines
        | Include_code { target; padding = extra } ->
            let splices = match target.span with None -> splices | Some span -> span :: splices in
            expand (padding ^ extra) splices (Hashtbl.find index target.value)) card.pieces in
    expand "" [] root;
    { text = Buffer.contents text; segments = List.rev !segments } in
  List.map (fun (path, card) -> path, render card) plan

let outputs cards = List.map (fun (path, output) -> path, output.text) (project cards)

let generated_stop segment =
  segment.generated_start + segment.origin.stop - segment.origin.start

let occurrences outputs file at =
  Files.bindings outputs |> List.concat_map (fun (target, output) ->
    output.segments |> List.filter_map (fun segment ->
      let origin = segment.origin in
      if origin.file = file && origin.start <= at && at < origin.stop then
        Some (target, segment.generated_start + at - origin.start, segment.splices)
      else None))

(* A range can span several lines of the same occurrence. Across a splice,
   only a diagnostic may be clipped to its first source line. *)
let origin_of_range ?(clip = false) output (span : P.span) =
  let start, stop = span.start, span.stop in
  let hits segment = segment.generated_start < stop && start < generated_stop segment in
  let segments = if start <> stop then List.filter hits output.segments else
    match List.find_opt (fun segment ->
      segment.generated_start <= start && start < generated_stop segment) output.segments with
    | Some segment -> [segment]
    | None -> Option.to_list (List.find_opt (fun segment -> generated_stop segment = start) output.segments) in
  match segments with
  | [] -> None
  | first :: rest ->
      let last = List.fold_left (fun _ segment -> segment) first rest in
      let same_occurrence segment =
        segment.origin.file = first.origin.file && segment.splices = first.splices in
      let start_in segment = segment.origin.start + max 0 (start - segment.generated_start) in
      let end_in segment = segment.origin.start + min (stop - segment.generated_start)
          (segment.origin.stop - segment.origin.start) in
      if List.for_all same_occurrence rest &&
         (clip || (start >= first.generated_start && stop <= generated_stop last)) then
        Some { first.origin with start = start_in first; stop = end_in last }
      else if clip then Some { first.origin with start = start_in first; stop = end_in first }
      else None

let project_sources sources =
  let obs, diagnostics = observe_sources sources in
  if problems obs diagnostics <> [] then None
  else Some (project (code_cards obs) |> List.to_seq |> Files.of_seq)

let texts = Files.map (fun output -> output.text)

let replace text edits =
  let writer = Buffer.create (String.length text) in
  let finish = List.fold_left (fun cursor ((span : P.span), replacement) ->
    if span.start < cursor then fail "Overlapping OCaml edits";
    Buffer.add_substring writer text cursor (span.start - cursor);
    Buffer.add_string writer replacement;
    span.stop) 0 edits in
  Buffer.add_substring writer text finish (String.length text - finish);
  Buffer.contents writer

let edits_by_file edits =
  List.fold_left (fun files ((span : P.span), _ as edit) ->
    Files.update span.file (fun old -> Some (edit :: Option.value old ~default:[])) files)
    Files.empty edits
  |> Files.map (List.sort_uniq compare)

let apply_edits documents edits =
  Files.fold (fun file edits documents ->
    Files.add file (replace (Files.find file documents) edits) documents) edits documents

let project_edits ~sources ~parsed ~outputs:projection generated =
  let original = List.map (fun ((span : P.span), replacement) ->
    let output = Files.find span.file projection in
    match origin_of_range output span with
    | Some origin -> origin, replacement
    | None -> fail "OCaml edit crosses a splice or generated indentation") generated
    |> edits_by_file in
  let expected = apply_edits (texts projection) (edits_by_file generated) in
  let revised = apply_edits sources original in
  let parsed = Files.fold (fun file _ parsed ->
    Files.add file (parse_source file (Files.find file revised)) parsed) original parsed in
  let obs, diagnostics = observe_parsed parsed in
  if problems obs diagnostics = [] &&
     Files.equal String.equal (List.to_seq (outputs (code_cards obs)) |> Files.of_seq) expected then original
  else fail "OCaml edits cannot be represented by a single change to the Lit source"

let rec ensure_directory path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR -> ()
  | _ -> fail "%s is not a directory" path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      ensure_directory (Filename.dirname path);
      Unix.mkdir path 0o755

let write path body =
  let dir = Filename.dirname path in
  ensure_directory dir;
  (match (Unix.lstat path).st_kind with
   | Unix.S_REG -> ()
   | _ -> fail "%s is not a regular file" path
   | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  let staged, channel = Filename.open_temp_file ~temp_dir:dir ".lit-" ".tmp" in
  Fun.protect ~finally:(fun () -> close_out_noerr channel; if Sys.file_exists staged then Sys.remove staged)
    (fun () -> output_string channel body; close_out channel;
      Unix.chmod staged 0o644; Unix.rename staged path)
```
]

== 组装模型

#chunk(id: <file-lit-engine-lit-model-ml>, target: "lit/engine/lit_model.ml")[
```ocaml
<<source-lit-engine-lit-model-ml-schema>>
<<source-lit-engine-lit-model-ml-typst>>
<<source-lit-engine-lit-model-ml-interpret>>
<<source-lit-engine-lit-model-ml-diagnostics>>
<<source-lit-engine-lit-model-ml-observe>>
<<source-lit-engine-lit-model-ml-workspace>>
```
]
