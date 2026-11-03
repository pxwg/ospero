module type FRONTEND = sig
  type metadata
  type relation
  type consumption
  type action
  type error
  type parse_error
  type input

  val parse :
    input ->
    ((metadata, action) Observation.project, parse_error list) result

  val interpret :
    (metadata, relation, action, consumption, error) Observation.interpreter
end

module Make (Frontend : FRONTEND) = struct
  type error =
    | Parse of Frontend.parse_error list
    | Observe of Frontend.error Observation.issue list

  let observe input =
    match Frontend.parse input with
    | Error errors -> Error (Parse errors)
    | Ok project ->
        match Observation.expand ~interpret:Frontend.interpret project with
        | Error issues -> Error (Observe issues)
        | Ok declarations ->
            Result.map_error (fun issues -> Observe issues)
              (Observation.assemble declarations)
end
