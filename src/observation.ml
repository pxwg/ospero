module Source = struct
  type 'action content =
    | Text of string
    | Action of 'action

  type ('metadata, 'action) note = {
    id : Graph.Vertex_id.t;
    title : string Provenance.located;
    metadata : 'metadata Provenance.located;
    body : 'action content Provenance.located list Provenance.located;
  }
end

type ('metadata, 'action) project = {
  identities : Graph.Vertex_id.t list;
  notes : ('metadata, 'action) Source.note Provenance.located list;
}

(** The immediate action that generated a definition. Its owning note can
    itself be generated; this link does not replace direct source locations. *)
type generation = {
  source : Graph.Vertex_id.t;
  action : Provenance.span option;
}

module Observed = struct
  type 'metadata note = {
    title : string Provenance.located;
    metadata : 'metadata Provenance.located;
    generated_from : generation option;
  }

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
  | Define of ('metadata, 'action) Source.note Provenance.located
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
  vertices : 'metadata Observed.note Graph.vertex Provenance.located list;
  edges : 'relation Graph.edge Provenance.located list;
  bodies :
    (Graph.Vertex_id.t *
     'consumption Observed.content Provenance.located list Provenance.located) list;
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
module Edge_map = Map.Make (Graph.Edge_id)

type ('metadata, 'relation, 'consumption) t = {
  graph : ('metadata, 'relation) Graph.knowledge_graph;
  bodies :
    'consumption Observed.content Provenance.located list Provenance.located Vertex_map.t;
  generations : generation option Vertex_map.t;
  edge_sources : Provenance.span option Edge_map.t;
  metadata_sources : Provenance.span option Vertex_map.t;
  title_sources : Provenance.span option Vertex_map.t;
  note_sources : Provenance.span option Vertex_map.t;
}

let graph result = result.graph
let body result id =
  Option.map (fun (body : _ Provenance.located) -> body.value)
    (Vertex_map.find_opt id result.bodies)
let body_source result id =
  Option.map (fun (body : _ Provenance.located) -> body.span)
    (Vertex_map.find_opt id result.bodies)
let generated_from result id = Vertex_map.find_opt id result.generations
let edge_source result id = Edge_map.find_opt id result.edge_sources
let metadata_source result id = Vertex_map.find_opt id result.metadata_sources
let title_source result id = Vertex_map.find_opt id result.title_sources
let note_source result id = Vertex_map.find_opt id result.note_sources

let vertex_of_note (note : (_, _) Source.note) =
  { Graph.id = note.id;
    note = { Graph.title = note.title.value; metadata = note.metadata.value } }

let expand ~interpret project =
  let identities = Vertex_set.of_list project.identities in
  let is_registered id = Vertex_set.mem id identities in
  let definitions = ref Vertex_set.empty in
  let pending = Queue.create () in
  let issues = ref [] in
  let report issue = issues := issue :: !issues in
  let register generated_from (located : (_, _) Source.note Provenance.located) =
    let note = located.value in
    let registered = is_registered note.id in
    let duplicate = Vertex_set.mem note.id !definitions in
    if not registered then report (Unregistered_definition note.id);
    if duplicate then report (Duplicate_definition note.id);
    definitions := Vertex_set.add note.id !definitions;
    if registered && not duplicate then Queue.add (located, generated_from) pending
  in
  List.iter (register None) project.notes;
  match List.rev !issues with
  | _ :: _ as errors -> Error errors
  | [] ->
      let snapshot =
        List.fold_left
          (fun index (note : _ Provenance.located) ->
            let vertex = vertex_of_note note.value in
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
        let located, generated_from = Queue.take pending in
        let note = located.value in
        let context = { current = note.id; is_registered; lookup } in
        let contents = ref [] in
        let edge_index = ref 0 in
        let emit span content =
          contents := Provenance.located ?span content :: !contents
        in
        let contribute span = function
          | Define definition ->
              register (Some { source = note.id; action = span }) definition
          | Relate { target; relation } ->
              let id =
                Observation_edge_id.make ~source:note.id ~index:!edge_index
              in
              incr edge_index;
              edges :=
                Provenance.located ?span
                  { Graph.id; source = note.id; target; relation } :: !edges
          | Emit content -> emit span content
        in
        vertices :=
          Provenance.located ?span:located.span
            { Graph.id = note.id;
              note = { Observed.title = note.title;
                       metadata = note.metadata; generated_from } }
          :: !vertices;
        List.iter
          (fun (content : _ Provenance.located) ->
            match content.value with
            | Source.Text text -> emit content.span (Observed.Text text)
            | Source.Action action ->
                match interpret context action with
                | Ok contributions ->
                    List.iter (contribute content.span) contributions
                | Error errors ->
                    action_failed := true;
                    List.iter
                      (fun error -> report (Action_error (note.id, error)))
                      errors)
          note.body.value;
        bodies :=
          (note.id, Provenance.located ?span:note.body.span (List.rev !contents))
          :: !bodies
      done;
      if !action_failed || !issues <> [] then Error (List.rev !issues)
      else
        Ok {
          vertices = List.rev !vertices;
          edges = List.rev !edges;
          bodies = List.rev !bodies;
        }

let assemble (declarations : (_, _, _) declarations) =
  let edges =
    List.map (fun (edge : _ Provenance.located) -> edge.value) declarations.edges
  in
  let vertices =
    List.map
      (fun (located : _ Provenance.located) ->
        let vertex : _ Observed.note Graph.vertex = located.value in
        { vertex with note =
            { Graph.title = vertex.note.title.value;
              metadata = vertex.note.metadata.value } })
      declarations.vertices
  in
  let graph_result = Graph.assemble vertices edges in
  let vertex_ids =
    List.fold_left
      (fun ids (vertex : _ Graph.vertex) -> Vertex_set.add vertex.id ids)
      Vertex_set.empty vertices
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
      (Vertex_set.empty, body_issues) vertices
  in
  let body_issues = List.rev body_issues in
  match graph_result, body_issues with
  | Ok graph, [] ->
      let edge_sources =
        List.fold_left
          (fun index (edge : _ Provenance.located) ->
            Edge_map.add edge.value.Graph.id edge.span index)
          Edge_map.empty declarations.edges
      in
      let metadata_sources =
        List.fold_left
          (fun index (located : _ Provenance.located) ->
            let vertex : _ Observed.note Graph.vertex = located.value in
            Vertex_map.add vertex.id vertex.note.metadata.span index)
          Vertex_map.empty declarations.vertices
      in
      let title_sources =
        List.fold_left
          (fun index (located : _ Provenance.located) ->
            let vertex : _ Observed.note Graph.vertex = located.value in
            Vertex_map.add vertex.id vertex.note.title.span index)
          Vertex_map.empty declarations.vertices
      in
      let note_sources =
        List.fold_left
          (fun index (located : _ Graph.vertex Provenance.located) ->
            Vertex_map.add located.value.id located.span index)
          Vertex_map.empty declarations.vertices
      in
      let generations =
        List.fold_left
          (fun index (located : _ Observed.note Graph.vertex Provenance.located) ->
            Vertex_map.add located.value.id located.value.note.generated_from index)
          Vertex_map.empty declarations.vertices
      in
      Ok { graph; bodies; edge_sources; metadata_sources; title_sources;
           note_sources; generations }
  | Ok _, issues -> Error issues
  | Error issues, body_issues ->
      Error (List.map (fun issue -> Graph_issue issue) issues @ body_issues)
