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

type ('note, 'relation) t = {
  vertices : 'note vertex list;
  edges : 'relation edge list;
  vertex_index : 'note vertex Vertex_map.t;
  edge_index : 'relation edge Edge_map.t;
  incoming_index : 'relation edge list Vertex_map.t;
  outgoing_index : 'relation edge list Vertex_map.t;
}

type 'metadata note = {
  title : string;
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
            (add edge.target edge incoming, add edge.source edge outgoing))
          (empty, empty) edges
      in
      Ok {
        vertices;
        edges;
        vertex_index;
        edge_index;
        incoming_index = Vertex_map.map List.rev incoming_index;
        outgoing_index = Vertex_map.map List.rev outgoing_index;
      }
  | issues -> Error issues

let vertices graph = graph.vertices
let edges graph = graph.edges

let find_vertex graph id = Vertex_map.find_opt id graph.vertex_index
let find_edge graph id = Edge_map.find_opt id graph.edge_index

let incoming graph id = Vertex_map.find_opt id graph.incoming_index
let outgoing graph id = Vertex_map.find_opt id graph.outgoing_index
