#import "/reader/book.typ": chunk

= frontend.ml <core:src:frontend.ml>

#chunk(id: <source-core-src-frontend-ml>)[
```ocaml
module Payload = struct
  type t = value Provenance.located

  and value =
    | String of string
    | Bool of bool
    | Int of int
    | List of t list
    | Record of field list
    | Contents of Text.t

  and field = {
    name : string Provenance.located;
    value : t;
  }

  module Kind_type = struct
    type t = String | Bool | Int | List | Record | Contents
  end

  let kind_of : value -> Kind_type.t = function
    | String _ -> Kind_type.String
    | Bool _ -> Kind_type.Bool
    | Int _ -> Kind_type.Int
    | List _ -> Kind_type.List
    | Record _ -> Kind_type.Record
    | Contents _ -> Kind_type.Contents

  module Kind = struct
    include Kind_type

    let of_value = kind_of
  end
end

module Invocation = struct
  type t = {
    name : string Provenance.located;
    arguments : Payload.field list;
  }
end

module Diagnostic = struct
  type segment =
    | Field of string
    | Index of int

  type problem =
    | Type_mismatch of { expected : Payload.Kind.t; given : Payload.Kind.t }
    | Missing_field of string
    | Unknown_field of { name : string; known : string list }
    | Duplicate_field of string
    | Invalid_choice of { given : string; choices : string list }
    | Unknown_action of { name : string; known : string list }
    | Invalid of string
    | Missing_identity of { insertion : Provenance.span option; prefix : string; suffix : string }

  type t = {
    problem : problem;
    path : segment list;
    span : Provenance.span option;
  }

  let make ?(path = []) ?span problem = { problem; path; span }

  let with_fallback_span span diagnostic =
    match diagnostic.span, span with
    | None, Some _ -> { diagnostic with span }
    | _ -> diagnostic
end

module type DECODING = sig
  type metadata
  type action

  val decode_metadata :
    Payload.t -> (metadata, Diagnostic.t list) result

  val decode_action :
    Invocation.t -> (action, Diagnostic.t list) result
end

type 'a read = ('a, Diagnostic.t list) result
type raw_note = (Payload.value read, Invocation.t read) Observation.Source.note
type raw_project = (Payload.value read, Invocation.t read) Observation.project

type 'a decoded = ('a, Diagnostic.t list) result

type action_failure =
  | Unread of Diagnostic.t list
  | Undecoded of Invocation.t * Diagnostic.t list

type 'a decoded_action = ('a, action_failure) result

type 'error failure =
  | Metadata_decode of Diagnostic.t list
  | Action_decode of action_failure
  | Interpretation of 'error

module type DECODER = sig
  type metadata
  type action

  val decode_source :
    raw_note Provenance.located ->
    (metadata decoded, action decoded_action) Observation.Source.note Provenance.located

  val decode_project :
    raw_project -> (metadata decoded, action decoded_action) Observation.project
end

module Decode (Rules : DECODING) = struct
  type metadata = Rules.metadata
  type action = Rules.action

  let decode_content (content : _ Provenance.located) =
    match content.value with
    | Observation.Source.Text text ->
        { content with value = Observation.Source.Text text }
    | Observation.Source.Action read ->
        let locate = List.map (Diagnostic.with_fallback_span content.span) in
        let decoded = match read with
          | Error diagnostics -> Error (Unread (locate diagnostics))
          | Ok invocation ->
              Rules.decode_action invocation
              |> Result.map_error (fun diagnostics -> Undecoded (invocation, locate diagnostics))
        in
        { content with value = Observation.Source.Action decoded }

  let decode_source (located : _ Observation.Source.note Provenance.located) =
    let note = located.value in
    let metadata_span =
      match note.metadata.span with
      | Some _ as span -> span
      | None -> note.title.span
    in
    let metadata =
      Result.bind note.metadata.value (fun value ->
        Rules.decode_metadata { note.metadata with value })
      |> Result.map_error (List.map (Diagnostic.with_fallback_span metadata_span))
    in
    { located with value =
      { Observation.Source.id = note.id;
        title = note.title;
        metadata = { note.metadata with value = metadata };
        body = { note.body with value = List.map decode_content note.body.value } } }

  let decode_project (project : (_, _) Observation.project) =
    { project with notes = List.map decode_source project.notes }
end

module type FRONTEND = sig
  include DECODER

  type relation
  type consumption
  type error

  val interpret :
    action ->
    (metadata decoded, relation, action decoded_action, consumption, error)
      Observation.contribution list
end

module Make (Frontend : FRONTEND) = struct
  let observe project =
    let interpret = function
      | Error failure -> [Observation.Fail (Action_decode failure)]
      | Ok action -> List.map (function
          | Observation.Define note -> Observation.Define note
          | Observation.Relate { target; relation } -> Observation.Relate { target; relation }
          | Observation.Emit content -> Observation.Emit content
          | Observation.Fail error -> Observation.Fail (Interpretation error))
          (Frontend.interpret action)
    in
    let metadata_errors = function
      | Ok _ -> []
      | Error diagnostics -> [Metadata_decode diagnostics]
    in
    let declarations, issues =
      Observation.expand ~metadata_errors ~interpret (Frontend.decode_project project)
    in
    Observation.assemble ~issues declarations
end
```
]

#chunk(id: <file-core-src-frontend-ml>, target: "core/src/frontend.ml")[
```ocaml
<<source-core-src-frontend-ml>>
```
]
