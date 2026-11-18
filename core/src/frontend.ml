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

  type t = {
    problem : problem;
    path : segment list;
    span : Provenance.span option;
  }

  let make ?(path = []) ?span problem = { problem; path; span }
end

module type DECODING = sig
  type metadata
  type action

  val decode_metadata :
    Payload.t -> (metadata, Diagnostic.t list) result

  val decode_action :
    Invocation.t -> (action, Diagnostic.t list) result
end

module type DECODER = sig
  type metadata
  type action

  val decode_source :
    (Payload.value, Invocation.t) Observation.Source.note Provenance.located ->
    ((metadata, action) Observation.Source.note Provenance.located,
     Diagnostic.t list) result

  val decode_project :
    (Payload.value, Invocation.t) Observation.project ->
    ((metadata, action) Observation.project, Diagnostic.t list) result
end

(* Map in order, collecting every failure instead of stopping at the first. *)
let collect f items =
  let values, errors =
    List.fold_left
      (fun (values, errors) item ->
        match f item with
        | Ok value -> (value :: values, errors)
        | Error found -> (values, List.rev_append found errors))
      ([], []) items
  in
  match errors with
  | [] -> Ok (List.rev values)
  | _ :: _ -> Error (List.rev errors)

module Decode (Rules : DECODING) = struct
  type metadata = Rules.metadata
  type action = Rules.action

  let decode_content (content : _ Provenance.located) =
    match content.value with
    | Observation.Source.Text text ->
        Ok { content with value = Observation.Source.Text text }
    | Observation.Source.Action invocation ->
        Result.map
          (fun action -> { content with value = Observation.Source.Action action })
          (Rules.decode_action invocation)

  let decode_source (located : _ Observation.Source.note Provenance.located) =
    let note = located.value in
    let metadata = Rules.decode_metadata note.metadata in
    let body = collect decode_content note.body.value in
    match metadata, body with
    | Ok metadata, Ok body ->
        Ok { located with value =
          { Observation.Source.id = note.id;
            title = note.title;
            metadata = { note.metadata with value = metadata };
            body = { note.body with value = body } } }
    | Error metadata, Error body -> Error (metadata @ body)
    | Error errors, Ok _ | Ok _, Error errors -> Error errors

  let decode_project (project : (_, _) Observation.project) =
    Result.map
      (fun notes -> { Observation.identities = project.identities; notes })
      (collect decode_source project.notes)
end

module type FRONTEND = sig
  include DECODER

  type relation
  type consumption
  type error

  val interpret :
    (metadata, relation, action, consumption, error) Observation.interpreter
end

module Make (Frontend : FRONTEND) = struct
  type error =
    | Decode of Diagnostic.t list
    | Observe of Frontend.error Observation.issue list

  let observe project =
    match Frontend.decode_project project with
    | Error diagnostics -> Error (Decode diagnostics)
    | Ok project ->
        match Observation.expand ~interpret:Frontend.interpret project with
        | Error issues -> Error (Observe issues)
        | Ok declarations ->
            Result.map_error (fun issues -> Observe issues)
              (Observation.assemble declarations)
end
