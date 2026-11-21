#import "/reader/book.typ": chunk

= graph.mli <core:src:graph.mli>

#chunk(id: <source-core-src-graph-mli>)[
```ocaml
(** A directed multigraph with opaque payloads.
    Vertex and edge identities are supplied by the caller.
    Parallel edges and cycles are allowed. *)

module Vertex_id : sig
  type t

  (** Accept any non-empty string. Graph-wide uniqueness is not checked here. *)
  val of_string : string -> (t, string) result

  val to_string : t -> string

  (** A total order for indexing, with no domain-specific ordering semantics. *)
  val compare : t -> t -> int
end

module Edge_id : sig
  type t

  (** Accept any non-empty string. Graph-wide uniqueness is not checked here. *)
  val of_string : string -> (t, string) result

  val to_string : t -> string

  (** A total order for indexing, with no domain-specific ordering semantics. *)
  val compare : t -> t -> int
end

(** A vertex declaration. Identity uniqueness is checked during assembly. *)
type 'note vertex = {
  id : Vertex_id.t;
  note : 'note;
}

(** An edge declaration. Its endpoints need not exist yet. *)
type 'relation edge = {
  id : Edge_id.t;
  source : Vertex_id.t;
  target : Vertex_id.t;
  relation : 'relation;
}

(** A valid graph has unique vertex identities, unique edge identities,
    and existing endpoints for every edge.
    Vertex and edge identities occupy separate namespaces. *)
type ('note, 'relation) t

(** A note payload, excluding identity, body, and provenance. *)
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
      (** The edge identity, endpoint direction, and referenced vertex identity. *)

(** Check duplicate identities and missing endpoints.
    Return a complete graph on success, or diagnostics without a partial graph
    on failure. If both endpoints of an edge are missing, report each separately.
    Edges are not deduplicated by endpoints or relation payloads. *)
val assemble :
  'note vertex list ->
  'relation edge list ->
  (('note, 'relation) t, issue list) result

(** Transform payloads while sharing the original topology and adjacency indexes.
    Callbacks receive original declarations and return only new payloads.
    They run once per vertex, then once per edge, in assembly input order.
    Payload types may change; identities, endpoints and order are preserved. *)
val map :
  vertex:('note vertex -> 'new_note) ->
  edge:('relation edge -> 'new_relation) ->
  ('note, 'relation) t ->
  ('new_note, 'new_relation) t

(** Return vertices in their assembly input order. *)
val vertices :
  ('note, 'relation) t -> 'note vertex list

(** Return edges in their assembly input order, preserving parallel edges. *)
val edges :
  ('note, 'relation) t -> 'relation edge list

(** Return the complete vertex, or [None] if its identity is unknown. *)
val find_vertex :
  ('note, 'relation) t -> Vertex_id.t -> 'note vertex option

(** Return the complete edge, or [None] if its identity is unknown. *)
val find_edge :
  ('note, 'relation) t -> Edge_id.t -> 'relation edge option

(** Return complete incoming edges in relative edge input order,
    preserving parallel edges.
    [None] denotes an unknown vertex; [Some []] denotes a known vertex
    with no incoming edges. A self-loop is both incoming and outgoing. *)
val incoming :
  ('note, 'relation) t -> Vertex_id.t -> 'relation edge list option

(** Return complete outgoing edges in relative edge input order,
    preserving parallel edges.
    [None] denotes an unknown vertex; [Some []] denotes a known vertex
    with no outgoing edges. A self-loop is both incoming and outgoing. *)
val outgoing :
  ('note, 'relation) t -> Vertex_id.t -> 'relation edge list option
```
]

#chunk(id: <file-core-src-graph-mli>, target: "core/src/graph.mli")[
```ocaml
<<source-core-src-graph-mli>>
```
]
