module Invocation_id = struct
  type t = string

  let of_string value =
    if value = "" then Error "Invocation ID must not be empty"
    else Ok value

  let to_string value = value
  let compare = String.compare
end

type 'issue error =
  | Failure of {
      invocation : Invocation_id.t;
      issues : 'issue list;
    }
  | Blocked of {
      invocation : Invocation_id.t;
      dependencies : Invocation_id.t list;
    }

type ('vertex, 'edge, 'issue) outcome =
  | Success of ('vertex, 'edge) Graph.t
  | Error of 'issue error

type ('vertex, 'edge) assignment = {
  vertex : Graph.Vertex_id.t -> 'vertex;
  edge : Graph.Edge_id.t -> 'edge;
}

type (_, 'vertex, 'edge) ports =
  | Nil : (unit, 'vertex, 'edge) ports
  | Cons :
      ('p, 'vertex, 'edge) ports ->
      (('vertex, 'edge) Graph.t * 'p, 'vertex, 'edge) ports

type ('vertex, 'edge, 'issue) t = {
  arity : int;
  check : ('vertex, 'edge) Graph.t list -> 'issue list;
  run : ('vertex, 'edge) Graph.t list -> ('vertex, 'edge) assignment;
}

type ('vertex, 'edge, 'issue) invocation = {
  id : Invocation_id.t;
  inputs : Invocation_id.t list;
  definition : ('vertex, 'edge, 'issue) t;
}

let invocation id definition ~inputs =
  { id; definition; inputs }

let rec port_count : type p v e. (p, v, e) ports -> int = function
  | Nil -> 0
  | Cons rest -> 1 + port_count rest

let rec decode_ports : type p v e. (p, v, e) ports -> (v, e) Graph.t list -> p =
  fun ports states ->
    match ports, states with
    | Nil, [] -> ()
    | Cons rest, state :: states -> state, decode_ports rest states
    | _ -> invalid_arg "Policy input count mismatch"

let make ports ?(check = fun _ -> []) run =
  {
    arity = port_count ports;
    check = (fun states -> check (decode_ports ports states));
    run = (fun states -> run (decode_ports ports states));
  }

let lift ~initial ~id definition =
  Clone.operation definition.arity (fun inputs ->
    let states, dependencies =
      List.fold_left
        (fun (states, dependencies) -> function
          | Success state -> state :: states, dependencies
          | Error (Failure { invocation; _ })
          | Error (Blocked { invocation; _ }) ->
              states, invocation :: dependencies)
        ([], []) inputs
    in
    match dependencies with
    | _ :: _ ->
        Error (Blocked {
          invocation = id;
          dependencies = List.sort_uniq Invocation_id.compare dependencies;
        })
    | [] ->
        let states = List.rev states in
        match definition.check states with
        | _ :: _ as issues -> Error (Failure { invocation = id; issues })
        | [] ->
            let assignment = definition.run states in
            Success (Graph.map initial
              ~vertex:(fun vertex -> assignment.vertex vertex.id)
              ~edge:(fun edge -> assignment.edge edge.id)))
