open Ospero.Core
open Lit_model

let escape text = String.to_seq text |> List.of_seq |> List.map (function
  | '&' -> "&amp;" | '<' -> "&lt;" | '>' -> "&gt;" | '"' -> "&quot;"
  | c -> String.make 1 c) |> String.concat ""

let json_string s = Yojson.Safe.to_string (`String s)

(* Ask Typst to render each original file in its own scope, with the book's
   show rule surrounding the result. The generated document uses stdin and
   can resolve each file's imports relative to that file. *)
let compile workspace registry source =
  let input = Filename.temp_file "lit-reader" ".typ" in
  let output = Filename.temp_file "lit-reader" ".html" in
  Fun.protect ~finally:(fun () -> Sys.remove input; Sys.remove output) (fun () ->
    Out_channel.with_open_bin input (fun oc -> output_string oc source);
    let input_fd = Unix.openfile input [Unix.O_RDONLY] 0 in
    let output_fd = Unix.openfile output [Unix.O_WRONLY; Unix.O_TRUNC] 0 in
    let argv = [|"typst"; "compile"; "--root"; workspace; "--features"; "html";
      "--format"; "html"; "--input"; "lit-registry=" ^ registry; "-"; "-"|] in
    let pid = Fun.protect ~finally:(fun () -> Unix.close input_fd; Unix.close output_fd)
      (fun () -> Unix.create_process "typst" argv input_fd output_fd Unix.stderr) in
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED 0 -> read output
    | _ -> fail "Typst could not render the book")

let owner obs id =
  match O.generated_from obs id with
  | Some (Some generation) -> generation.source
  | _ -> fail "chunk %s has no owning card" (id_name id)

let code_html obs card =
  let pieces = card.pieces |> List.map (function
    | Code text -> escape text
    | Include_code { id; padding } ->
        let block = escape (id_name id) and card = escape (id_name (owner obs id)) in
        let padding = escape padding in
        Printf.sprintf "<a href=\"#stack=%s&amp;block=%s\" data-card=\"%s\" data-block=\"%s\" data-padding=\"%s\">%s&lt;&lt;%s&gt;&gt;</a>\n"
          card block card block padding padding block) |> String.concat "" in
  let summary = Option.value card.target ~default:(id_name card.id) in
  let target = Option.fold ~none:"" ~some:(fun path -> " data-target=\"" ^ escape path ^ "\"") card.target in
  Printf.sprintf "<details class=\"code\" data-block=\"%s\"%s><summary>%s</summary><pre><code data-lang=\"%s\">%s</code></pre></details>"
    (escape (id_name card.id)) target (escape summary) (escape card.language) pieces

let render workspace obs chunks =
  let vertices = Graph.vertices (O.graph obs) in
  let registry = vertices |> List.map (fun (v : _ Graph.note Graph.vertex) ->
    let id = id_name v.id in
    let card, block = match v.note.metadata with
      | Ok (Some _) -> id_name (owner obs v.id), `String id
      | _ -> id, `Null in
    id, `Assoc ["title", `String v.note.title.text; "card", `String card; "block", block]) in
  let registry = Yojson.Safe.to_string (`Assoc registry) in
  let notes = vertices |> List.filter_map (fun (v : _ Graph.note Graph.vertex) ->
    match v.note.metadata, definition_spans obs v.id with
    | Ok None, [span] -> Some (id_name v.id, span.file, v.note.title.text)
    | _ -> None) in
  let home, notes = List.partition (fun (_, file, _) -> file = guide workspace) notes in
  let title = match home with
    | [("home", _, title)] -> title
    | _ -> fail "index.typ must declare one card named home" in
  let seen = Hashtbl.create (List.length notes) in
  let article out file =
    if Hashtbl.mem seen file then fail "the reader requires one card per file: %s" file;
    Hashtbl.add seen file ();
    let path = String.sub file (String.length workspace) (String.length file - String.length workspace) in
    Printf.bprintf out "#html.elem(\"article\")[#include %s]\n" (json_string path) in
  let source = Buffer.create 4096 in
  Buffer.add_string source "#import \"/reader/book.typ\": card-links\n#set text(lang: \"zh\")\n#show heading: it => html.elem(\"h\" + str(calc.min(6, it.level)), it.body)\n#show: card-links\n";
  Buffer.add_string source "#html.elem(\"main\", attrs: (class: \"zk-stack\"))[\n#html.elem(\"section\", attrs: (class: \"zk-pane\", \"data-node\": \"home\"))[\n";
  article source (guide workspace);
  Buffer.add_string source "]\n]\n";
  List.iter (fun (id, file, _) ->
    Printf.bprintf source "#html.elem(\"template\", attrs: (\"data-id\": %s))[\n" (json_string id);
    article source file;
    Buffer.add_string source "]\n") notes;
  let html = compile workspace registry (Buffer.contents source) in
  let chunks_by_id = Hashtbl.create (List.length chunks) in
  List.iter (fun card -> Hashtbl.add chunks_by_id (id_name card.id) card) chunks;
  let marker = Str.regexp {|<div data-lit-chunk="\([^"]+\)"></div>|} in
  let html = Str.global_substitute marker (fun html ->
    let id = Str.matched_group 1 html in
    match Hashtbl.find_opt chunks_by_id id with
    | Some card -> code_html obs card
    | None -> fail "rendered unknown chunk %s" id) html in
  let assets name = read (Filename.concat (Filename.concat workspace "reader") name) in
  let replace tag text html = Str.replace_first (Str.regexp_string tag) text html in
  let inject tag content html =
    let i = Str.search_forward (Str.regexp_string tag) html 0 in
    String.sub html 0 i ^ content ^ String.sub html i (String.length html - i) in
  html
  |> replace "<body>" "<body><header class=\"zk-bar\"><a href=\"#\" aria-label=\"回到导览\">Ospero</a>文学编程笔记</header>"
  |> inject "</head>" ("<title>" ^ escape title ^ " · Ospero</title><style>" ^ assets "reader.css" ^ "</style>")
  |> inject "</body>" ("<script>" ^ assets "reader.js" ^ "</script>")
