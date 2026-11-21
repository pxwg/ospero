(** Policy definitions over a common fixed-topology state space. *)

module Invocation_id : sig
  type t

  (** Accept any non-empty string. Wiring checks uniqueness. *)
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val compare : t -> t -> int
end

(** An exceptional product carries the ID of its own record. *)
type 'a availability =
  | Ready of 'a
  | Degraded of 'a * Failure.id
  | Unavailable of Failure.id

module State : sig
  type ('vertex, 'edge) t

  (** With no [name], read the primary output. An unknown output or identity
      returns [None]. Unavailable products retain their place in the topology. *)
  val vertex : ?name:string -> ('vertex, 'edge) t -> Graph.Vertex_id.t -> 'vertex availability option
  val edge : ?name:string -> ('vertex, 'edge) t -> Graph.Edge_id.t -> 'edge availability option
  val products : ?name:string -> ('vertex, 'edge) t ->
    ('vertex availability, 'edge availability) Graph.t option

  (** A payload-only view exists if every product in the output is available.
      Use product queries when availability and provenance matter. *)
  val graph : ?name:string -> ('vertex, 'edge) t -> ('vertex, 'edge) Graph.t option

  (** Direct failure IDs for a source product. Available on the initial port
      of a compilation bound to an observation. *)
  val observation_causes :
    ('vertex, 'edge) t -> Observation.product -> Graph.Vertex_id.t -> Failure.id list option
end

(** These errors describe calls that could not deliver a state. *)
type 'issue error =
  | Failure of {
      invocation : Invocation_id.t;
      issues : 'issue list;
    }
  | Blocked of {
      invocation : Invocation_id.t;
      dependencies : Invocation_id.t list;
    }

(** [Success] delivers a state whose individual products can be unavailable. *)
type ('vertex, 'edge, 'issue) status =
  | Success of ('vertex, 'edge) State.t
  | Error of 'issue error

type product = {
  output : string option;
  target : Failure.target;
  card : Graph.Vertex_id.t;
      (** The vertex itself, or the source card of an edge product. *)
}

type subject = Invocation of Invocation_id.t | Product of Invocation_id.t * product

type 'issue failure_detail =
  | Failed of 'issue error
  | Used_fallback
  | Used_degraded_input
  | Product_failed of 'issue list
  | Product_blocked

type 'issue failure = (subject, 'issue failure_detail) Failure.t

