module Source = struct
  type 'action content =
    | Text of string
    | Action of 'action

  type ('metadata, 'action) note = {
    id : Graph.Vertex_id.t;
    title : string;
    metadata : 'metadata;
    body : 'action content list;
  }
end

type ('metadata, 'action) project = {
  identities : Graph.Vertex_id.t list;
  notes : ('metadata, 'action) Source.note list;
}

module Observed = struct
  type 'consumption content =
    | Text of string
    | Consume of 'consumption
end

type 'metadata context = {
  current : Graph.Vertex_id.t;
  is_registered : Graph.Vertex_id.t -> bool;
  lookup :
    Graph.Vertex_id.t ->
    'metadata Graph.note Graph.vertex option;
}

type ('metadata, 'relation, 'action, 'consumption) contribution =
  | Define of ('metadata, 'action) Source.note
  | Relate of {
      target : Graph.Vertex_id.t;
      relation : 'relation;
    }
  | Emit of 'consumption Observed.content

type ('metadata, 'relation, 'action, 'consumption, 'error) interpreter =
  'metadata context ->
  'action ->
  (('metadata, 'relation, 'action, 'consumption) contribution list,
   'error list) result

type ('metadata, 'relation, 'consumption) declarations = {
  vertices : 'metadata Graph.note Graph.vertex list;
  edges : 'relation Graph.edge list;
  bodies :
    (Graph.Vertex_id.t * 'consumption Observed.content list) list;
}

type 'error issue =
  | Unregistered_definition of Graph.Vertex_id.t
  | Duplicate_definition of Graph.Vertex_id.t
  | Action_error of Graph.Vertex_id.t * 'error
  | Graph_issue of Graph.issue
  | Missing_body of Graph.Vertex_id.t
  | Duplicate_body of Graph.Vertex_id.t
  | Unknown_body_vertex of Graph.Vertex_id.t

module Vertex_set = Set.Make (Graph.Vertex_id)
module Vertex_map = Map.Make (Graph.Vertex_id)

type ('metadata, 'relation, 'consumption) t = {
  graph : ('metadata, 'relation) Graph.knowledge_graph;
  bodies : 'consumption Observed.content list Vertex_map.t;
}

let graph result = result.graph
let body result id = Vertex_map.find_opt id result.bodies

let vertex_of_note (note : (_, _) Source.note) =
  { Graph.id = note.id;
    note = { Graph.title = note.title; metadata = note.metadata } }

let expand ~interpret project =
  let identities = Vertex_set.of_list project.identities in
  let is_registered id = Vertex_set.mem id identities in
  let definitions = ref Vertex_set.empty in
  let pending = Queue.create () in
  let issues = ref [] in
  let report issue = issues := issue :: !issues in
  let register (note : (_, _) Source.note) =
    let registered = is_registered note.id in
    let duplicate = Vertex_set.mem note.id !definitions in
    if not registered then report (Unregistered_definition note.id);
    if duplicate then report (Duplicate_definition note.id);
    definitions := Vertex_set.add note.id !definitions;
    if registered && not duplicate then Queue.add note pending
  in
  List.iter register project.notes;
  match List.rev !issues with
  | _ :: _ as errors -> Error errors
  | [] ->
      let snapshot =
        List.fold_left
          (fun index note ->
            let vertex = vertex_of_note note in
            Vertex_map.add vertex.id vertex index)
          Vertex_map.empty project.notes
      in
      let lookup id = Vertex_map.find_opt id snapshot in
      let vertices = ref [] in
      let edges = ref [] in
      let bodies = ref [] in
      let action_failed = ref false in
      (* Initial notes run first; generated definitions join the FIFO queue.
         Accumulators are reversed once to preserve observation order. *)
      while not (Queue.is_empty pending) do
        let note = Queue.take pending in
        let context = { current = note.id; is_registered; lookup } in
        let contents = ref [] in
        let edge_index = ref 0 in
        let emit content = contents := content :: !contents in
        let contribute = function
          | Define definition -> register definition
          | Relate { target; relation } ->
              let id =
                Observation_edge_id.make ~source:note.id ~index:!edge_index
              in
              incr edge_index;
              edges :=
                { Graph.id; source = note.id; target; relation } :: !edges
          | Emit content -> emit content
        in
        vertices := vertex_of_note note :: !vertices;
        List.iter
          (function
            | Source.Text text -> emit (Observed.Text text)
            | Source.Action action ->
                match interpret context action with
                | Ok contributions -> List.iter contribute contributions
                | Error errors ->
                    action_failed := true;
                    List.iter
                      (fun error -> report (Action_error (note.id, error)))
                      errors)
          note.body;
        bodies := (note.id, List.rev !contents) :: !bodies
      done;
      if !action_failed || !issues <> [] then Error (List.rev !issues)
      else
        Ok {
          vertices = List.rev !vertices;
          edges = List.rev !edges;
          bodies = List.rev !bodies;
        }

let assemble (declarations : (_, _, _) declarations) =
  let graph_result = Graph.assemble declarations.vertices declarations.edges in
  let vertex_ids =
    List.fold_left
      (fun ids (vertex : _ Graph.vertex) -> Vertex_set.add vertex.id ids)
      Vertex_set.empty declarations.vertices
  in
  let bodies, body_issues =
    List.fold_left
      (fun (index, issues) (id, contents) ->
        let issues =
          if Vertex_set.mem id vertex_ids then issues
          else Unknown_body_vertex id :: issues
        in
        if Vertex_map.mem id index then
          (index, Duplicate_body id :: issues)
        else
          (Vertex_map.add id contents index, issues))
      (Vertex_map.empty, []) declarations.bodies
  in
  let _, body_issues =
    List.fold_left
      (fun (seen, issues) (vertex : _ Graph.vertex) ->
        if Vertex_set.mem vertex.id seen then (seen, issues)
        else
          let issues =
            if Vertex_map.mem vertex.id bodies then issues
            else Missing_body vertex.id :: issues
          in
          (Vertex_set.add vertex.id seen, issues))
      (Vertex_set.empty, body_issues) declarations.vertices
  in
  let body_issues = List.rev body_issues in
  match graph_result, body_issues with
  | Ok graph, [] -> Ok { graph; bodies }
  | Ok _, issues -> Error issues
  | Error issues, body_issues ->
      Error (List.map (fun issue -> Graph_issue issue) issues @ body_issues)
