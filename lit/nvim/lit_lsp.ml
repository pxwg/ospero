open Ospero.Core
open Lit_model
open Yojson.Safe.Util

open Lit_ocaml

let send = send Lwt_io.stdout

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

let serve workspace =
  let buffers = ref Files.empty in
  let snapshot = ref None in
  let in_project = is_source workspace in
  let versions = ref Files.empty in
  let disk = ref Files.empty in
  let parsed = ref Files.empty in
  let workspace_projection = lazy (Lit_ocaml.create ~publish:(fun params ->
    send (message "ospero/projection" params))) in
  let projection_enabled = ref false in
  let lit_diagnostics = ref Files.empty in
  let publish file =
    let diagnostics = Option.value (Files.find_opt file !lit_diagnostics) ~default:[] in
    let params = ["uri", str (uri file); "diagnostics", `List diagnostics] in
    let params = match Files.find_opt file !versions with
      | None -> params | Some version -> ("version", version) :: params in
    send (message "textDocument/publishDiagnostics" (obj params)) in
  let refresh ?(reload = false) file =
    if reload then disk := sources workspace;
    let sources = Files.union (fun _ _ buffer -> Some buffer) !disk !buffers in
    parsed := Files.mapi (fun file source ->
      match Files.find_opt file !parsed with
      | Some (previous, batch) when previous = source -> previous, batch
      | _ -> source, parse_source file source) sources;
    let obs, diagnostics = observe_parsed (Files.map snd !parsed) in
    snapshot := Some (sources, obs);
    let problems = problems obs diagnostics in
    let entries = List.fold_left (fun entries (span, message) ->
      let span = Option.value span ~default:{ P.file; start = 0; stop = 0 } in
      let source = Files.find_opt span.file sources |> Option.value ~default:"" in
      let diagnostic = obj ["range", range source span; "message", str message;
                            "severity", `Int 1; "source", str "ospero-lit"] in
      Files.update span.file (fun prev -> Some (diagnostic :: Option.value prev ~default:[])) entries)
      Files.empty problems in
    let affected = Files.union (fun _ old _ -> Some old) !lit_diagnostics entries in
    lit_diagnostics := Files.map List.rev entries;
    let sync_projection () =
      let current = if problems <> [] then None else
        let outputs = project (code_cards obs) |> List.to_seq |> Files.of_seq in
        Some { Lit_ocaml.sources; parsed = Files.map snd !parsed; outputs } in
      let saved = if reload then project_sources !disk else None in
      Lit_ocaml.sync (Lazy.force workspace_projection) ~saved current in
    let* () = if not !projection_enabled then return () else
      Lwt.catch sync_projection (function
        | Failure message | Sys_error message ->
            prerr_endline ("Lit workspace: " ^ message);
            return ()
        | Unix.Unix_error (code, _, path) ->
            prerr_endline ("Lit workspace: " ^ path ^ ": " ^ Unix.error_message code);
            return ()
        | error -> Lwt.fail error) in
    let* () = Files.bindings !buffers |> Lwt_list.iter_s (fun (file, source) ->
      send ["method", str "ospero/titles"; "params", obj ["uri", str (uri file);
            "version", Files.find file !versions; "spans", `List (title_spans obs file source)]]) in
    Files.bindings affected |> Lwt_list.iter_s (fun (file, _) -> publish file)
  in
  let update ~reload document text =
    let file = path (to_string (member "uri" document)) in
    let* () = if in_project file then begin
      versions := Files.add file (member "version" document) !versions;
      buffers := Files.add file (text ()) !buffers;
      refresh ~reload file
    end else return () in
    return `Null in
  let request method_ params =
    let document () = member "textDocument" params in
    let file () = path (to_string (member "uri" (document ()))) in
    match method_ with
    | "initialize" ->
        let encodings = params |> member "capabilities" |> member "general" |> member "positionEncodings" in
        if not (match encodings with `List values -> List.mem (str "utf-8") values | _ -> false) then
          invalid_arg "Ospero Lit requires UTF-8 positions";
        projection_enabled := member "ocamlProjection" (member "initializationOptions" params) = `Bool true
          && Lit_ocaml.available ();
        return (obj ["capabilities", obj ["positionEncoding", str "utf-8";
          "textDocumentSync", obj ["openClose", `Bool true; "change", `Int 1; "save", `Bool true];
          "hoverProvider", `Bool true; "workspaceSymbolProvider", `Bool true;
          "completionProvider", obj ["triggerCharacters", `List [str "@"; str "<"]];
          "definitionProvider", `Bool true; "referencesProvider", `Bool true]])
    | "ospero/lookup" when !projection_enabled -> return (Lit_ocaml.lookup (Lazy.force workspace_projection) params)
    | "ospero/projectResult" when !projection_enabled ->
        return (Lit_ocaml.project_result (Lazy.force workspace_projection) ~versions:!versions params)
    | "ospero/projectDiagnostics" when !projection_enabled ->
        return (Lit_ocaml.project_diagnostics (Lazy.force workspace_projection) params)
    | "shutdown" -> return `Null
    | "exit" -> Lwt.fail End_of_file
    | "textDocument/didOpen" -> update ~reload:true (document ()) (fun () -> document () |> member "text" |> to_string)
    | "textDocument/didChange" -> update ~reload:false (document ()) (fun () -> params |> member "contentChanges" |> index 0 |> member "text" |> to_string)
    | "textDocument/didSave" ->
        let file = file () in
        let* () = if in_project file then refresh ~reload:true file else return () in
        return `Null
    | "textDocument/didClose" ->
        let file = file () in
        let* () = if in_project file then begin
          buffers := Files.remove file !buffers;
          versions := Files.remove file !versions;
          refresh ~reload:true file
        end else return () in
        return `Null
    | "workspace/symbol" | "textDocument/completion" ->
        (match !snapshot with
         | None -> return (`List [])
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
                 return (obj ["isIncomplete", `Bool true; "items", `List items])
             | _ -> return (`List items))
    | "textDocument/hover" | "textDocument/definition" | "textDocument/references" ->
        let file = file () in
        (match !snapshot with
         | Some (sources, obs) ->
             let at = Option.bind (Files.find_opt file sources) (fun source ->
               offset source (member "position" params)) in
             (match Option.bind at (target_at obs file) with
              | None -> return `Null
              | Some id when method_ = "textDocument/hover" ->
                  return (match title obs id with None -> `Null | Some label ->
                    obj ["contents", obj ["kind", str "plaintext"; "value", str (label ^ "\n" ^ id_name id)]])
              | Some id when method_ = "textDocument/definition" -> return (locations sources (definition_spans obs id))
              | Some id when method_ = "textDocument/references" ->
                  let declarations =
                    if params |> member "context" |> member "includeDeclaration" = `Bool true
                    then definition_spans obs id else [] in
                  let references = O.references_to obs id |> List.filter_map (fun (r : _ O.reference) -> r.target.span) in
                  return (locations sources (declarations @ references))
              | Some _ -> return `Null)
         | None -> return `Null)
    | _ -> raise Not_found
  in
  let handle msg =
    let id = member "id" msg in
    let respond fields = if id = `Null then return () else send (("id", id) :: fields) in
    let error code message =
      if id = `Null then (prerr_endline message; return ())
      else respond ["error", obj ["code", `Int code; "message", str message]] in
    Lwt.catch (fun () ->
      let* result = request (to_string (member "method" msg)) (member "params" msg) in
      respond ["result", result]) (function
      | Not_found -> if id = `Null then return () else error (-32601) "Method not found"
      | Type_error (message, _) | Invalid_argument message -> error (-32602) message
      | Failure message | Sys_error message -> error (-32603) message
      | Unix.Unix_error (code, _, path) -> error (-32603) (path ^ ": " ^ Unix.error_message code)
      | exn -> Lwt.fail exn)
  in
  let rec loop () =
    let* msg = receive Lwt_io.stdin in
    let* () = handle msg in
    loop () in
  Lwt.finalize (fun () -> Lwt.catch loop (function End_of_file -> return () | exn -> Lwt.fail exn))
    (fun () -> if Lazy.is_val workspace_projection then Lit_ocaml.stop (Lazy.force workspace_projection) else return ())

let () =
  match Array.to_list Sys.argv with
  | [_; workspace] -> Lwt_main.run (serve (Unix.realpath workspace))
  | _ -> prerr_endline "usage: lit_lsp WORKSPACE"; exit 1
