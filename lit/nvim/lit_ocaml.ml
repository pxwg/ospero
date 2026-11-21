open Lit_model
open Yojson.Safe.Util

let ( let* ) = Lwt.bind
let return = Lwt.return

let obj fields = `Assoc fields
let str text = `String text
let uri file = Uri.make ~scheme:"file" ~host:"" ~path:file () |> Uri.to_string
let path uri = Uri.of_string uri |> Uri.path |> Uri.pct_decode

let send channel fields =
  let body = Yojson.Safe.to_string (obj (("jsonrpc", str "2.0") :: fields)) in
  Lwt_io.atomic (fun channel ->
    let* () = Lwt_io.write channel (Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length body)) in
    let* () = Lwt_io.write channel body in
    Lwt_io.flush channel) channel

let receive channel =
  let rec headers length =
    let* line = Lwt_io.read_line channel in
    let line = String.trim line in
    if line = "" then Lwt.return length
    else match String.index_opt line ':' with
      | Some i when String.lowercase_ascii (String.sub line 0 i) = "content-length" ->
          headers (int_of_string (String.trim (String.sub line (i + 1) (String.length line - i - 1))))
      | _ -> headers length in
  let* length = headers 0 in
  let body = Bytes.create length in
  let* () = Lwt_io.read_into_exactly channel body 0 length in
  Lwt.return (Yojson.Safe.from_string (Bytes.unsafe_to_string body))

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

let object_fields = function `Assoc fields -> fields | _ -> []
let list = function `List xs -> xs | _ -> []
let put key value json = obj ((key, value) :: List.remove_assoc key (object_fields json))
let message method_ params =
  if params = `Null then ["method", str method_]
  else ["method", str method_; "params", params]
let document file = obj ["uri", str (uri file)]
let file_of json = json |> member "uri" |> to_string |> path
let span_of_range file text json =
  match offset text (member "start" json), offset text (member "end" json) with
  | Some start, Some stop when start <= stop -> Some { P.file; start; stop }
  | _ -> None

let workspace_edits edit =
  let changes = object_fields (member "changes" edit) |> List.map (fun (uri, edits) -> path uri, list edits) in
  let document_changes = list (member "documentChanges" edit) |> List.map (fun change ->
    if member "kind" change <> `Null then fail "OCaml rename requires a file operation";
    file_of (member "textDocument" change), list (member "edits" change)) in
  changes @ document_changes

let relative root file =
  let prefix = root ^ "/" in
  if String.starts_with ~prefix file then
    Some (String.sub file (String.length prefix) (String.length file - String.length prefix))
  else None

let source_edits ~root ~sources ~parsed ~outputs edit =
  let generated = workspace_edits edit |> List.concat_map (fun (file, edits) ->
    let target = match relative root file with
      | Some target when Files.mem target outputs -> target
      | _ -> fail "OCaml edit targets a file outside the Lit projection" in
    let output = Files.find target outputs in
    List.map (fun edit ->
      match span_of_range target output.text (member "range" edit) with
      | Some span -> span, to_string (member "newText" edit)
      | None -> fail "Invalid OCaml edit range") edits) in
  project_edits ~sources ~parsed ~outputs generated

let workspace_edit ~sources ~versions edits =
  let changes = Files.bindings edits |> List.map (fun (file, edits) ->
    let version = Option.value (Files.find_opt file versions) ~default:`Null in
    obj ["textDocument", put "version" version (document file);
         "edits", `List (List.map (fun (span, replacement) ->
           obj ["range", range (Files.find file sources) span; "newText", str replacement]) edits)]) in
  obj ["documentChanges", `List changes]


let ocaml_target name = Filename.check_suffix name ".ml" || Filename.check_suffix name ".mli"

let available () =
  let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  String.split_on_char ':' path |> List.exists (fun dir ->
    let file = Filename.concat dir "ocamllsp" in
    try Unix.access file [Unix.X_OK]; not (Sys.is_directory file) with Unix.Unix_error _ | Sys_error _ -> false)

let rec remove_tree path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then begin
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  end else Unix.unlink path

type 'parsed snapshot = {
  sources : string Files.t;
  parsed : 'parsed Files.t;
  outputs : output Files.t;
}

type build = Starting of Lwt_process.process_none | Watching of Lwt_process.process_none

type 'parsed workspace = {
  root : string;
  publish : Yojson.Safe.t -> unit Lwt.t;
  mutable build : build option;
  mutable saved : string Files.t;
  mutable current : 'parsed snapshot option;
  mutable revision : int;
  mutable announced : (string * bool) Files.t;
}

let rec workspace_directory random =
  let name = Printf.sprintf "ospero-lit-%08x" (Random.State.bits random) in
  let root = Filename.concat (Filename.get_temp_dir_name ()) name in
  match Unix.mkdir root 0o700 with
  | () -> Unix.realpath root
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> workspace_directory random

let create ~publish =
  let root = workspace_directory (Random.State.make_self_init ()) in
  { root; publish; build = None; saved = Files.empty; current = None; revision = 0;
    announced = Files.empty }

let ready workspace = match workspace.build with Some (Starting _) -> false | _ -> true

let publish workspace =
  let documents = match workspace.current with
    | None -> Files.empty
    | Some snapshot -> snapshot.outputs |> Files.filter_map (fun target output ->
        if not (ocaml_target target) then None else
        Some (output.text, Files.find_opt target workspace.saved = Some output.text)) in
  let target_uri target = str (uri (Filename.concat workspace.root target)) in
  let files = Files.bindings documents |> List.filter_map (fun (target, (text, saved)) ->
    let before = Files.find_opt target workspace.announced in
    if before = Some (text, saved) then None else
    let fields = ["uri", target_uri target; "saved", `Bool saved] in
    let fields = if Option.map fst before = Some text then fields else ("text", str text) :: fields in
    Some (obj fields)) in
  let removed = Files.bindings workspace.announced |> List.filter_map (fun (target, _) ->
    if Files.mem target documents then None else Some (target_uri target)) in
  workspace.announced <- documents;
  workspace.publish (obj ["root", str workspace.root; "revision", `Int workspace.revision;
                          "ready", `Bool (ready workspace); "files", `List files; "removed", `List removed])

