open Ospero_kernel
open Frontend
module Payload_rules = Rules.Payload_rules
module Identity_rules = Rules.Identity_rules
module Action_rules = Rules.Action_rules

type nested = { level : int; extent : Provenance.span }

type 'value context = {
  level : int;
  slice : Provenance.span -> Text.t Provenance.located;
  values : 'value Payload_rules.reader;
  named :
    name:string Provenance.located -> ?body:Text.t Provenance.located ->
    'value Payload_rules.field list -> (Invocation.t, Diagnostic.t list) result;
}

type ('heading, 'value) heading = {
  level : int;
  identity : 'heading Provenance.located;
  title : Provenance.span;
  metadata : 'value Payload_rules.field list;
  metadata_span : Provenance.span option;
  start : int;
  body_start : int;
}

type ('heading, 'value, 'node) outline = {
  headings : ('heading, 'value) heading list;
  nodes : 'node Provenance.located list;
}

type ('native, 'heading, 'value, 'node) language = {
  language : Text.Language.t;
  source : 'native -> string;
  scan :
    file:string -> 'native ->
    (('heading, 'value, 'node) outline, Diagnostic.t list) result;
  read :
    file:string -> string -> start:int ->
    (('heading, 'value, 'node) outline, Diagnostic.t list) result;
  nested : nested -> 'node;
  children : 'node -> 'node Provenance.located list;
}

let invalid ?span message = Diagnostic.make ?span (Invalid message)

let collect results =
  match List.concat_map (function Error e -> e | Ok _ -> []) results with
  | [] -> Ok (List.filter_map Result.to_option results)
  | errors -> Error errors

let start_of (node : _ Provenance.located) =
  match node.span with Some s -> s.start | None -> max_int

(* {1 Named calls} *)

(* A trailing body has no name in the source; it belongs to the single
   Contents parameter the action declares. *)
let body_parameter (Syntax.Action.Pack action) =
  List.filter_map (fun (name, Syntax.Args.Value v) ->
    let Syntax.Args.Value carrier = Syntax.Args.carrier v in
    match Syntax.Args.equal carrier Syntax.Args.contents with
    | Some Equal -> Some name
    | None -> None)
    (Syntax.Action.parameters action)

let named frontend reader ~(name : string Provenance.located) ?body fields =
  match Action_rules.named frontend reader ~name fields with
  | Error _ as error -> error
  | Ok call ->
      match body with
      | None -> Ok call
      | Some (contents : Text.t Provenance.located) ->
          let action = Option.get (Syntax.Frontend_input.find_action frontend name.value) in
          match body_parameter action with
          | [ parameter ] ->
              let field =
                { Payload.name = Provenance.located ?span:contents.span parameter;
                  value = Syntax.Args.encode Syntax.Args.contents contents }
              in
              Ok { call with arguments = call.arguments @ [ field ] }
          | [] -> Error [ invalid ?span:contents.span (name.value ^ " takes no body") ]
          | _ ->
              Error [ invalid ?span:contents.span
                (name.value ^ " declares several Contents parameters; name the body") ]

(* {1 Card trees} *)

type ('heading, 'value, 'node) tree = {
  head : ('heading, 'value) heading;
  id : Graph.Vertex_id.t Provenance.located;
  extent : Provenance.span;
  items : ('heading, 'value, 'node) item list;
}

and ('heading, 'value, 'node) item =
  | Node of 'node Provenance.located
  | Child of ('heading, 'value, 'node) tree

(* A card governs the headings after it until one at its level or above.
   Section headings stay in the card; card headings below it nest. *)
let trees ~file identities (outline : _ outline) ~stop =
  let heads = Array.of_list outline.headings in
  let count = Array.length heads in
  let ids = Array.map (fun h -> Identity_rules.read identities h.identity) heads in
  let errors =
    Array.to_list ids |> List.concat_map (function Rules.Invalid e -> e | _ -> [])
  in
  let governs i bound =
    let rec next j =
      if j >= count || heads.(j).start >= bound then bound
      else if heads.(j).level <= heads.(i).level then heads.(j).start
      else next (j + 1)
    in
    next (i + 1)
  in
  let span start stop = { Provenance.file; start; stop } in
  (* Cards with their index, in [from, bound), with nothing between them and the caller. *)
  let rec cards i bound acc =
    if i >= count || heads.(i).start >= bound then List.rev acc
    else
      match ids.(i) with
      | Rules.Matched id ->
          let stop = governs i bound in
          let rec skip j = if j < count && heads.(j).start < stop then skip (j + 1) else j in
          cards (skip (i + 1)) bound (tree i id stop :: acc)
      | _ -> cards (i + 1) bound acc
  and tree i id stop =
    let head = heads.(i) in
    let children = cards (i + 1) stop [] in
    let inside (n : _ Provenance.located) =
      let at = start_of n in
      at >= head.body_start && at < stop
      && not (List.exists (fun c -> at >= c.extent.start && at < c.extent.stop) children)
    in
    let own = List.filter inside outline.nodes |> List.map (fun n -> start_of n, Node n) in
    let nested = List.map (fun c -> c.extent.start, Child c) children in
    let items =
      List.stable_sort (fun (a, _) (b, _) -> compare a b) (own @ nested) |> List.map snd
    in
    { head; id; extent = span head.start stop; items }
  in
  let roots = cards 0 stop [] in
  match errors with [] -> Ok roots | _ -> Error errors

(* {1 The adapter} *)

let metadata_fields frontend =
  match Syntax.Frontend_input.metadata_shape frontend with
  | Schema.Record fields -> Ok fields
  | _ -> Error [ invalid "the metadata schema must describe a record" ]

(* The field that declared the ID is structure, not metadata. *)
let without_identity (id : _ Provenance.located) fields =
  let covers (field : _ Payload_rules.field) =
    match field.value.span, id.span with
    | Some (f : Provenance.span), Some (i : Provenance.span) ->
        f.file = i.file && f.start <= i.start && i.stop <= f.stop
    | _ -> false
  in
  List.filter (fun field -> not (covers field)) fields

(* Undeclared fields are dropped before reading, so they are never reported. *)
let declared_only schema fields =
  List.filter (fun (field : _ Payload_rules.field) ->
    List.exists (fun (s : Schema.field) -> s.name = field.name.value) schema) fields

let adapter lang ?(unknown_metadata = `Report) ~values ~identities ~actions ~define frontend =
  let reader = Payload_rules.reader values in
  let named = named frontend reader in
  let parse ~file text outline =
    Result.bind outline (fun outline -> trees ~file identities outline ~stop:(String.length text))
  in
  let note text tree =
    let slice (s : Provenance.span) =
      Provenance.located ~span:s
        { Text.text = String.sub text s.start (s.stop - s.start); language = lang.language }
    in
    let context = { level = tree.head.level; slice; values = reader; named } in
    (* A node no rule takes is read through its children. *)
    let rec expand items =
      List.concat_map (fun item ->
        let node =
          match item with
          | Node n -> n
          | Child c ->
              Provenance.located ~span:c.extent
                (lang.nested { level = c.head.level; extent = c.extent })
        in
        match Action_rules.read actions context node, item with
        | Rules.No_match, Node n -> expand (List.map (fun c -> Node c) (lang.children n.value))
        | Rules.No_match, Child c -> expand c.items
        | _ -> [ node ])
        items
    in
    let metadata =
      Result.bind (metadata_fields frontend) (fun schema ->
        let fields = without_identity tree.id tree.head.metadata in
        let fields =
          match unknown_metadata with `Ignore -> declared_only schema fields | `Report -> fields
        in
        Payload_rules.read_metadata reader schema fields)
    in
    let body_span = { tree.extent with start = tree.head.body_start } in
    let body =
      Action_rules.body actions context
        ~source:{ Text.text; language = lang.language } body_span (expand tree.items)
    in
    match metadata, body with
    | Ok fields, Ok body ->
        Ok (Provenance.located ~span:tree.extent
          { Observation.Source.id = tree.id.value;
            title = slice tree.head.title;
            metadata =
              Provenance.located ?span:tree.head.metadata_span (Payload.Record fields);
            body = Provenance.located ~span:body_span body })
    | metadata, body ->
        let errors = function Error e -> e | Ok _ -> [] in
        Error (errors metadata @ errors body)
  in
  (* Contents are read in place: the text is padded so spans stay file offsets. *)
  let card (contents : Text.t Provenance.located) =
    let file, base =
      match contents.span with Some s -> s.file, s.start | None -> "", 0
    in
    let text = String.make base ' ' ^ contents.value.text in
    match parse ~file text (lang.read ~file text ~start:base) with
    | Error _ as error -> error
    | Ok [ tree ] -> Result.map (fun n -> n, tree.id) (note text tree)
    | Ok [] -> Error [ invalid ?span:contents.span "these Contents declare no card" ]
    | Ok _ -> Error [ invalid ?span:contents.span "these Contents declare more than one card" ]
  in
  (* Every card a define call would produce, read from its Contents, deepest
     included. The same reading backs [contents] during expansion. *)
  let rec declared (note : Syntax.raw_note Provenance.located) =
    let defined = function
      | { Provenance.value = Observation.Source.Action (call : Invocation.t); _ }
        when call.name.value = define ->
          List.filter_map (fun (field : Payload.field) ->
            match field.value.value with
            | Contents t when Text.Language.equal t.language lang.language ->
                Some (Provenance.located ?span:field.value.span t)
            | _ -> None) call.arguments
      | _ -> []
    in
    List.concat_map defined note.value.body.value
    |> List.map (fun contents ->
         Result.bind (card contents) (fun (child, id) ->
           Result.map (fun below -> id :: below) (declared child)))
    |> collect |> Result.map List.concat
  in
  let extract (document : _ Syntax.document) =
    let text = lang.source document.native in
    match parse ~file:document.file text (lang.scan ~file:document.file document.native) with
    | Error _ as error -> error
    | Ok roots ->
        Result.bind (collect (List.map (note text) roots)) (fun notes ->
          Result.map (fun declared -> { Syntax.notes; declared = List.concat declared })
            (collect (List.map declared notes)))
  in
  { Syntax.language = lang.language; extract; contents = (fun c -> Result.map fst (card c)) }

let nested_card project action make rules =
  Action_rules.bind ~sugar:"nested-card" action (fun node (context : _ context) ->
    match project node.Provenance.value with
    | None -> Rules.No_match
    | Some (card : nested) ->
        let contents = context.slice card.extent in
        let depth = Provenance.located ?span:None (card.level - context.level) in
        Rules.Matched (make ~contents ~depth))
    rules
