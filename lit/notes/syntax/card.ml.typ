#import "/reader/book.typ": card-source, chunk
#show: card-source

= card.ml <syntax:card.ml>

#chunk(id: <source-syntax-card-ml>)[
```ocaml
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
  metadata : 'value Payload_rules.field list Frontend.read;
  metadata_span : Provenance.span option;
  start : int;
  body_start : int;
}

type ('heading, 'value, 'node) outline = {
  headings : ('heading, 'value) heading list;
  nodes : 'node Provenance.located list;
  closes : int list;
}

type ('native, 'heading, 'value, 'node) language = {
  language : Text.Language.t;
  source : 'native -> string;
  scan : file:string -> 'native -> ('heading, 'value, 'node) outline;
  read : file:string -> string -> start:int -> ('heading, 'value, 'node) outline;
  nested : nested -> 'node;
  children : 'node -> 'node Provenance.located list;
}

let invalid ?span message = Diagnostic.make ?span (Invalid message)

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
  heading : 'node Provenance.located list;  (** Nodes in the title, such as references. *)
  items : ('heading, 'value, 'node) item list;
}

and ('heading, 'value, 'node) item =
  | Node of 'node Provenance.located
  | Child of ('heading, 'value, 'node) tree
  | Unreadable of Diagnostic.t list Provenance.located
      (** A heading that tried to declare a card and failed. *)

(* A card governs the headings after it until one at its level or above.
   Section headings stay in the card; card headings below it nest. A heading
   whose identity is invalid is a section, and its diagnostics belong to the
   innermost card around it. Returns the roots and the diagnostics outside
   every card. *)
let trees ~file identities (outline : _ outline) ~stop =
  let heads = Array.of_list outline.headings in
  let count = Array.length heads in
  let ids = Array.map (fun h -> Identity_rules.read identities h.identity) heads in
  let invalid =
    List.filter_map (fun i ->
      match ids.(i) with
      | Rules.Invalid found ->
          let span = heads.(i).identity.span in
          let found = List.map (Diagnostic.with_fallback_span span) found in
          Some (heads.(i).start, Provenance.located ?span found)
      | Rules.No_match | Rules.Matched _ -> None)
      (List.init count Fun.id)
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
          let card = tree i id (governs i bound) in
          let stop = card.extent.stop in
          let rec skip j = if j < count && heads.(j).start < stop then skip (j + 1) else j in
          cards (skip (i + 1)) bound (card :: acc)
      | _ -> cards (i + 1) bound acc
  (* An explicit close ends the innermost open card; the closes of its
     children, each at a child's end, are theirs. *)
  and tree i id stop =
    let head = heads.(i) in
    let children = cards (i + 1) stop [] in
    let claimed at = List.exists (fun c -> at >= c.extent.start && at <= c.extent.stop) children in
    let stop, children =
      match List.find_opt (fun at -> at >= head.body_start && at < stop && not (claimed at)) outline.closes with
      | None -> stop, children
      | Some close -> close, cards (i + 1) close []
    in
    let own at =
      at >= head.body_start && at < stop
      && not (List.exists (fun c -> at >= c.extent.start && at < c.extent.stop) children)
    in
    let nodes =
      List.filter (fun n -> own (start_of n)) outline.nodes |> List.map (fun n -> start_of n, Node n)
    in
    let failures =
      List.filter_map (fun (at, found) -> if own at then Some (at, Unreadable found) else None) invalid
    in
    let nested = List.map (fun c -> c.extent.start, Child c) children in
    let items =
      List.stable_sort (fun (a, _) (b, _) -> compare a b) (nodes @ failures @ nested)
      |> List.map snd
    in
    let heading =
      List.filter (fun n ->
        let at = start_of n in at >= head.title.start && at < head.title.stop) outline.nodes
    in
    { head; id; extent = span head.start stop; heading; items }
  in
  let roots = cards 0 stop [] in
  let outside at = not (List.exists (fun r -> at >= r.extent.start && at < r.extent.stop) roots) in
  let unowned =
    List.concat_map (fun (at, (found : _ Provenance.located)) ->
      if outside at then found.value else []) invalid
  in
  roots, unowned

(* {1 The adapter} *)


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
  let rec declared schema name =
    match String.index_opt name '.' with
    | None -> List.exists (fun (s : Schema.field) -> s.name = name) schema
    | Some dot ->
        List.exists (fun (s : Schema.field) ->
          match s.shape with
          | Record fields when s.name = String.sub name 0 dot ->
              declared fields (String.sub name (dot + 1) (String.length name - dot - 1))
          | _ -> false) schema
  in
  List.filter (fun (field : _ Payload_rules.field) -> declared schema field.name.value) fields

let adapter lang ?(unknown_metadata = `Report) ~values ~identities ~actions ~define frontend =
  let schema =
    match Syntax.Frontend_input.metadata_shape frontend with
    | Schema.Record fields -> fields
    | _ -> invalid_arg "Card.adapter: the metadata schema must describe a record"
  in
  let reader = Payload_rules.reader values in
  let named = named frontend reader in
  let parse ~file text outline = trees ~file identities outline ~stop:(String.length text) in
  let note text tree =
    let slice (s : Provenance.span) =
      Provenance.located ~span:s
        { Text.text = String.sub text s.start (s.stop - s.start); language = lang.language }
    in
    let context = { level = tree.head.level; slice; values = reader; named } in
    (* A node no rule takes is read through its children. *)
    let rec nodes items =
      List.concat_map (function
        | Unreadable found -> [ Provenance.map (fun found -> Error found) found ]
        | Node n as item -> read_or_children item n
        | Child c as item ->
            read_or_children item
              (Provenance.located ~span:c.extent
                 (lang.nested { level = c.head.level; extent = c.extent })))
        items
    and read_or_children item node =
      match Action_rules.read actions context node, item with
      | Rules.No_match, Node n -> nodes (List.map (fun c -> Node c) (lang.children n.value))
      | Rules.No_match, Child c -> nodes c.items
      | _ -> [ Provenance.map Result.ok node ]
    in
    let metadata =
      Result.bind tree.head.metadata (fun fields ->
        let fields = without_identity tree.id fields in
        let fields =
          match unknown_metadata with `Ignore -> declared_only schema fields | `Report -> fields
        in
        Payload_rules.read_metadata reader schema fields)
      |> Result.map (fun fields -> Payload.Record fields)
    in
    (* Actions written in the title belong to the card. They precede the body,
       located where they are written; the title keeps its text. *)
    let heading =
      nodes (List.map (fun n -> Node n) tree.heading)
      |> List.filter_map (fun (n : _ Provenance.located) ->
          let action read = Some (Provenance.located ?span:n.span (Observation.Source.Action read)) in
          match n.value with
          | Error found -> action (Error found)
          | Ok node -> (
              match Action_rules.read actions context { n with value = node } with
              | Rules.Matched { call; _ } -> action (Ok call.value)
              | Rules.Invalid found -> action (Error found)
              | Rules.No_match -> None))
    in
    let body_span = { tree.extent with start = tree.head.body_start } in
    let body =
      heading
      @ Action_rules.body actions context
          ~source:{ Text.text; language = lang.language } body_span (nodes tree.items)
    in
    Provenance.located ~span:tree.extent
      { Observation.Source.id = tree.id;
        title = slice tree.head.title;
        metadata = Provenance.located ?span:tree.head.metadata_span metadata;
        body = Provenance.located ~span:body_span body }
  in
  (* Contents are read in place: the text is padded so spans stay file offsets.
     Diagnostics outside the card matter only when no card is found. *)
  let card (contents : Text.t Provenance.located) =
    let file, base =
      match contents.span with Some s -> s.file, s.start | None -> "", 0
    in
    (* Newlines keep the padding out of the first line. *)
    let text = String.make base '\n' ^ contents.value.text in
    match parse ~file text (lang.read ~file text ~start:base) with
    | [ tree ], _ -> Ok (note text tree, tree.id)
    | [], (_ :: _ as unowned) -> Error unowned
    | [], [] -> Error [ invalid ?span:contents.span "these Contents declare no card" ]
    | _ -> Error [ invalid ?span:contents.span "these Contents declare more than one card" ]
  in
  (* Every card a define call would produce, read from its Contents, deepest
     included. The same reading backs [contents] during expansion, which
     reports Contents that define no card; here they only contribute no ID. *)
  let rec declared (note : Syntax.raw_note Provenance.located) =
    let defined = function
      | { Provenance.value = Observation.Source.Action (Ok (call : Invocation.t)); _ }
        when call.name.value = define ->
          List.filter_map (fun (field : Payload.field) ->
            match field.value.value with
            | Contents t when Text.Language.equal t.language lang.language ->
                Some (Provenance.located ?span:field.value.span t)
            | _ -> None) call.arguments
      | _ -> []
    in
    List.concat_map defined note.value.body.value
    |> List.concat_map (fun contents ->
         match card contents with
         | Ok (child, id) -> id :: declared child
         | Error _ -> [])
  in
  let extract (document : _ Syntax.document) =
    let text = lang.source document.native in
    let roots, diagnostics = parse ~file:document.file text (lang.scan ~file:document.file document.native) in
    let notes = List.map (note text) roots in
    { Syntax.notes; declared = List.concat_map declared notes; diagnostics }
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
```
]

#chunk(id: <file-syntax-card-ml>, target: "syntax/card.ml")[
```ocaml
<<source-syntax-card-ml>>
```
]
