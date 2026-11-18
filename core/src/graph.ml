module Vertex_id = struct
  type t = string

  let of_string value =
    if value = "" then Error "Vertex ID must not be empty"
    else Ok value

  let to_string value = value
  let compare = String.compare
end

module Edge_id = struct
  type t = string

  let of_string value =
    if value = "" then Error "Edge ID must not be empty"
    else Ok value

  let to_string value = value
  let compare = String.compare
end

type 'note vertex = {
  id : Vertex_id.t;
  note : 'note;
}

type 'relation edge = {
  id : Edge_id.t;
  source : Vertex_id.t;
  target : Vertex_id.t;
  relation : 'relation;
}

module Vertex_map = Map.Make (Vertex_id)
module Edge_map = Map.Make (Edge_id)

type topology = {
  vertices : Vertex_id.t list;
  edges : Edge_id.t list;
  endpoints : (Vertex_id.t * Vertex_id.t) Edge_map.t;
  incoming : Edge_id.t list Vertex_map.t;
  outgoing : Edge_id.t list Vertex_map.t;
}

type ('note, 'relation) values = {
  vertices : 'note Vertex_map.t;
  edges : 'relation Edge_map.t;
}

type ('note, 'relation) t = {
  topology : topology;
  values : ('note, 'relation) values;
}

type 'metadata note = {
  title : Text.t;
  metadata : 'metadata;
}

type ('metadata, 'relation) knowledge_graph =
  ('metadata note, 'relation) t

type endpoint = Source | Target

type issue =
  | Duplicate_vertex of Vertex_id.t
  | Duplicate_edge of Edge_id.t
  | Missing_endpoint of Edge_id.t * endpoint * Vertex_id.t

let assemble vertices edges =
  (* Keep the first declaration of each identity for validation.
     These indexes are exposed only if all checks succeed. *)
  let vertex_index, issues =
    List.fold_left
      (fun (index, issues) (vertex : _ vertex) ->
        if Vertex_map.mem vertex.id index then
          (index, Duplicate_vertex vertex.id :: issues)
        else
          (Vertex_map.add vertex.id vertex index, issues))
      (Vertex_map.empty, []) vertices
  in
  let edge_index, issues =
    List.fold_left
      (fun (index, issues) (edge : _ edge) ->
        if Edge_map.mem edge.id index then
          (index, Duplicate_edge edge.id :: issues)
        else
          (Edge_map.add edge.id edge index, issues))
      (Edge_map.empty, issues) edges
  in
  let check_endpoint edge_id endpoint vertex_id issues =
    if Vertex_map.mem vertex_id vertex_index then issues
    else Missing_endpoint (edge_id, endpoint, vertex_id) :: issues
  in
  let issues =
    List.fold_left
      (fun issues (edge : _ edge) ->
        let issues = check_endpoint edge.id Source edge.source issues in
        check_endpoint edge.id Target edge.target issues)
      issues edges
  in
  match List.rev issues with
  | [] ->
      (* Include isolated vertices, so absence means an unknown vertex.
         Prepend while collecting, then reverse each list to restore input order. *)
      let empty = Vertex_map.map (fun _ -> []) vertex_index in
      let add id edge index =
        Vertex_map.add id (edge :: Vertex_map.find id index) index
      in
      let incoming_index, outgoing_index =
        List.fold_left
          (fun (incoming, outgoing) (edge : _ edge) ->
            (add edge.target edge.id incoming, add edge.source edge.id outgoing))
          (empty, empty) edges
      in
      Ok {
        topology = {
          vertices = List.map (fun (vertex : _ vertex) -> vertex.id) vertices;
          edges = List.map (fun (edge : _ edge) -> edge.id) edges;
          endpoints =
            Edge_map.map (fun (edge : _ edge) -> edge.source, edge.target) edge_index;
          incoming = Vertex_map.map List.rev incoming_index;
          outgoing = Vertex_map.map List.rev outgoing_index;
        };
        values = {
          vertices = Vertex_map.map (fun (vertex : _ vertex) -> vertex.note) vertex_index;
          edges = Edge_map.map (fun (edge : _ edge) -> edge.relation) edge_index;
        };
      }
  | issues -> Error issues

let vertex graph id =
  { id; note = Vertex_map.find id graph.values.vertices }

let edge graph id =
  let source, target = Edge_map.find id graph.topology.endpoints in
  { id; source; target; relation = Edge_map.find id graph.values.edges }

let map ~vertex:map_vertex ~edge:map_edge graph =
  let vertices =
    List.fold_left
      (fun values id ->
        Vertex_map.add id (map_vertex (vertex graph id)) values)
      Vertex_map.empty graph.topology.vertices
  in
  let edges =
    List.fold_left
      (fun values id ->
        Edge_map.add id (map_edge (edge graph id)) values)
      Edge_map.empty graph.topology.edges
  in
  { topology = graph.topology; values = { vertices; edges } }

let vertices graph = List.map (vertex graph) graph.topology.vertices
let edges graph = List.map (edge graph) graph.topology.edges

let find_vertex graph id =
  Option.map (fun note -> { id; note })
    (Vertex_map.find_opt id graph.values.vertices)

let find_edge graph id =
  Option.map
    (fun (source, target) ->
      { id; source; target; relation = Edge_map.find id graph.values.edges })
    (Edge_map.find_opt id graph.topology.endpoints)

let incoming graph id =
  Option.map (List.map (edge graph))
    (Vertex_map.find_opt id graph.topology.incoming)

let outgoing graph id =
  Option.map (List.map (edge graph))
    (Vertex_map.find_opt id graph.topology.outgoing)
