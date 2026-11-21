#import "/reader/book.typ": chunk

= observation.mli <core:src:observation.mli>

#chunk(id: <source-core-src-observation-mli>)[
```ocaml
(** Input objects, before observation expands actions. *)
module Source : sig
  type 'action content =
    | Text of Text.t
    | Action of 'action

  (** Constructing a note does not register its identity.
      Metadata follows the project schema; the body preserves input order.
      Each body occurrence carries its optional source span independently
      of the text or action value. The outer body wrapper locates the whole
      container, including an explicitly empty body. *)
  type ('metadata, 'action) note = {
    id : Graph.Vertex_id.t Provenance.located;
        (** The span covers the ID as written, such as a label or property. *)
    title : Text.t Provenance.located;
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
    id_span : Provenance.span option;
    title : Text.t Provenance.located;
    metadata : 'metadata Provenance.located;
    generated_from : generation option;
  }

  (** Final body data, with no pending observation actions.
      Consumption declarations are interpreted by consumers; they do not
      contribute further definitions or graph edges. *)
  type 'consumption content =
    | Text of Text.t
    | Consume of 'consumption
end

(** Ordered contributions returned by an action interpreter. *)
type ('metadata, 'relation, 'action, 'consumption, 'error) contribution =
  | Define of ('metadata, 'action) Source.note Provenance.located
      (** Contribute a definition for a registered identity.
          The core observes its body under that identity; subsequent
          contributions still belong to the original current note.
          Duplicate definitions are conflicts. The wrapper records the direct
          definition span, not the generating action's span. *)
  | Relate of {
      target : Graph.Vertex_id.t Provenance.located;
      relation : 'relation;
    }
      (** Contribute an edge from the current note to the target. The span
          locates the target argument within the action. Each occurrence
          receives an ID from its source and local index. Contributions of
          one action that name the same target at the same span form one
          source reference, as when an argument yields several relations. *)
  | Emit of 'consumption Observed.content
      (** Append action-free content to the current note's observed body. *)

  | Fail of 'error
      (** Report a failed action contribution without discarding siblings. *)

(** Interpret an action into ordered contributions.
    The action carries its explicit inputs; the core supplies no context.
    Contributions belong to the note whose body contains the action. *)
type ('metadata, 'relation, 'action, 'consumption, 'error) interpreter =
  'action ->
  ('metadata, 'relation, 'action, 'consumption, 'error) contribution list

(** A declared edge with the whole action and the target argument located. *)
type 'relation edge_declaration = {
  edge : 'relation Graph.edge;
  reference : int;
      (** The ordinal of its source reference in the expansion, shared by
          every edge of that reference. *)
  call : Provenance.span option;
  target_span : Provenance.span option;
}

(** Expanded graph and body declarations, awaiting assembly.
    Lists preserve declaration order and duplicate entries for validation.
    Vertex title and metadata retain their direct source spans until assembly
    separates semantic values from the source registry. *)
type ('metadata, 'relation, 'consumption) declarations = {
  vertices : 'metadata Observed.note Graph.vertex Provenance.located list;
  edges : 'relation edge_declaration list;
  bodies :
    (Graph.Vertex_id.t *
     'consumption Observed.content Provenance.located list Provenance.located) list;
}

(** Failed contributions retain the source span of the offending occurrence:
    the ID of a rejected definition, the target argument of an unresolved
    target, otherwise the affected construct. *)
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

(** Freeze registered identities and expand actions. Edge IDs use the source
    identity and its zero-based Relate occurrence index. Define preserves both
    the direct definition location and the generating action's location.
    [metadata_errors] identifies failures carried by a decoded metadata value. *)
val expand :
  ?metadata_errors:('metadata -> 'error list) ->
  interpret:('metadata, 'relation, 'action, 'consumption, 'error) interpreter ->
  ('metadata, 'action) project ->
  ('metadata, 'relation, 'consumption) declarations * 'error issue Provenance.located list

(** The assembled graph and the contributions that could not be resolved. *)
type ('metadata, 'relation, 'consumption, 'error) t

(** A definition candidate of an identity, whether or not it resolved. *)
type 'error definition = {
  id : Graph.Vertex_id.t Provenance.located;
  title : Provenance.span option;
  note : Provenance.span option;
  rejected : 'error failure list;
      (** Why this candidate was rejected; empty for the resolved definition. *)
}

(** One source occurrence of a target argument. Several edges contributed by
    the same argument share it. *)
type ('relation, 'error) reference = {
  source : Graph.Vertex_id.t;
  target : Graph.Vertex_id.t Provenance.located;
      (** The span locates the target argument. *)
  call : Provenance.span option;
  edges : 'relation Graph.edge list;
  rejected : 'error failure list;
      (** Failures of its edges, each recorded once for the reference;
          empty when every edge resolved. *)
}

(** Keep uniquely defined vertices and uniquely identified edges with valid
    endpoints. Reject every candidate for an ambiguous identity. Keep all
    diagnostics, including earlier failures, and all rejected references. *)
val assemble :
  ?issues:'error issue Provenance.located list ->
  ('metadata, 'relation, 'consumption) declarations ->
  ('metadata, 'relation, 'consumption, 'error) t

val issues :
  ('metadata, 'relation, 'consumption, 'error) t ->
  'error issue Provenance.located list

(** Issues owned by a vertex, including its rejected references. *)
val issues_for :
  ('metadata, 'relation, 'consumption, 'error) t -> Graph.Vertex_id.t ->
  'error issue Provenance.located list

val unresolved_references :
  ('metadata, 'relation, 'consumption, 'error) t ->
  'relation Graph.edge Provenance.located list

(** Records retain their identities across every query of this observation. *)
val failure_records :
  ('metadata, 'relation, 'consumption, 'error) t -> 'error failure list

val failures_for :
  ('metadata, 'relation, 'consumption, 'error) t -> Graph.Vertex_id.t ->
  'error failure list

(** The owning card, including the source of a rejected reference. *)
val failure_owner : 'error failure -> Graph.Vertex_id.t

type product = Metadata | Body | Outgoing

(** Documented gaps for a source product. An action failure can affect both
    the body and the outgoing references. *)
val failures_for_product :
  ('metadata, 'relation, 'consumption, 'error) t -> product -> Graph.Vertex_id.t ->
  'error failure list

(** Read the metadata independently of the title, definition and body.
    [None] denotes an unresolved card. *)
val metadata :
  ('metadata, 'relation, 'consumption, 'error) t -> Graph.Vertex_id.t ->
  ('metadata, 'error failure list) result option

val rejected_references :
  ('metadata, 'relation, 'consumption, 'error) t ->
  ('relation, 'error) rejected_reference list

(** Every definition candidate of a registered identity, in declaration order,
    including duplicates and candidates under an unavailable generator.
    Unregistered definitions are reported as issues only. *)
val definitions :
  ('metadata, 'relation, 'consumption, 'error) t -> Graph.Vertex_id.t ->
  'error definition list

(** Every definition candidate, in declaration order. *)
val all_definitions :
  ('metadata, 'relation, 'consumption, 'error) t -> 'error definition list

(** Every source reference in declaration order, resolved or not. *)
val references :
  ('metadata, 'relation, 'consumption, 'error) t -> ('relation, 'error) reference list

(** The source references naming this target, including dangling ones. *)
val references_to :
  ('metadata, 'relation, 'consumption, 'error) t -> Graph.Vertex_id.t ->
  ('relation, 'error) reference list

type ('relation, 'error) outgoing = {
  resolved : 'relation Graph.edge list;
  unresolved : ('relation, 'error) rejected_reference list;
  failures : 'error failure list;
}

(** Read the known outgoing edges and their gaps. An action failure is
    conservatively treated as a possible gap. [None] means the source does
    not resolve to a graph vertex; consult [failures_for] for its failures. *)
val outgoing :
  ('metadata, 'relation, 'consumption, 'error) t -> Graph.Vertex_id.t ->
  ('relation, 'error) outgoing option

(** The semantic graph contains unwrapped title and metadata values.
    Source locations remain owned by this observation, independently of
    policy computations. *)
val graph :
  ('metadata, 'relation, 'consumption, 'error) t ->
  ('metadata, 'relation) Graph.knowledge_graph

(** Return the body in observation order.
    [None] denotes an unavailable body or an identity absent from the graph;
    [Some []] denotes a vertex with an empty body. *)
val body :
  ('metadata, 'relation, 'consumption, 'error) t ->
  Graph.Vertex_id.t ->
  'consumption Observed.content Provenance.located list option

(** Return the source of the action that contributed an edge.
    [None] means the edge is absent; [Some None] means it exists without a
    known source span. Sources are retained outside the semantic graph. *)
val edge_source :
  ('metadata, 'relation, 'consumption, 'error) t ->
  Graph.Edge_id.t ->
  Provenance.span option option

(** Return the direct source span of a note's original metadata as a whole.
    [None] means the vertex is absent; [Some None] means it exists without a
    known metadata span. Generated definitions retain their supplied metadata
    span; the generating action's span is not substituted for a missing one. *)
val metadata_source :
  ('metadata, 'relation, 'consumption, 'error) t ->
  Graph.Vertex_id.t ->
  Provenance.span option option

(** Return the direct source span of a note's original title.
    [None] means the vertex is absent; [Some None] means it exists without a
    known title span. A generating action's span is not substituted. *)
val title_source :
  ('metadata, 'relation, 'consumption, 'error) t ->
  Graph.Vertex_id.t ->
  Provenance.span option option

(** Return the direct source span of the complete note definition.
    [None] means the vertex is absent; [Some None] means it has no known
    direct definition span. Generated notes preserve their supplied span;
    no action or title span is substituted. *)
val note_source :
  ('metadata, 'relation, 'consumption, 'error) t ->
  Graph.Vertex_id.t ->
  Provenance.span option option

(** The original body container span, including delimiters when supplied by
    the DSL. Empty bodies retain this location. Absence follows [body]. *)
val body_source :
  ('metadata, 'relation, 'consumption, 'error) t ->
  Graph.Vertex_id.t ->
  Provenance.span option option

(** [None] means an unknown vertex; [Some None] means an initial definition.
    Generated definitions record the immediate action and owning note even
    when the action itself has no source span. Direct field spans are unchanged. *)
val generated_from :
  ('metadata, 'relation, 'consumption, 'error) t ->
  Graph.Vertex_id.t ->
  generation option option

```
]

#chunk(id: <file-core-src-observation-mli>, target: "core/src/observation.mli")[
```ocaml
<<source-core-src-observation-mli>>
```
]
