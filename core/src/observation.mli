(** Input objects, before observation expands actions. *)
module Source : sig
  type 'action content =
    | Text of string
    | Action of 'action

  (** Constructing a note does not register its identity.
      Metadata follows the project schema; the body preserves input order.
      Each body occurrence carries its optional source span independently
      of the text or action value. The outer body wrapper locates the whole
      container, including an explicitly empty body. *)
  type ('metadata, 'action) note = {
    id : Graph.Vertex_id.t;
    title : string Provenance.located;
    metadata : 'metadata Provenance.located;
        (** The optional span covers the original metadata as a whole,
            independently of the project-defined decoded value.
            Omitted metadata has no direct source span. *)
    body : 'action content Provenance.located list Provenance.located;
  }
end

(** Registered identities are frozen as a set before observation.
    Initial notes need not cover every registered identity.
    Duplicate registrations are harmless; duplicate definitions are conflicts. *)
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

module Observed : sig
  (** Note fields retain direct source locations until assembly separates
      semantic values from the observation's source registry. *)
  type 'metadata note = {
    title : string Provenance.located;
    metadata : 'metadata Provenance.located;
    generated_from : generation option;
  }

  (** Final body data, with no pending observation actions.
      Consumption declarations are interpreted by consumers; they do not
      contribute further definitions or graph edges. *)
  type 'consumption content =
    | Text of string
    | Consume of 'consumption
end

(** Read-only context supplied by the core when interpreting an action. *)
type 'metadata context = {
  current : Graph.Vertex_id.t;
  is_registered : Graph.Vertex_id.t -> bool;
      (** Membership in the frozen identity space. *)
  lookup :
    Graph.Vertex_id.t ->
    'metadata Graph.note Graph.vertex option;
      (** Query the frozen snapshot of initial explicit definitions.
          Returns identity, title and metadata.
          Generated definitions do not update this snapshot.
          A registered identity may still return [None]. *)
}

(** Ordered contributions returned by an action interpreter. *)
type ('metadata, 'relation, 'action, 'consumption) contribution =
  | Define of ('metadata, 'action) Source.note Provenance.located
      (** Contribute a definition for a registered identity.
          The core observes its body under that identity; subsequent
          contributions still belong to the original current note.
          Duplicate definitions are conflicts. The wrapper records the direct
          definition span, not the generating action's span. *)
  | Relate of {
      target : Graph.Vertex_id.t;
      relation : 'relation;
    }
      (** Contribute an edge from the current note to the target.
          Each occurrence receives an ID from its source and local index. *)
  | Emit of 'consumption Observed.content
      (** Append action-free content to the current note's observed body. *)

(** Interpret an action into ordered contributions or project-defined errors. *)
type ('metadata, 'relation, 'action, 'consumption, 'error) interpreter =
  'metadata context ->
  'action ->
  (('metadata, 'relation, 'action, 'consumption) contribution list,
   'error list) result

(** Expanded graph and body declarations, awaiting assembly.
    Lists preserve declaration order and duplicate entries for validation.
    Vertex title and metadata retain their direct source spans until assembly
    separates semantic values from the source registry. *)
type ('metadata, 'relation, 'consumption) declarations = {
  vertices : 'metadata Observed.note Graph.vertex Provenance.located list;
  edges : 'relation Graph.edge Provenance.located list;
  bodies :
    (Graph.Vertex_id.t *
     'consumption Observed.content Provenance.located list Provenance.located) list;
}

(** Structural diagnostics and errors reported by the project interpreter. *)
type 'error issue =
  | Unregistered_definition of Graph.Vertex_id.t
  | Duplicate_definition of Graph.Vertex_id.t
  | Action_error of Graph.Vertex_id.t * 'error
      (** The current note's identity and the interpreter's error. *)
  | Graph_issue of Graph.issue
  | Missing_body of Graph.Vertex_id.t
  | Duplicate_body of Graph.Vertex_id.t
  | Unknown_body_vertex of Graph.Vertex_id.t

(** Freeze registered identities and the initial explicit-definition snapshot,
    then expand note bodies using the interpreter.
    Edge IDs use the source identity and its zero-based Relate occurrence index.
    Endpoint existence is checked during assembly.
    Plain text retains its source span. Each Relate and Emit contribution
    inherits the current action's span, including absence of a source span.
    Define records the generating action separately from the supplied direct
    definition and field spans. Nested definitions retain their immediate
    generating note identity; no source position is fabricated. *)
val expand :
  interpret:('metadata, 'relation, 'action, 'consumption, 'error) interpreter ->
  ('metadata, 'action) project ->
  (('metadata, 'relation, 'consumption) declarations, 'error issue list) result

(** A completed observation, with one observed body per graph vertex. *)
type ('metadata, 'relation, 'consumption) t

(** Validate graph structure and require exactly one body per vertex.
    An empty body is represented by an explicit empty list.
    Return a complete result or diagnostics.
    Assembly reports graph and body issues; it does not invoke the interpreter. *)
val assemble :
  ('metadata, 'relation, 'consumption) declarations ->
  (('metadata, 'relation, 'consumption) t, 'error issue list) result

(** The semantic graph contains unwrapped title and metadata values.
    Source locations remain owned by this observation, independently of
    policy computations. *)
val graph :
  ('metadata, 'relation, 'consumption) t ->
  ('metadata, 'relation) Graph.knowledge_graph

(** Return the body in observation order.
    [None] denotes an identity absent from the result graph;
    [Some []] denotes a vertex with an empty body. *)
val body :
  ('metadata, 'relation, 'consumption) t ->
  Graph.Vertex_id.t ->
  'consumption Observed.content Provenance.located list option

(** Return the source of the action that contributed an edge.
    [None] means the edge is absent; [Some None] means it exists without a
    known source span. Sources are retained outside the semantic graph. *)
val edge_source :
  ('metadata, 'relation, 'consumption) t ->
  Graph.Edge_id.t ->
  Provenance.span option option

(** Return the direct source span of a note's original metadata as a whole.
    [None] means the vertex is absent; [Some None] means it exists without a
    known metadata span. Generated definitions retain their supplied metadata
    span; the generating action's span is not substituted for a missing one. *)
val metadata_source :
  ('metadata, 'relation, 'consumption) t ->
  Graph.Vertex_id.t ->
  Provenance.span option option

(** Return the direct source span of a note's original title.
    [None] means the vertex is absent; [Some None] means it exists without a
    known title span. A generating action's span is not substituted. *)
val title_source :
  ('metadata, 'relation, 'consumption) t ->
  Graph.Vertex_id.t ->
  Provenance.span option option

(** Return the direct source span of the complete note definition.
    [None] means the vertex is absent; [Some None] means it has no known
    direct definition span. Generated notes preserve their supplied span;
    no action or title span is substituted. *)
val note_source :
  ('metadata, 'relation, 'consumption) t ->
  Graph.Vertex_id.t ->
  Provenance.span option option

(** The original body container span, including delimiters when supplied by
    the DSL. Empty bodies retain this location. Absence follows [note_source]. *)
val body_source :
  ('metadata, 'relation, 'consumption) t ->
  Graph.Vertex_id.t ->
  Provenance.span option option

(** [None] means an unknown vertex; [Some None] means an initial definition.
    Generated definitions record the immediate action and owning note even
    when the action itself has no source span. Direct field spans are unchanged. *)
val generated_from :
  ('metadata, 'relation, 'consumption) t ->
  Graph.Vertex_id.t ->
  generation option option

