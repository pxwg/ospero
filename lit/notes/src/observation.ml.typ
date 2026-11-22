#import "/reader/book.typ": card-source, chunk
#show: card-source

= observation.ml <core:src:observation.ml>

#chunk(id: <source-core-src-observation-ml>)[
```ocaml
module Source = struct
  type 'action content =
    | Text of Text.t
    | Action of 'action

  type ('metadata, 'action) note = {
    id : Graph.Vertex_id.t Provenance.located;
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
    id_span : Provenance.span option;
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
      target : Graph.Vertex_id.t Provenance.located;
      relation : 'relation;
    }
  | Emit of 'consumption Observed.content

  | Fail of 'error

type ('metadata, 'relation, 'action, 'consumption, 'error) interpreter =
  'action ->
  ('metadata, 'relation, 'action, 'consumption, 'error) contribution list

type 'relation edge_declaration = {
  edge : 'relation Graph.edge;
  reference : int;
  call : Provenance.span option;
  target_span : Provenance.span option;
}

type ('metadata, 'relation, 'consumption) declarations = {
  vertices : 'metadata Observed.note Graph.vertex Provenance.located list;
  edges : 'relation edge_declaration list;
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

type 'error definition = {
  id : Graph.Vertex_id.t Provenance.located;
  title : Provenance.span option;
  note : Provenance.span option;
  rejected : 'error failure list;
}

type ('relation, 'error) reference = {
  source : Graph.Vertex_id.t;
  target : Graph.Vertex_id.t Provenance.located;
  call : Provenance.span option;
  edges : 'relation Graph.edge list;
  rejected : 'error failure list;
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
  definitions : 'error definition list;
  definitions_by_id : 'error definition list Vertex_map.t;
  references : ('relation, 'error) reference list;
  references_by_target : ('relation, 'error) reference list Vertex_map.t;
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

let all_definitions result = result.definitions
let definitions result id =
  Vertex_map.find_opt id result.definitions_by_id |> Option.value ~default:[]
let references result = result.references
let references_to result id =
  Vertex_map.find_opt id result.references_by_target |> Option.value ~default:[]

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

(* Report at the most specific known location. *)
let at_id specific fallback = match specific with Some _ -> specific | None -> fallback

let expand ?(metadata_errors = fun _ -> []) ~interpret project =
  let identities = Vertex_set.of_list project.identities in
  let definitions = ref Vertex_set.empty in
  let ambiguous = ref Vertex_set.empty in
  let pending = Queue.create () in
  let issues = ref [] in
  let report span issue = issues := Provenance.located ?span issue :: !issues in
  let vertices = ref [] in
  let edges = ref [] in
  let reference_count = ref 0 in
  let bodies = ref [] in
  let register generated_from (located : (_, _) Source.note Provenance.located) =
    let note = located.value in
    List.iter
      (fun error -> report note.metadata.span (Metadata_error (note.id.value, error)))
      (metadata_errors note.metadata.value);
    let id = note.id.value in
    if not (Vertex_set.mem id identities) then
      report (at_id note.id.span located.span) (Unregistered_definition id)
    else begin
      let vertex =
        { Graph.id;
          note = { Observed.id_span = note.id.span; title = note.title;
                   metadata = note.metadata; generated_from } }
      in
      vertices := { located with value = vertex } :: !vertices;
      if Vertex_set.mem id !definitions then
        ambiguous := Vertex_set.add id !ambiguous
      else begin
        definitions := Vertex_set.add id !definitions;
        Queue.add note pending
      end
    end
  in
  List.iter (register None) project.notes;
  let observe_body (note : (_, _) Source.note) =
    let source = note.id.value in
    let contents = ref [] in
    let edge_index = ref 0 in
    let emit span content =
      contents := Provenance.located ?span content :: !contents
    in
    (* [arguments] holds the references already opened by the current action. *)
    let contribute span arguments = function
      | Define definition ->
          register (Some { source; action = span }) definition
      | Relate { target; relation } ->
          let id = Observation_edge_id.make ~source ~index:!edge_index in
          incr edge_index;
          let key = target.value, target.span in
          let reference = match List.assoc_opt key !arguments with
            | Some reference -> reference
            | None ->
                let reference = !reference_count in
                incr reference_count;
                arguments := (key, reference) :: !arguments;
                reference
          in
          edges := { edge = { Graph.id; source; target = target.value; relation };
                     reference; call = span; target_span = target.span } :: !edges
      | Emit content -> emit span content
      | Fail error -> report span (Action_error (source, error))
    in
    List.iter
      (fun (content : _ Provenance.located) ->
        match content.value with
        | Source.Text text -> emit content.span (Observed.Text text)
        | Source.Action action ->
            List.iter (contribute content.span (ref [])) (interpret action))
      note.body.value;
    bodies := (source, { note.body with value = List.rev !contents }) :: !bodies
  in
  (* Initial notes run first; generated definitions join the FIFO queue.
     Assembly also rejects contributions from definitions found ambiguous later. *)
  while not (Queue.is_empty pending) do
    let note = Queue.take pending in
    if not (Vertex_set.mem note.id.value !ambiguous) then observe_body note
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
  let candidates = List.map (fun (located : _ Graph.vertex Provenance.located) ->
    let vertex = located.value in
    let note = vertex.note in
    let span = at_id note.Observed.id_span located.span in
    let rejected =
      if Vertex_set.mem vertex.Graph.id duplicates then
        [ record span (Duplicate_definition vertex.id) ]
      else match note.generated_from with
        | Some { source; _ } when not (available source) ->
            [ record span (Unavailable_generator (vertex.id, source)) ]
        | _ -> []
    in
    located,
    { id = Provenance.located ?span:note.id_span vertex.id; title = note.title.span;
      note = located.span; rejected }) declarations.vertices
  in
  let vertices = List.filter_map (fun (located, (definition : _ definition)) ->
    match definition.rejected with [] -> Some located | _ -> None) candidates in
  let definitions = List.map snd candidates in
  let edge_counts = List.fold_left (fun counts (declared : _ edge_declaration) ->
    Edge_map.update declared.edge.Graph.id
      (fun count -> Some (1 + Option.value count ~default:0)) counts)
    Edge_map.empty declarations.edges
  in
  let reference_error span (edge : _ Graph.edge) problem =
    record span (Reference_error { source = edge.source; problem })
  in
  (* Endpoints are shared by the edges of a reference, so their failures are
     recorded once, at its first edge; duplicate identities stay per edge. *)
  let endpoint_failures = Hashtbl.create 16 in
  let checked = List.map (fun (declared : _ edge_declaration) ->
    let edge = declared.edge in
    let duplicate =
      if Edge_map.find edge.id edge_counts = 1 then []
      else [ reference_error declared.call edge (Graph.Duplicate_edge edge.id) ]
    in
    let endpoints = match Hashtbl.find_opt endpoint_failures declared.reference with
      | Some failures -> failures
      | None ->
          let failures =
            (if available edge.source then []
             else [ reference_error declared.call edge
                      (Graph.Missing_endpoint (edge.id, Source, edge.source)) ])
            @ (if available edge.target then []
               else [ reference_error (at_id declared.target_span declared.call) edge
                        (Graph.Missing_endpoint (edge.id, Target, edge.target)) ])
          in
          Hashtbl.add endpoint_failures declared.reference failures;
          failures
    in
    declared, duplicate @ endpoints) declarations.edges
  in
  let edges, rejected_references = List.partition_map (fun ((declared : _ edge_declaration), reasons) ->
    let located = Provenance.located ?span:declared.call declared.edge in
    match reasons with
    | [] -> Either.Left located
    | _ -> Either.Right { declaration = located; reasons }) checked
  in
  (* Edges contributed by one target argument form one source reference. *)
  let references =
    let module Int_map = Map.Make (Int) in
    (* Edges and their failures accumulate in reverse; shared endpoint
       failures recur in every edge of a reference and are kept once. *)
    let groups = List.fold_left (fun groups ((declared : _ edge_declaration), reasons) ->
      Int_map.update declared.reference (fun group ->
        let first, edges, rejected = Option.value group ~default:(declared, [], []) in
        Some (first, declared.edge :: edges, List.rev_append reasons rejected))
        groups) Int_map.empty checked
    in
    let once records = List.fold_left (fun kept record ->
      if List.exists (fun r -> Failure.compare r.Failure.id record.Failure.id = 0) kept then kept
      else record :: kept) [] records |> List.rev in
    (* Ordinals follow the first edge of each reference, hence declaration order. *)
    Int_map.bindings groups |> List.map (fun (_, ((first : _ edge_declaration), edges, rejected)) ->
      { source = first.edge.Graph.source;
        target = Provenance.located ?span:first.target_span first.edge.target;
        call = first.call; edges = List.rev edges; rejected = once (List.rev rejected) })
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
  let group key items = List.fold_right (fun item index ->
    Vertex_map.update (key item) (fun group -> Some (item :: Option.value group ~default:[])) index)
    items Vertex_map.empty in
  { graph; bodies; edge_sources; failures; failures_by_vertex;
    rejected_references; rejected_by_source;
    definitions; definitions_by_id = group (fun (d : _ definition) -> d.id.value) definitions;
    references;
    references_by_target = group (fun (r : _ reference) -> r.target.value) references;
    note_sources = index_vertex (fun located -> located.span);
    title_sources = index_vertex (fun located -> located.value.note.Observed.title.span);
    metadata_sources = index_vertex (fun located -> located.value.note.Observed.metadata.span);
    generations = index_vertex (fun located -> located.value.note.Observed.generated_from) }
```
]

#chunk(id: <file-core-src-observation-ml>, target: "core/src/observation.ml")[
```ocaml
<<source-core-src-observation-ml>>
```
]