type ('vertex, 'edge, 'issue) outcome = private {
  result : ('vertex, 'edge, 'issue) status;
  records : 'issue failure list;
}

(** A payload provider for each identity in the initial topology. *)
type ('vertex, 'edge) assignment = {
  vertex : Graph.Vertex_id.t -> 'vertex;
  edge : Graph.Edge_id.t -> 'edge;
}

(** Cite the IDs of the exceptional inputs actually used by this product.
    [Derive] keeps a computed value that depends on degraded inputs.
    [Recover_product] supplies a fallback value. [Block_product] supplies no
    value. Each of these decisions requires at least one cause.
    [Reject_product] records an independent failure. *)
type ('value, 'issue) product_decision =
  | Produce of 'value
  | Derive of 'value * Failure.id list
  | Recover_product of 'value * Failure.id list
  | Reject_product of 'issue list
  | Block_product of Failure.id list

(** A product under construction: a value together with the exceptional inputs
    it used, or the causes that leave it unavailable. Reading inputs through
    these combinators records their causes; [decide] turns the result into the
    matching decision, so a policy states only how a value is computed. *)
module Product : sig
  type 'a t

  val return : 'a -> 'a t

  (** Unavailable for these causes. Raises [Invalid_argument] on an empty list. *)
  val unavailable : Failure.id list -> 'a t

  val of_availability : 'a availability -> 'a t

  (** Read an input product. Raises [Invalid_argument] for an unknown identity
      or output, which the fixed topology rules out. *)
  val vertex :
    ?name:string -> ('vertex, 'edge) State.t -> Graph.Vertex_id.t -> 'vertex t

  val edge : ?name:string -> ('vertex, 'edge) State.t -> Graph.Edge_id.t -> 'edge t

  val map : ('a -> 'b) -> 'a t -> 'b t
  val bind : 'a t -> ('a -> 'b t) -> 'b t

  (** Combine independent products. When several are unavailable, all their
      causes are kept. *)
  val both : 'a t -> 'b t -> ('a * 'b) t

  val all : 'a t list -> 'a list t
  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
  val ( let* ) : 'a t -> ('a -> 'b t) -> 'b t
  val ( and* ) : 'a t -> 'b t -> ('a * 'b) t

  (** [Produce] without causes, [Derive] with degraded ones, otherwise
      [Block_product] citing every unavailable input. *)
  val decide : 'a t -> ('a, 'issue) product_decision
end

type ('vertex, 'edge, 'issue) product_assignment =
  (('vertex, 'issue) product_decision, ('edge, 'issue) product_decision) assignment

type ('vertex, 'edge, 'issue) outputs = {
  primary : ('vertex, 'edge, 'issue) product_assignment;
  named : (string * ('vertex, 'edge, 'issue) product_assignment) list;
      (** Optional, independently addressable outputs of the same payload types.
          Names must be unique within the call. *)
}

(** Ordered input states decoded into nested pairs ending in unit.
    [Cons_state] exposes individual products. [Cons] consumes the complete
    primary graph, including its degraded inputs, and blocks if it is incomplete.
    For both constructors, a call-level input error blocks the receiving call. *)
type (_, 'vertex, 'edge) ports =
  | Nil : (unit, 'vertex, 'edge) ports
  | Cons :
      ('p, 'vertex, 'edge) ports ->
      (('vertex, 'edge) Graph.t * 'p, 'vertex, 'edge) ports
  | Cons_state :
      ('p, 'vertex, 'edge) ports ->
      (('vertex, 'edge) State.t * 'p, 'vertex, 'edge) ports

type ('vertex, 'edge, 'issue) decision =
  | Apply of ('vertex, 'edge) assignment
  | Recover of ('vertex, 'edge) assignment * Failure.id list
  | Reject of 'issue list
  | Block_on of Failure.id list
  | Publish of ('vertex, 'edge, 'issue) outputs

type ('vertex, 'edge, 'issue) t

val arity : ('vertex, 'edge, 'issue) t -> int

type ('vertex, 'edge, 'issue) invocation = {
  id : Invocation_id.t;
  inputs : Invocation_id.t list;
  definition : ('vertex, 'edge, 'issue) t;
}

(** Declare a pure policy without running its callbacks. *)
val make :
  ('p, 'vertex, 'edge) ports ->
  ?check:('p -> 'issue list) ->
  ('p -> ('vertex, 'edge) assignment) ->
  ('vertex, 'edge, 'issue) t

(** Declare a pure policy that can cite direct causes from input products or
    from the observation bound by [Policy_wiring.compile_observation]. Empty
    cause lists on blocking, recovery, or derivation raise [Invalid_argument]. *)
val make_deciding :
  ('p, 'vertex, 'edge) ports ->
  ('p -> ('vertex, 'edge, 'issue) decision) ->
  ('vertex, 'edge, 'issue) t

(** Wrap the initial graph as a successful primary output with ready products. *)
val initial :
  ?observation_causes:(Observation.product -> Graph.Vertex_id.t -> Failure.id list) ->
  ('vertex, 'edge) Graph.t -> ('vertex, 'edge, 'issue) outcome

(** Build an operation without invoking callbacks. Each output is materialized
    over the captured topology once per evaluation, in vertex-then-edge order.
    Only records created by this invocation are returned. Exceptions propagate. *)
val lift :
  initial:('vertex, 'edge) Graph.t ->
  id:Invocation_id.t ->
  ('vertex, 'edge, 'issue) t ->
  ('vertex, 'edge, 'issue) outcome Clone.operation
