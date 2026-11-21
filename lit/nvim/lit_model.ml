open Ospero.Core
module Syntax = Ospero.Syntax
module Org = Syntax.Lang.Org
module Args = Syntax.Args
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
}

type action = Define of Text.t P.located | Block of block | Code_body of block

let define = Syntax.Action.declare ~name:"define"
  Args.(spec (let+ body = required "contents" contents ~get:Fun.id in body))

let code_block = Syntax.Action.declare ~name:"code-block" Args.(spec (
  let+ id = required "id" string ~get:(fun b -> b.id)
  and+ contents = required "contents" contents ~get:(fun b -> b.contents)
  and+ language = required "language" string ~get:(fun b -> b.language)
  and+ target = optional "target-file" string ~get:(fun b -> b.target)
  and+ noweb = required "noweb" bool ~get:(fun b -> b.noweb) in
  { id; contents; language; target; noweb }))

let input = Syntax.Frontend_input.create ~metadata:metadata_schema
  [ Syntax.Frontend_input.action define ~decode:(fun body -> Ok (Define body));
    Syntax.Frontend_input.action code_block ~decode:(fun block -> Ok (Block block)) ]

let src_block (node : Org.node P.located) (context : Org.context) =
  let field fields key = List.find_opt (fun f -> f.Syntax.Payload_rules.name.value = key) fields in
  let text f = match Syntax.Payload_rules.read context.values Args.string f.Syntax.Payload_rules.value with
    | Syntax.Matched value -> value
    | _ -> f.value in
  match node.value with
  | Org.Block { name; parameters; contents; _ } when String.lowercase_ascii name.value = "src" ->
      let header = parameters.value in
      let stop = Option.value (String.index_from_opt header 0 ' ') ~default:(String.length header) in
      let stop = min stop (Option.value (String.index_opt header '\t') ~default:stop) in
      let span = Option.map (fun (s : P.span) -> { s with start = s.start + stop }) parameters.span in
      let args = pos ?span (String.sub header stop (String.length header - stop)) in
      (match Org.arguments args with
       | Error _ -> Syntax.No_match
       | Ok fields ->
           let id = Option.map text (field fields "id") in
           let target = Option.map text (field fields "target-file") in
           let noweb = Option.map text (field fields "zk-noweb") in
           match id, target, noweb with
           | None, None, None -> Syntax.No_match
           | None, _, _ -> Syntax.Invalid [diagnostic ?span "code block needs an explicit :id"]
           | Some id, _, _ ->
               if stop = 0 || header.[0] = ':' then
                 Syntax.Invalid [diagnostic ?span:parameters.span "expected a source language"]
               else if id.value = "" || String.exists (function ' ' | '\t' | '<' | '>' -> true | _ -> false) id.value then
                 Syntax.Invalid [diagnostic ?span:id.span "expected a code card ID"]
               else if List.exists (fun key -> List.length (List.filter
                   (fun f -> f.Syntax.Payload_rules.name.value = key) fields) > 1)
                   ["id"; "target-file"; "zk-noweb"] then
                 Syntax.Invalid [diagnostic ?span "duplicate code block header argument"]
               else match noweb with
                 | Some flag when flag.value <> "yes" && flag.value <> "no" ->
                     Syntax.Invalid [diagnostic ?span:flag.span "expected :zk-noweb yes or no"]
                 | _ -> Syntax.Matched { id; contents; target;
                     language = pos ?span:parameters.span (String.sub header 0 stop);
                     noweb = pos (Option.exists (fun flag -> flag.P.value = "yes") noweb) })
  | _ -> Syntax.No_match

let config =
  let actions = Org.actions
    |> Org.Sugar.nested_card define (fun ~contents ~depth:_ -> contents)
    |> Syntax.Action_rules.bind ~sugar:"lit-source-block" code_block src_block in
  Syntax.configure [Org.adapter ~actions input]

module Decoder = Frontend.Decode (struct
  type nonrec metadata = metadata
  type nonrec action = action
  let decode_metadata = Syntax.Frontend_input.decode_metadata input
  let decode_action = Syntax.Frontend_input.decode_action input
end)

type piece = Code of string | Include_code of Graph.Vertex_id.t

