(** Deterministic occurrence IDs from pre-defined policies.
    The index counts Relate contributions within one source note, from zero. *)
let make ~source ~index =
  if index < 0 then invalid_arg "Observation_edge_id.make: negative index";
  let source = Graph.Vertex_id.to_string source in
  let encoded =
    Printf.sprintf "%d:%s:%d" (String.length source) source index
  in
  match Graph.Edge_id.of_string encoded with
  | Ok id -> id
  | Error message -> invalid_arg message
