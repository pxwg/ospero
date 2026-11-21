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

let chunk_typst out obs splices card =
  let id = id_name card.id in
  let summary = Option.value card.target ~default:id in
  let raw_buf = Buffer.create 256 in
  List.iter (function
    | Code lines -> List.iter (fun line -> Buffer.add_string raw_buf line.P.value) lines
    | Include_code { target; padding } ->
        let target = target.P.value in
        let k = Hashtbl.length splices in
        let block = escape (id_name target) and owner_card = escape (id_name (owner obs target)) in
        let pad = escape padding in
        let link = Printf.sprintf
          "<a href=\"#stack=%s&amp;block=%s\" data-card=\"%s\" data-block=\"%s\" data-padding=\"%s\">%s&lt;&lt;%s&gt;&gt;</a>"
          owner_card block owner_card block pad pad block in
        Hashtbl.add splices k link;
        Printf.bprintf raw_buf "LITSPLICE%dEND\n" k) card.pieces;
  let attrs = match card.target with
    | Some path -> Printf.sprintf "(class: \"code\", \"data-block\": %s, \"data-target\": %s)"
        (json_string id) (json_string path)
    | None -> Printf.sprintf "(class: \"code\", \"data-block\": %s)" (json_string id) in
  Printf.bprintf out "#html.elem(\"details\", attrs: %s)[#html.elem(\"summary\", %s)#raw(lang: %s, block: true, %s)]"
    attrs (json_string summary) (json_string card.language) (json_string (Buffer.contents raw_buf))

let render workspace obs chunks =
  let vertices = Graph.vertices (O.graph obs) in
  let titles = Hashtbl.create (List.length vertices) in
  let registry = vertices |> List.map (fun (v : _ Graph.note Graph.vertex) ->
    let id = id_name v.id in
    Hashtbl.replace titles id v.note.title.text;
    let card, block = match v.note.metadata with
      | Ok (Some _) -> id_name (owner obs v.id), `String id
      | _ -> id, `Null in
    id, `Assoc ["title", `String v.note.title.text; "card", `String card; "block", block]) in
  let registry = Yojson.Safe.to_string (`Assoc registry) in
  let chunks_by_id = Hashtbl.create (List.length chunks) in
  List.iter (fun card -> Hashtbl.add chunks_by_id (id_name card.id) card) chunks;
  let splices = Hashtbl.create 64 in
  let notes = vertices |> List.filter_map (fun (v : _ Graph.note Graph.vertex) ->
    match v.note.metadata with
    | Ok None -> Some (v.id, id_name v.id, v.note.title.text)
    | _ -> None) in
  let home, notes = List.partition (fun (_, id, _) -> id = "home") notes in
  let home_id, title = match home with
    | [(vid, "home", title)] -> vid, title
    | _ -> fail "index.typ must declare one card named home" in
  let files = Hashtbl.create 32 in
  let slice (span : P.span) =
    let text = match Hashtbl.find_opt files span.file with
      | Some text -> text
      | None -> let text = read span.file in Hashtbl.add files span.file text; text in
    String.sub text span.start (span.stop - span.start) in
  let embed out target =
    let id = id_name target in
    let title = Option.value (Hashtbl.find_opt titles id) ~default:id in
    Printf.bprintf out "#html.elem(\"details\", attrs: (class: \"tree\", \"data-embed\": %s), html.elem(\"summary\", %s))"
      (json_string id) (json_string title) in
  let article out vid heading_title =
    Printf.bprintf out "#html.elem(\"article\")[\n= %s\n\n" heading_title;
    Option.value (O.body obs vid) ~default:[] |> List.iter (fun (part : _ P.located) ->
      match part.value, part.span with
      | O.Observed.Text text, _ -> Buffer.add_string out text.text
      | O.Observed.Consume (Code_piece _), _ -> ()
      | O.Observed.Consume (Chunk_ref id), _ ->
          let name = id_name id in
          (match Hashtbl.find_opt chunks_by_id name with
           | Some card -> chunk_typst out obs splices card
           | None -> fail "rendered unknown chunk %s" name)
      | O.Observed.Consume (Nested_card id), _ ->
          Buffer.add_char out '\n';
          embed out id;
          Buffer.add_char out '\n'
      | O.Observed.Consume (Embed_card _), Some span -> Buffer.add_string out (slice span)
      | O.Observed.Consume (Embed_card id), None -> embed out id
      | O.Observed.Consume (Link_ref _), Some span -> Buffer.add_string out (slice span)
      | O.Observed.Consume (Link_ref id), None ->
          Printf.bprintf out "#card-link(label(%s), auto)" (json_string (id_name id)));
    Buffer.add_string out "\n]\n" in
  let source = Buffer.create 4096 in
  Buffer.add_string source "#import \"/reader/book.typ\": card-link, card-links, include-note, source-index\n#set text(lang: \"zh\")\n#show heading: it => html.elem(\"h\" + str(calc.min(6, it.level)), it.body)\n#show: card-links\n";
  Buffer.add_string source "#html.elem(\"main\", attrs: (class: \"zk-stack\"))[\n#html.elem(\"section\", attrs: (class: \"zk-pane\", \"data-node\": \"home\"))[\n";
  article source home_id title;
  Buffer.add_string source "]\n]\n";
  List.iter (fun (vid, id, card_title) ->
    Printf.bprintf source "#html.elem(\"template\", attrs: (\"data-id\": %s))[\n" (json_string id);
    article source vid card_title;
    Buffer.add_string source "]\n") notes;
  let html = compile workspace registry (Buffer.contents source) in
  let splice_re = Str.regexp {|\(<span[^>]*>\|<strong>\|<em>\)*LITSPLICE\([0-9]+\)END\(</span>\|</strong>\|</em>\)*|} in
  let html = Str.global_substitute splice_re (fun html ->
    let k = int_of_string (Str.matched_group 2 html) in
    Hashtbl.find splices k) html in
  let assets name = read (Filename.concat (Filename.concat workspace "reader") name) in
  let replace tag text html = Str.replace_first (Str.regexp_string tag) text html in
  let inject tag content html =
    let i = Str.search_forward (Str.regexp_string tag) html 0 in
    String.sub html 0 i ^ content ^ String.sub html i (String.length html - i) in
  html
  |> replace "<body>" "<body><header class=\"zk-bar\"><a href=\"#\" aria-label=\"回到导览\">Ospero</a>文学编程笔记</header>"
  |> inject "</head>" ("<title>" ^ escape title ^ " · Ospero</title><style>" ^ assets "reader.css" ^ "</style>")
  |> inject "</body>" ("<script>" ^ assets "reader.js" ^ "</script>")