let write_saved workspace saved =
  let saved = texts saved in
  Files.iter (fun file _ ->
    if not (Files.mem file saved) then begin
      let path = Filename.concat workspace.root file in
      Sys.remove path;
      let rec prune dir =
        if dir <> workspace.root && Array.length (Sys.readdir dir) = 0 then begin
          Unix.rmdir dir;
          prune (Filename.dirname dir)
        end in
      prune (Filename.dirname path)
    end) workspace.saved;
  Files.iter (fun file text ->
    if Files.find_opt file workspace.saved <> Some text then write (Filename.concat workspace.root file) text) saved;
  workspace.saved <- saved

let dune workspace options =
  let args = ["dune"; "build"; "--root"; workspace.root] @ options in
  Lwt_process.open_process_none ~cwd:workspace.root ~stdin:`Dev_null
    ~stdout:`Dev_null ~stderr:`Dev_null ("", Array.of_list args)

let watch workspace =
  if Option.is_none workspace.build && Files.mem "dune-project" workspace.saved then begin
    let initial = dune workspace [] in
    workspace.build <- Some (Starting initial);
    Lwt.async (fun () -> Lwt.catch (fun () ->
      let* _ = initial#close in
      match workspace.build with
      | Some (Starting process) when process == initial ->
          workspace.build <- Some (Watching (dune workspace ["--watch"]));
          publish workspace
      | _ -> return ()) (fun error ->
      prerr_endline ("Lit workspace: " ^ Printexc.to_string error);
      return ()))
  end

let sync workspace ~saved current =
  Option.iter (write_saved workspace) saved;
  watch workspace;
  workspace.current <- current;
  workspace.revision <- workspace.revision + 1;
  publish workspace

let stop workspace =
  let build = workspace.build in
  workspace.build <- None;
  let* () = match build with
    | None -> return ()
    | Some (Starting process | Watching process) ->
        process#terminate;
        let* _ = process#close in
        return () in
  remove_tree workspace.root;
  return ()

let context_label snapshot (target, _, splices) =
  let location (span : P.span) =
    let at = position (Files.find span.file snapshot.sources) span.start in
    Printf.sprintf "%s:%d:%d" (Filename.basename span.file)
      (to_int (member "line" at) + 1) (to_int (member "character" at) + 1) in
  String.concat " ← " (target :: List.rev_map location splices)

let rec markdown = function
  | `String text -> text
  | `List contents -> String.concat "

" (List.map markdown contents)
  | `Assoc _ as content ->
      let value = content |> member "value" |> to_string in
      (match member "language" content with
       | `String language -> Printf.sprintf "~~~%s
%s
~~~" language value
       | _ -> value)
  | _ -> ""

let hover snapshot results =
  let texts = List.map (fun (context, response) ->
    context, if response = `Null then "" else markdown (member "contents" response)) results in
  let body = match List.sort_uniq String.compare (List.map snd texts) with
    | [] | [""] -> ""
    | [text] -> text
    | distinct -> List.map (fun text ->
        let labels = texts |> List.filter_map (fun (context, value) ->
          if value = text then Some (context_label snapshot context) else None) in
        Printf.sprintf "**%s**

%s" (String.concat " · " labels)
          (if text = "" then "No OCaml information at these occurrences." else text)) distinct
        |> String.concat "

---

" in
  if body = "" then `Null else obj ["contents", obj ["kind", str "markdown"; "value", str body]]

let location workspace snapshot result =
  let link = member "targetUri" result <> `Null in
  let uri_key, range_key = if link then "targetUri", "targetSelectionRange" else "uri", "range" in
  let location_uri = member uri_key result in
  let file = path (to_string location_uri) in
  let range_json = member range_key result in
  match relative workspace.root file with
  | None -> Some (obj ["uri", location_uri; "range", range_json])
  | Some target ->
      Option.bind (Files.find_opt target snapshot.outputs) (fun output ->
        Option.bind (span_of_range target output.text range_json) (fun span ->
          Option.map (fun (origin : P.span) ->
            obj ["uri", str (uri origin.file);
                 "range", range (Files.find origin.file snapshot.sources) origin])
            (origin_of_range output span)))

