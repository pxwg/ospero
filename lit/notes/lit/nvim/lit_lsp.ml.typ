#import "/reader/book.typ": chunk

= 编辑器如何读取观察 <lit:nvim:lit_lsp.ml>

编辑器每次观察当前缓冲区和磁盘卡片。定义、反向引用和诊断直接使用观察记录的字节区间。

#chunk(id: <source-lit-nvim-lit-lsp-ml>)[
```ocaml
open Ospero.Core
open Lit_model
open Yojson.Safe.Util

let obj fields = `Assoc fields
let str text = `String text
let uri file = Uri.make ~scheme:"file" ~host:"" ~path:file () |> Uri.to_string
let path uri = Uri.of_string uri |> Uri.path |> Uri.pct_decode

let send fields =
  let body = Yojson.Safe.to_string (obj (("jsonrpc", str "2.0") :: fields)) in
  Printf.printf "Content-Length: %d\r\n\r\n%s%!" (String.length body) body

let position source offset =
  let line = ref 0 and start = ref 0 in
  let offset = max 0 (min offset (String.length source)) in
  for i = 0 to offset - 1 do
    if source.[i] = '\n' then (incr line; start := i + 1)
  done;
  obj ["line", `Int !line; "character", `Int (offset - !start)]

let offset source at =
  let line = to_int (member "line" at) and column = to_int (member "character" at) in
  let rec find start = function
    | 0 ->
        let stop = Option.value (String.index_from_opt source start '\n') ~default:(String.length source) in
        if column >= 0 && column <= stop - start then Some (start + column) else None
    | n when n > 0 ->
        Option.bind (String.index_from_opt source start '\n') (fun stop -> find (stop + 1) (n - 1))
    | _ -> None
  in
  find 0 line

let range source (span : P.span) =
  obj ["start", position source span.start; "end", position source span.stop]

let locations sources spans =
  `List (List.filter_map (fun (span : P.span) ->
    Files.find_opt span.file sources |> Option.map (fun source ->
      obj ["uri", str (uri span.file); "range", range source span])) spans)

let contains file at = function
  | Some (span : P.span) -> span.file = file && span.start <= at && at < span.stop
  | None -> false

let target_at obs file at =
  let contains = contains file at in
  let reference_span (r : _ O.reference) =
    match r.edges, r.target.span with
    | [{ Graph.relation = Splice; _ }], Some span ->
        Some { span with start = span.start - 2; stop = span.stop + 2 }
    | _ -> r.call in
  match List.find_opt (fun r -> contains (reference_span r)) (O.references obs) with
  | Some r -> Some r.target.value
  | None -> O.all_definitions obs |> List.find_map (fun (d : _ O.definition) ->
      if contains d.id.span then Some d.id.value else None)

let title_spans obs file source =
  O.references obs |> List.filter_map (fun (r : _ O.reference) ->
    match r.edges, r.call, r.target.span, title obs r.target.value with
    | [{ Graph.relation = Link; _ }], Some span, Some target, Some label
      when span.file = file && source.[span.start] = '@' ->
        let written = String.sub source span.start (span.stop - span.start) in
        let label =
          if target.stop + 2 < span.stop && source.[target.stop] = '[' then
            String.sub source (target.stop + 1) (span.stop - target.stop - 2)
          else label in
        Some (obj ["range", range source span; "source", str written; "label", str label])
    | _ -> None)

