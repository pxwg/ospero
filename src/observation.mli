(** Input objects, before observation expands actions. *)
module Source : sig
  type 'action content =
    | Text of string
    | Action of 'action

  (** Constructing a note does not register its identity.
      Metadata follows the project schema; the body preserves input order. *)
  type ('metadata, 'action) note = {
    id : Graph.Vertex_id.t;
    title : string;
    metadata : 'metadata;
    body : 'action content list;
  }
end

(** Registered identities are frozen as a set before observation.
    Initial notes need not cover every registered identity.
    Duplicate registrations are harmless; duplicate definitions are conflicts. *)
type ('metadata, 'action) project = {
  identities : Graph.Vertex_id.t list;
  notes : ('metadata, 'action) Source.note list;
}

module Observed : sig
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
  | Define of ('metadata, 'action) Source.note
      (** Contribute a definition for a registered identity.
          The core observes its body under that identity; subsequent
          contributions still belong to the original current note.
          Duplicate definitions are conflicts. *)
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
    Lists preserve declaration order and duplicate entries for validation. *)
type ('metadata, 'relation, 'consumption) declarations = {
  vertices : 'metadata Graph.note Graph.vertex list;
  edges : 'relation Graph.edge list;
  bodies :
    (Graph.Vertex_id.t * 'consumption Observed.content list) list;
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
    Endpoint existence is checked during assembly. *)
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

val graph :
  ('metadata, 'relation, 'consumption) t ->
  ('metadata, 'relation) Graph.knowledge_graph

(** Return the body in observation order.
    [None] denotes an identity absent from the result graph;
    [Some []] denotes a vertex with an empty body. *)
val body :
  ('metadata, 'relation, 'consumption) t ->
  Graph.Vertex_id.t ->
  'consumption Observed.content list option

