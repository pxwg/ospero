module Source = struct
  type 'action content =
    | Text of Text.t
    | Action of 'action

  type ('metadata, 'action) note = {
    id : Graph.Vertex_id.t;
    title : Text.t Provenance.located;
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
    title : Text.t Provenance.located;
    metadata : 'metadata Provenance.located;
    generated_from : generation option;
  }

  type 'consumption content =
    | Text of Text.t
    | Consume of 'consumption
end

type ('metadata, 'relation, 'action, 'consumption, 'error) contribution =
  | Define of ('metadata, 'action) Source.note Provenance.located
  | Relate of {
      target : Graph.Vertex_id.t;
      relation : 'relation;
    }
  | Emit of 'consumption Observed.content

  | Fail of 'error

type ('metadata, 'relation, 'action, 'consumption, 'error) interpreter =
  'action ->
  ('metadata, 'relation, 'action, 'consumption, 'error) contribution list

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
  | Unavailable_generator of Graph.Vertex_id.t * Graph.Vertex_id.t
  | Metadata_error of Graph.Vertex_id.t * 'error
  | Action_error of Graph.Vertex_id.t * 'error
  | Reference_error of {
      source : Graph.Vertex_id.t;
      problem : Graph.issue;
    }
  | Missing_body of Graph.Vertex_id.t
  | Duplicate_body of Graph.Vertex_id.t
  | Unknown_body_vertex of Graph.Vertex_id.t

type subject = Note of Graph.Vertex_id.t | Reference of Graph.Edge_id.t

type 'error failure = (subject, 'error issue Provenance.located) Failure.t

type ('relation, 'error) rejected_reference = {
  declaration : 'relation Graph.edge Provenance.located;
  reasons : 'error failure list;
}

module Vertex_set = Set.Make (Graph.Vertex_id)
module Vertex_map = Map.Make (Graph.Vertex_id)
module Edge_map = Map.Make (Graph.Edge_id)

type ('metadata, 'relation, 'consumption, 'error) t = {
  graph : ('metadata, 'relation) Graph.knowledge_graph;
  bodies :
    'consumption Observed.content Provenance.located list Provenance.located Vertex_map.t;
  generations : generation option Vertex_map.t;
  edge_sources : Provenance.span option Edge_map.t;
  metadata_sources : Provenance.span option Vertex_map.t;
  title_sources : Provenance.span option Vertex_map.t;
  note_sources : Provenance.span option Vertex_map.t;
  failures : 'error failure list;
  failures_by_vertex : 'error failure list Vertex_map.t;
  rejected_references : ('relation, 'error) rejected_reference list;
  rejected_by_source : ('relation, 'error) rejected_reference list Vertex_map.t;
}

type ('relation, 'error) outgoing = {
  resolved : 'relation Graph.edge list;
  unresolved : ('relation, 'error) rejected_reference list;
  failures : 'error failure list;
}

let failure_records (result : (_, _, _, _) t) = result.failures
let failures_for result id =
  Vertex_map.find_opt id result.failures_by_vertex |> Option.value ~default:[]
let issues result = List.map (fun record -> record.Failure.detail) (failure_records result)
let issues_for result id =
  List.map (fun record -> record.Failure.detail) (failures_for result id)
let rejected_references result = result.rejected_references
let unresolved_references result =
  List.map (fun reference -> reference.declaration) (rejected_references result)

let graph result = result.graph

let outgoing result id =
  Option.map (fun resolved ->
    let unresolved = Vertex_map.find_opt id result.rejected_by_source
      |> Option.value ~default:[] in
    let failures = failures_for result id |> List.filter (fun record ->
      match record.Failure.detail.Provenance.value with
      | Action_error _ | Reference_error _ -> true
      | _ -> false) in
    { resolved; unresolved; failures }) (Graph.outgoing result.graph id)

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

let expand ?(metadata_errors = fun _ -> []) ~interpret project =
  let identities = Vertex_set.of_list project.identities in
  let definitions = ref Vertex_set.empty in
  let ambiguous = ref Vertex_set.empty in
  let pending = Queue.create () in
  let issues = ref [] in
  let report span issue = issues := Provenance.located ?span issue :: !issues in
  let vertices = ref [] in
  let edges = ref [] in
  let bodies = ref [] in
  let register generated_from (located : (_, _) Source.note Provenance.located) =
    let note = located.value in
    List.iter
      (fun error -> report note.metadata.span (Metadata_error (note.id, error)))
      (metadata_errors note.metadata.value);
    if not (Vertex_set.mem note.id identities) then
      report located.span (Unregistered_definition note.id)
    else begin
      let vertex =
        { Graph.id = note.id;
          note = { Observed.title = note.title; metadata = note.metadata; generated_from } }
      in
      vertices := { located with value = vertex } :: !vertices;
      if Vertex_set.mem note.id !definitions then
        ambiguous := Vertex_set.add note.id !ambiguous
      else begin
        definitions := Vertex_set.add note.id !definitions;
        Queue.add note pending
      end
    end
  in
  List.iter (register None) project.notes;
  let observe_body (note : (_, _) Source.note) =
    let contents = ref [] in
    let edge_index = ref 0 in
    let emit span content =
      contents := Provenance.located ?span content :: !contents
    in
    let contribute span = function
      | Define definition ->
          register (Some { source = note.id; action = span }) definition
      | Relate { target; relation } ->
          let id = Observation_edge_id.make ~source:note.id ~index:!edge_index in
          incr edge_index;
          edges := Provenance.located ?span
            { Graph.id; source = note.id; target; relation } :: !edges
      | Emit content -> emit span content
      | Fail error -> report span (Action_error (note.id, error))
    in
    List.iter
      (fun (content : _ Provenance.located) ->
        match content.value with
        | Source.Text text -> emit content.span (Observed.Text text)
        | Source.Action action -> List.iter (contribute content.span) (interpret action))
      note.body.value;
    bodies := (note.id, { note.body with value = List.rev !contents }) :: !bodies
  in
  (* Initial notes run first; generated definitions join the FIFO queue.
     Assembly also rejects contributions from definitions found ambiguous later. *)
  while not (Queue.is_empty pending) do
    let note = Queue.take pending in
    if not (Vertex_set.mem note.id !ambiguous) then observe_body note
  done;
  { vertices = List.rev !vertices; edges = List.rev !edges; bodies = List.rev !bodies },
  List.rev !issues

let issue_owner = function
  | Unregistered_definition id | Duplicate_definition id
  | Unavailable_generator (id, _) | Metadata_error (id, _) | Action_error (id, _)
  | Missing_body id | Duplicate_body id | Unknown_body_vertex id -> id
  | Reference_error { source; _ } -> source

let failure_owner (failure : _ failure) = issue_owner failure.detail.value

type product = Metadata | Body | Outgoing

let failures_for_product observation product id =
  failures_for observation id |> List.filter (fun record ->
    match product, record.Failure.detail.Provenance.value with
    | _, (Unregistered_definition _ | Duplicate_definition _ | Unavailable_generator _)
      when Option.is_none (Graph.find_vertex (graph observation) id) -> true
    | Metadata, Metadata_error _ -> true
    | Body, (Action_error _ | Missing_body _ | Duplicate_body _ | Unknown_body_vertex _) -> true
    | Outgoing, (Action_error _ | Reference_error _) -> true
    | _ -> false)

let metadata observation id =
  Option.map (fun vertex ->
    let failures = failures_for_product observation Metadata id in
    match failures with
    | [] -> Ok vertex.Graph.note.Graph.metadata
    | failures -> Error failures)
    (Graph.find_vertex (graph observation) id)

let failure_subject = function
  | Reference_error { problem = (Graph.Duplicate_edge id | Graph.Missing_endpoint (id, _, _)); _ } ->
      Reference id
  | issue -> Note (issue_owner issue)

let failure_record occurrence (detail : _ Provenance.located) =
  { Failure.id = Failure.observation occurrence;
    subject = failure_subject detail.value;
    detail;
    causes = [] }

let assemble ?(issues = []) (declarations : (_, _, _) declarations) =
  let earlier = List.mapi failure_record issues in
  let occurrence = ref (List.length earlier) in
  let found = ref [] in
  let record span issue =
    let failure = failure_record !occurrence (Provenance.located ?span issue) in
    incr occurrence;
    found := failure :: !found;
    failure
  in
  let report span issue = ignore (record span issue) in
  let vertex_index, duplicates =
    List.fold_left (fun (index, duplicates) (located : _ Graph.vertex Provenance.located) ->
      let id = located.value.Graph.id in
      if Vertex_map.mem id index then index, Vertex_set.add id duplicates
      else Vertex_map.add id located index, duplicates)
      (Vertex_map.empty, Vertex_set.empty) declarations.vertices
  in
  (* A generated definition needs its generating card to resolve uniquely. *)
  let children = List.fold_left (fun index (located : _ Provenance.located) ->
    match located.value.Graph.note.Observed.generated_from with
    | None -> index
    | Some { source; _ } ->
        Vertex_map.update source (fun children ->
          Some (located.value.Graph.id :: Option.value children ~default:[])) index)
    Vertex_map.empty declarations.vertices
  in
  let rec reject rejected = function
    | [] -> rejected
    | id :: rest when Vertex_set.mem id rejected -> reject rejected rest
    | id :: rest ->
        let children = Vertex_map.find_opt id children |> Option.value ~default:[] in
        reject (Vertex_set.add id rejected) (List.rev_append children rest)
  in
  let unavailable_generators = Vertex_map.fold (fun source _ missing ->
    if Vertex_map.mem source vertex_index then missing else source :: missing) children []
  in
  let rejected = reject Vertex_set.empty (Vertex_set.elements duplicates @ unavailable_generators) in
  let available id = Vertex_map.mem id vertex_index && not (Vertex_set.mem id rejected) in
  let vertices = List.filter (fun (located : _ Graph.vertex Provenance.located) ->
    let vertex = located.value in
    if Vertex_set.mem vertex.Graph.id duplicates then begin
      report located.span (Duplicate_definition vertex.id);
      false
    end else match vertex.note.Observed.generated_from with
      | Some { source; _ } when not (available source) ->
          report located.span (Unavailable_generator (vertex.id, source));
          false
      | _ -> true) declarations.vertices
  in
  let edge_counts = List.fold_left (fun counts (located : _ Provenance.located) ->
    Edge_map.update located.value.Graph.id
      (fun count -> Some (1 + Option.value count ~default:0)) counts)
    Edge_map.empty declarations.edges
  in
  let edges, rejected_references = List.partition_map (fun (located : _ Provenance.located) ->
    let edge : _ Graph.edge = located.value in
    let reasons =
      [ Edge_map.find edge.id edge_counts <> 1, Graph.Duplicate_edge edge.id;
        not (available edge.source), Graph.Missing_endpoint (edge.id, Source, edge.source);
        not (available edge.target), Graph.Missing_endpoint (edge.id, Target, edge.target) ]
      |> List.filter_map (fun (failed, problem) ->
        if failed then Some (record located.span (Reference_error { source = edge.source; problem }))
        else None)
    in
    match reasons with
    | [] -> Either.Left located
    | _ -> Either.Right { declaration = located; reasons }) declarations.edges
  in
  let body_index = List.fold_left (fun index (id, (contents : _ Provenance.located)) ->
    if available id then
      Vertex_map.update id (function
        | None -> Some [contents]
        | Some candidates -> Some (contents :: candidates)) index
    else begin
      if not (Vertex_map.mem id vertex_index) then report contents.span (Unknown_body_vertex id);
      index
    end) Vertex_map.empty declarations.bodies
  in
  let bodies = List.fold_left (fun bodies (located : _ Graph.vertex Provenance.located) ->
    let id = located.value.Graph.id in
    match Vertex_map.find_opt id body_index with
    | Some [contents] -> Vertex_map.add id contents bodies
    | Some candidates ->
        List.iter (fun (body : _ Provenance.located) -> report body.span (Duplicate_body id))
          (List.rev candidates);
        bodies
    | None -> report located.span (Missing_body id); bodies) Vertex_map.empty vertices
  in
  let graph =
    let values = List.map (fun (located : _ Provenance.located) ->
      let vertex : _ Observed.note Graph.vertex = located.value in
      { vertex with note = { Graph.title = vertex.note.title.value;
                             metadata = vertex.note.metadata.value } }) vertices in
    match Graph.assemble values (List.map (fun (e : _ Provenance.located) -> e.value) edges) with
    | Ok graph -> graph
    | Error _ -> invalid_arg "Observation.assemble: invalid resolved topology"
  in
  let index_vertex f = List.fold_left (fun index (located : _ Graph.vertex Provenance.located) ->
    Vertex_map.add located.value.Graph.id (f located) index) Vertex_map.empty vertices in
  let edge_sources = List.fold_left (fun index (located : _ Provenance.located) ->
    Edge_map.add located.value.Graph.id located.span index) Edge_map.empty edges in
  let failures = earlier @ List.rev !found in
  let failures_by_vertex = List.fold_right (fun failure index ->
    Vertex_map.update (issue_owner failure.Failure.detail.Provenance.value)
      (fun group -> Some (failure :: Option.value group ~default:[])) index)
    failures Vertex_map.empty in
  let rejected_by_source = List.fold_right (fun reference index ->
    Vertex_map.update reference.declaration.value.Graph.source
      (fun group -> Some (reference :: Option.value group ~default:[])) index)
    rejected_references Vertex_map.empty in
  { graph; bodies; edge_sources; failures; failures_by_vertex;
    rejected_references; rejected_by_source;
    note_sources = index_vertex (fun located -> located.span);
    title_sources = index_vertex (fun located -> located.value.note.Observed.title.span);
    metadata_sources = index_vertex (fun located -> located.value.note.Observed.metadata.span);
    generations = index_vertex (fun located -> located.value.note.Observed.generated_from) }