(* Only a whole line can be a reference. Its newline is the splice boundary. *)
let pieces block =
  let text = block.contents.value.text in
  let slice start stop value =
    let span = Option.map (fun (s : P.span) ->
      { s with start = s.start + start; stop = s.start + stop }) block.contents.span in
    pos ?span value
  in
  let emit piece = O.Emit (O.Observed.Consume piece) in
  let literal start stop = emit (Code (String.sub text start (stop - start))) in
  let rec scan chunk from acc =
    if from = String.length text then
      List.rev (if chunk = from then acc else literal chunk from :: acc)
    else
      let stop = Option.value (String.index_from_opt text from '\n') ~default:(String.length text) in
      let next = min (stop + 1) (String.length text) in
      let line = String.sub text from (stop - from) |> String.trim in
      if not (String.starts_with ~prefix:"<<" line && String.ends_with ~suffix:">>" line
              && String.length line >= 4) then scan chunk next acc
      else
        let raw = String.sub line 2 (String.length line - 4) in
        let rec first i = if text.[i] = '<' then i else first (i + 1) in
        let start = first from + 2 in
        let target = slice start (start + String.length raw) raw in
        let acc = if chunk = from then acc else literal chunk from :: acc in
        let acc = match Graph.Vertex_id.of_string raw with
          | Ok id when not (String.exists (function ' ' | '\t' | '<' | '>' -> true | _ -> false) raw) ->
              emit (Include_code id) :: O.Relate { target = { target with value = id }; relation = () } :: acc
          | _ -> O.Fail (diagnostic ?span:target.span "expected <<card-id>>") :: acc in
        scan next next acc
  in
  if not block.noweb.value || text = "" then [literal 0 (String.length text)]
  else scan 0 0 []

module Observe = Frontend.Make (struct
  include Decoder
  type relation = unit
  type consumption = piece
  type error = Frontend.Diagnostic.t
  let interpret = function
    | Code_body block -> pieces block
    | Block block ->
        let span = block.contents.span in
        let title = { Text.text = block.id.value; language = Org.language } in
        let metadata = Some { language = block.language.value;
                              target = Option.map (fun path -> path.P.value) block.target } in
        let body = pos ?span [pos ?span (O.Source.Action (Ok (Code_body block)))] in
        (match Graph.Vertex_id.of_string block.id.value with
         | Ok id -> [O.Define (pos ?span { O.Source.id = { block.id with value = id };
                                           title = pos title; metadata = pos (Ok metadata); body })]
         | Error error -> [O.Fail (diagnostic ?span:block.id.span error)])
    | Define body ->
        match Syntax.parse_contents config body with
        | Ok note -> [O.Define (Decoder.decode_source note)]
        | Error errors -> List.map (fun error -> O.Fail error) errors
end)

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
  | O.Reference_error _ -> [item.span, "unresolved code reference"]
  | _ -> [item.span, "invalid card contribution"]

type card = { id : Graph.Vertex_id.t; title : string; language : string; target : string option; pieces : piece list }

let code_cards obs =
  O.graph obs |> Graph.vertices |> List.filter_map (fun ({ Graph.id; note } : metadata Frontend.decoded Graph.note Graph.vertex) ->
    match note.metadata with
    | Ok (Some metadata) ->
        let pieces = Option.value (O.body obs id) ~default:[] |> List.filter_map (fun item ->
          match item.P.value with
          | O.Observed.Consume piece -> Some piece
          | O.Observed.Text _ -> None) in
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
      | Include_code id ->
          match Hashtbl.find_opt index id with
          | None -> reject card "%s: %s is not a code card" (id_name card.id) (id_name id)
          | Some target when target.language <> card.language ->
              reject card "%s: incompatible language in %s" (id_name card.id) (id_name id)
          | Some _ -> ()) card.pieces) cards;
  let checked = Hashtbl.create (List.length cards) in
  let rec check_cycles stack card =
    if List.mem card.id stack then
      reject card "code inclusion cycle: %s" (String.concat " -> " (List.rev_map id_name (card.id :: stack)));
    if not (Hashtbl.mem checked card.id) then begin
      List.iter (function
        | Code _ -> ()
        | Include_code id -> check_cycles (card.id :: stack) (Hashtbl.find index id)) card.pieces;
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

(* Register block IDs from the same calls that will define them. The Org
   adapter handles heading IDs, including headings nested in a define. *)
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

let observe documents =
  let project, diagnostics = Syntax.parse_project config documents in
  let identities = project.identities @ List.concat_map code_ids project.notes in
  Observe.observe { project with identities }, diagnostics
