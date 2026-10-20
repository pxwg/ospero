(** The OCaml value produced when a DSL argument is checked. *)
type _ argument =
  | Reference : Graph.Vertex_id.t argument
  | String : string argument

(** Positional arguments decode into nested pairs ending in unit. *)
type _ arguments =
  | Nil : unit arguments
  | Cons : 'a argument * 'b arguments -> ('a * 'b) arguments

type ('action, _) body =
  | Forbidden : ('action, unit) body
  | Optional : ('action, 'action Observation.Source.content list option) body
  | Required : ('action, 'action Observation.Source.content list) body

(** A deferred call whose generated notes may contain more deferred calls. *)
type ('metadata, 'relation, 'consumption, 'error) action =
  | Action of
      ('metadata Observation.context ->
       (('metadata, 'relation,
         ('metadata, 'relation, 'consumption, 'error) action, 'consumption)
          Observation.contribution list,
        'error list) result)

(** Package a parameter specification with a callback accepting those values. *)
type ('metadata, 'relation, 'consumption, 'error) t =
  | Function : {
      name : string;
      arguments : 'args arguments;
      body : (('metadata, 'relation, 'consumption, 'error) action, 'body) body;
      run :
        'metadata Observation.context ->
        'args ->
        'body ->
        (('metadata, 'relation,
          ('metadata, 'relation, 'consumption, 'error) action, 'consumption)
           Observation.contribution list,
         'error list) result;
    } -> ('metadata, 'relation, 'consumption, 'error) t
  | Raw of {
      name : string;
      run :
        'metadata Observation.context ->
        string ->
        ('consumption Observation.Observed.content list, 'error list) result;
    }

let make name ~args ~body run =
  Function { name; arguments = args; body; run }

let raw name run = Raw { name; run }

let name = function
  | Function definition -> definition.name
  | Raw definition -> definition.name

type check_error = {
  range : Dsl_syntax.range;
  message : string;
}

let decode_argument : type a.
    lookup:(string -> Graph.Vertex_id.t option) ->
    a argument ->
    Dsl_syntax.argument Dsl_syntax.located ->
    (a, check_error) result =
  fun ~lookup specification supplied ->
    let error message = Error { range = supplied.range; message } in
    match specification, supplied.value with
    | Reference, Dsl_syntax.Reference name ->
        (match lookup name with
         | Some id -> Ok id
         | None -> error (Printf.sprintf "Unknown label '%s'" name))
    | String, Dsl_syntax.String value -> Ok value
    | Reference, Dsl_syntax.String _ -> error "Expected a label reference"
    | String, Dsl_syntax.Reference _ -> error "Expected a string"

(** The call range locates missing arguments; supplied arguments carry
    their own ranges for type errors and excess arguments. *)
let rec decode_arguments : type a.
    lookup:(string -> Graph.Vertex_id.t option) ->
    range:Dsl_syntax.range ->
    a arguments ->
    Dsl_syntax.argument Dsl_syntax.located list ->
    (a, check_error) result =
  fun ~lookup ~range specification supplied ->
    match specification, supplied with
    | Nil, [] -> Ok ()
    | Nil, extra :: _ ->
        Error { range = extra.range; message = "Too many arguments" }
    | Cons _, [] ->
        Error { range; message = "Missing argument" }
    | Cons (head, tail), first :: rest ->
        match decode_argument ~lookup head first with
        | Error error -> Error error
        | Ok value ->
            match decode_arguments ~lookup ~range tail rest with
            | Error error -> Error error
            | Ok values -> Ok (value, values)

(** An explicitly empty body satisfies Required. *)
let decode_body : type a b.
    range:Dsl_syntax.range ->
    (a, b) body ->
    a Observation.Source.content list option ->
    (b, check_error) result =
  fun ~range requirement supplied ->
    match requirement, supplied with
    | Forbidden, Some _ ->
        Error { range; message = "This function does not accept a body" }
    | Required, None ->
        Error { range; message = "This function requires a body" }
    | Forbidden, None -> Ok ()
    | Optional, body -> Ok body
    | Required, Some body -> Ok body

(** The body has already been recursively checked and converted to Source
    content by the caller. Preparing a call does not run its callback. *)
let prepare ~lookup ~range definition ~arguments ~body =
  match definition with
  | Raw _ ->
      Error { range; message = "Expected a function, but this name is a raw handler" }
  | Function definition ->
      match decode_body ~range definition.body body with
      | Error error -> Error error
      | Ok body ->
          match decode_arguments ~lookup ~range definition.arguments arguments with
          | Error error -> Error error
          | Ok values ->
              Ok (Action (fun context -> definition.run context values body))

let prepare_raw ~range definition ~source =
  match definition with
  | Function _ ->
      Error { range; message = "Expected a raw handler, but this name is a function" }
  | Raw definition ->
      Ok (Action (fun context ->
        Result.map
          (List.map (fun content -> Observation.Emit content))
          (definition.run context source)))

let interpret context (Action run) = run context

module Name_map = Map.Make (String)

type ('metadata, 'relation, 'consumption, 'error) registry =
  ('metadata, 'relation, 'consumption, 'error) t Name_map.t

type registration_error =
  | Duplicate_function of string

let register functions =
  let rec collect registry = function
    | [] -> Ok registry
    | definition :: rest ->
        let key = name definition in
        if Name_map.mem key registry then Error (Duplicate_function key)
        else collect (Name_map.add key definition registry) rest
  in
  collect Name_map.empty functions

(** Check every retained subtree before observation; callbacks are deferred.
    Conversion stops at the first error. *)
let rec convert_body ~lookup registry contents =
  let rec collect reversed = function
    | [] -> Ok (List.rev reversed)
    | content :: rest ->
        match convert_content ~lookup registry content with
        | Error error -> Error error
        | Ok content -> collect (content :: reversed) rest
  in
  collect [] contents

and convert_content ~lookup registry
    (content : Dsl_syntax.content Dsl_syntax.located) =
  match content.value with
  | Dsl_syntax.Text text -> Ok (Observation.Source.Text text)
  | Dsl_syntax.Raw raw ->
      (match Name_map.find_opt raw.format.value registry with
       | None ->
           Error {
             range = raw.format.range;
             message = Printf.sprintf "Unknown raw format '%s'" raw.format.value;
           }
       | Some definition ->
           Result.map (fun action -> Observation.Source.Action action)
             (prepare_raw ~range:raw.format.range definition
                ~source:raw.source.value))
  | Dsl_syntax.Action invocation ->
      match Name_map.find_opt invocation.name.value registry with
      | None ->
          Error {
            range = invocation.name.range;
            message = Printf.sprintf "Unknown function '%s'" invocation.name.value;
          }
      | Some definition ->
          let body =
            match invocation.body with
            | None -> Ok None
            | Some contents ->
                Result.map (fun contents -> Some contents)
                  (convert_body ~lookup registry contents)
          in
          match body with
          | Error error -> Error error
          | Ok body ->
              Result.map (fun action -> Observation.Source.Action action)
                (prepare ~lookup ~range:content.range definition
                   ~arguments:invocation.arguments ~body)