let publish file diagnostics =
  send ["method", str "textDocument/publishDiagnostics";
        "params", obj ["uri", str (uri file); "diagnostics", `List diagnostics]]

let serve workspace =
  let buffers = ref Files.empty and published = ref Files.empty in
  let snapshot = ref None in
  let in_project = is_source workspace in
  let versions = ref Files.empty in
  let disk = ref Files.empty in
  let parsed = ref Files.empty in
  let refresh ?(reload = false) file =
    if reload then disk := sources workspace;
    let sources = Files.union (fun _ _ buffer -> Some buffer) !disk !buffers in
    parsed := Files.mapi (fun file source ->
      match Files.find_opt file !parsed with
      | Some (previous, batch) when previous = source -> previous, batch
      | _ -> source, parse_source file source) sources;
    let obs, diagnostics = observe_parsed (Files.map snd !parsed) in
    snapshot := Some (sources, obs);
    Files.iter (fun file source ->
      send ["method", str "ospero/titles"; "params", obj ["uri", str (uri file);
            "version", Files.find file !versions; "spans", `List (title_spans obs file source)]]) !buffers;
    let entries = List.fold_left (fun entries (span, message) ->
      let span = Option.value span ~default:{ P.file; start = 0; stop = 0 } in
      let source = Files.find_opt span.file sources |> Option.value ~default:"" in
      let diagnostic = obj ["range", range source span; "message", str message;
                            "severity", `Int 1; "source", str "ospero-lit"] in
      Files.update span.file (fun prev -> Some (diagnostic :: Option.value prev ~default:[])) entries)
      Files.empty (problems obs diagnostics) in
    Files.iter (fun file _ -> if not (Files.mem file entries) then publish file []) !published;
    Files.iter (fun file diagnostics -> publish file (List.rev diagnostics)) entries;
    published := entries
  in
  let update ~reload document text =
    let file = path (to_string (member "uri" document)) in
    if in_project file then begin
      versions := Files.add file (member "version" document) !versions;
      buffers := Files.add file (text ()) !buffers;
      refresh ~reload file
    end;
    `Null in
  let request method_ params =
    let document () = member "textDocument" params in
    let file () = path (to_string (member "uri" (document ()))) in
    match method_ with
    | "initialize" ->
        let encodings = params |> member "capabilities" |> member "general" |> member "positionEncodings" in
        if not (match encodings with `List values -> List.mem (str "utf-8") values | _ -> false) then
          invalid_arg "Ospero Lit requires UTF-8 positions";
        obj ["capabilities", obj ["positionEncoding", str "utf-8";
          "textDocumentSync", obj ["openClose", `Bool true; "change", `Int 1; "save", `Bool true];
          "hoverProvider", `Bool true; "workspaceSymbolProvider", `Bool true;
          "completionProvider", obj ["triggerCharacters", `List [str "@"; str "<"]];
          "definitionProvider", `Bool true; "referencesProvider", `Bool true]]
    | "shutdown" -> `Null
    | "exit" -> exit 0
    | "textDocument/didOpen" -> update ~reload:true (document ()) (fun () -> document () |> member "text" |> to_string)
    | "textDocument/didChange" -> update ~reload:false (document ()) (fun () -> params |> member "contentChanges" |> index 0 |> member "text" |> to_string)
    | "textDocument/didSave" -> let file = file () in if in_project file then refresh ~reload:true file; `Null
    | "textDocument/didClose" ->
        let file = file () in
        if in_project file then begin buffers := Files.remove file !buffers; versions := Files.remove file !versions; refresh ~reload:true file end;
        `Null
    | "workspace/symbol" | "textDocument/completion" ->
        (match !snapshot with
         | None -> `List []
         | Some (sources, obs) ->
             let query = match member "query" params with `String q -> String.lowercase_ascii q | _ -> "" in
             let edit =
               if method_ <> "textDocument/completion" then None else
               let path = file () in
               Option.bind (Files.find_opt path sources) (fun source ->
                 Option.bind (offset source (member "position" params)) (fun stop ->
                   let start = match String.rindex_from_opt source (stop - 1) '\n' with
                     | Some newline -> newline + 1 | None -> 0 in
                   let prefix = String.sub source start (stop - start) in
                   let context = Str.regexp {|\(@\|<<\)\([^][<>@]*\)$|} in
                   match Str.search_forward context prefix 0 with
                   | exception Not_found -> None
                   | _ ->
                       let kind = Str.matched_group 1 prefix and typed = Str.matched_group 2 prefix in
                       let first = start + Str.group_beginning 2 in
                       if kind = "<<" && String.exists (function ' ' | '\t' -> true | _ -> false) typed then None
                       else Some (kind, typed, range source { P.file = path; start = first; stop }))) in
             let query = match edit with
               | Some (kind, typed, _) when kind <> "<<" -> String.trim typed |> String.lowercase_ascii
               | _ -> query in
             let pattern = Str.regexp_string query in
             let matches s = try ignore (Str.search_forward pattern
               (String.lowercase_ascii s) 0); true with Not_found -> false in
             let items = Graph.vertices (O.graph obs) |> List.filter_map (fun (vertex : _ Graph.vertex) ->
               let name = id_name vertex.Graph.id and label = vertex.note.Graph.title.text in
               if method_ = "textDocument/completion" then
                 (match edit, vertex.note.metadata with
                  | Some (kind, typed, range), Ok metadata
                    when (String.starts_with ~prefix:typed name || (kind <> "<<" && matches label))
                      && (kind <> "<<" || Option.is_some metadata)
                      ->
                      let display =
                        if kind = "<<" then ["label", str name; "detail", str label]
                        else ["label", str label; "detail", str name;
                              "labelDetails", obj ["description", str name];
                              "filterText", str (label ^ " " ^ name)] in
                      Some (obj (display @ ["kind", `Int 18;
                                 "textEdit", obj ["range", range; "newText", str name]]))
                  | _ -> None)
               else if matches name || matches label then
                 (match locations sources (definition_spans obs vertex.id) with
                  | `List [loc] ->
                      let kind = match vertex.note.metadata with Ok (Some _) -> 13 | _ -> 19 in
                      Some (obj ["name", str label; "containerName", str name;
                                 "kind", `Int kind; "location", loc])
                  | _ -> None)
               else None) in
             match edit with
             | Some (kind, _, _) when kind <> "<<" ->
                 obj ["isIncomplete", `Bool true; "items", `List items]
             | _ -> `List items)
    | "textDocument/hover" | "textDocument/definition" | "textDocument/references" ->
        let file = file () in
        (match !snapshot with
         | Some (sources, obs) ->
             let at = Option.bind (Files.find_opt file sources) (fun source ->
               offset source (member "position" params)) in
             (match Option.bind at (target_at obs file) with
              | None -> `Null
              | Some id when method_ = "textDocument/hover" ->
                  (match title obs id with None -> `Null | Some label ->
                    obj ["contents", obj ["kind", str "plaintext"; "value", str (label ^ "\n" ^ id_name id)]])
              | Some id when method_ = "textDocument/definition" -> locations sources (definition_spans obs id)
              | Some id ->
                  let declarations =
                    if params |> member "context" |> member "includeDeclaration" = `Bool true
                    then definition_spans obs id else [] in
                  let references = O.references_to obs id |> List.filter_map (fun (r : _ O.reference) -> r.target.span) in
                  locations sources (declarations @ references))
         | None -> `Null)
    | _ -> raise Not_found
  in
  let handle msg =
    let id = member "id" msg in
    let respond fields = if id <> `Null then send (("id", id) :: fields) in
    let error code message =
      if id = `Null then prerr_endline message
      else respond ["error", obj ["code", `Int code; "message", str message]] in
    try respond ["result", request (to_string (member "method" msg)) (member "params" msg)] with
    | Not_found -> if id <> `Null then error (-32601) "Method not found"
    | Type_error (message, _) | Invalid_argument message -> error (-32602) message
    | Sys_error message -> error (-32603) message
    | Unix.Unix_error (code, _, path) -> error (-32603) (path ^ ": " ^ Unix.error_message code)
  in
  let rec headers length =
    let line = String.trim (input_line stdin) in
    if line = "" then length
    else match String.index_opt line ':' with
      | Some i when String.lowercase_ascii (String.sub line 0 i) = "content-length" ->
          headers (int_of_string (String.trim (String.sub line (i + 1) (String.length line - i - 1))))
      | _ -> headers length
  in
  try while true do
    let length = headers 0 in
    handle (Yojson.Safe.from_string (really_input_string stdin length))
  done with End_of_file -> ()

let () =
  match Array.to_list Sys.argv with
  | [_; workspace] -> serve (Unix.realpath workspace)
  | _ -> prerr_endline "usage: lit_lsp WORKSPACE"; exit 1
```
]

#chunk(id: <file-lit-nvim-lit-lsp-ml>, target: "lit/nvim/lit_lsp.ml")[
```ocaml
<<source-lit-nvim-lit-lsp-ml>>
```
]