let completion workspace snapshot file (target, _, _) response =
  let items, incomplete = match response with
    | `List items -> items, false
    | `Null -> [], false
    | result -> list (member "items" result), member "isIncomplete" result = `Bool true in
  let items = List.filter_map (fun item ->
    let primary = member "textEdit" item in
    if primary = `Null then None else
    let changes = primary :: list (member "additionalTextEdits" item) in
    let edit = obj ["changes", obj [uri (Filename.concat workspace.root target), `List changes]] in
    try
      let projected = source_edits ~root:workspace.root ~sources:snapshot.sources ~parsed:snapshot.parsed ~outputs:snapshot.outputs edit in
      let output = Files.find target snapshot.outputs in
      let source = Files.find file snapshot.sources in
      match Files.bindings projected,
            Option.bind (span_of_range target output.text (member "range" primary)) (origin_of_range output) with
      | [written_file, edits], Some span when written_file = file && span.file = file ->
          let primary = span, to_string (member "newText" primary) in
          let encode (span, text) = obj ["range", range source span; "newText", str text] in
          let fields = List.filter (fun (key, _) ->
            not (List.mem key ["textEdit"; "additionalTextEdits"; "command"; "data"])) (object_fields item) in
          Some (obj (("textEdit", encode primary) ::
                     ("additionalTextEdits", `List (List.filter ((<>) primary) edits |> List.map encode)) :: fields))
      | _ -> None
    with Failure _ | Type_error _ -> None) items in
  obj ["items", `List items; "isIncomplete", `Bool incomplete]

let lookup workspace params =
  match workspace.current with
  | None -> `Null
  | Some snapshot ->
      let file = file_of (member "textDocument" params) in
      let at = Option.bind (Files.find_opt file snapshot.sources) (fun source -> offset source (member "position" params)) in
      let contexts = match at with None -> [] | Some at -> occurrences snapshot.outputs file at in
      let contexts = List.filter_map (fun (target, at, _) ->
        if not (ocaml_target target) then None else
        let output = Files.find target snapshot.outputs in
        Some (obj ["textDocument", document (Filename.concat workspace.root target); "position", position output.text at])) contexts in
      obj ["revision", `Int workspace.revision; "contexts", `List contexts]

let project_result workspace ~versions params =
  match workspace.current with
  | None -> `Null
  | Some _ when member "revision" params <> `Int workspace.revision -> `Null
  | Some snapshot ->
      let method_ = params |> member "method" |> to_string in
      let file = file_of (member "textDocument" params) in
      let results = list (member "results" params) in
      match method_ with
      | "textDocument/definition" | "textDocument/references" | "textDocument/typeDefinition"
      | "textDocument/implementation" | "textDocument/declaration" ->
          `List (results |> List.concat_map (function `List xs -> xs | `Null -> [] | x -> [x])
             |> List.filter_map (location workspace snapshot) |> List.sort_uniq compare)
      | "textDocument/rename" ->
          let plans = List.map (function `Null -> Files.empty | result ->
            source_edits ~root:workspace.root ~sources:snapshot.sources ~parsed:snapshot.parsed ~outputs:snapshot.outputs result) results in
          (match plans with
           | first :: rest when List.for_all (Files.equal (=) first) rest ->
               if Files.is_empty first then `Null else workspace_edit ~sources:snapshot.sources ~versions first
           | [] -> `Null
           | _ -> fail "OCaml rename has different edits across Lit expansions")
      | "textDocument/hover" | "textDocument/completion" ->
          let contexts = occurrences snapshot.outputs file (Option.get (offset (Files.find file snapshot.sources) (member "position" params)))
            |> List.filter (fun (target, _, _) -> ocaml_target target) in
          if List.length contexts <> List.length results then `Null
          else if method_ = "textDocument/hover" then hover snapshot (List.combine contexts results)
          else (match contexts, results with
            | [context], [result] -> completion workspace snapshot file context result
            | _ -> `Null)
      | _ -> `Null

let project_diagnostics workspace params =
  match workspace.current, relative workspace.root (file_of params) with
  | Some snapshot, Some target when ready workspace && member "revision" params = `Int workspace.revision ->
      (match Files.find_opt target snapshot.outputs with
      | Some output when Files.find_opt target workspace.saved = Some output.text ->
          `List (list (member "diagnostics" params) |> List.filter_map (fun diagnostic ->
            let span = Option.bind (span_of_range target output.text (member "range" diagnostic))
                (origin_of_range ~clip:true output) in
            Option.map (fun (span : P.span) ->
              let fields = object_fields diagnostic |> List.remove_assoc "relatedInformation" in
              obj ["uri", str (uri span.file); "diagnostic", put "range" (range (Files.find span.file snapshot.sources) span) (obj fields)]) span))
      | _ -> `Null)
  | _ -> `Null
