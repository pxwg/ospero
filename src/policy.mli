(** Policy definitions over a common fixed-topology state space. *)

(** Computation identities, distinct from knowledge-graph identities. *)
module Invocation_id : sig
  type t

  (** Accept any non-empty string; uniqueness is checked when wiring calls. *)
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val compare : t -> t -> int
end

(** [Failure] carries the current invocation's applicability issues.
    [Blocked] carries the producer identities of erroneous direct inputs. *)
type 'issue error =
  | Failure of {
      invocation : Invocation_id.t;
      issues : 'issue list;
    }
  | Blocked of {
      invocation : Invocation_id.t;
      dependencies : Invocation_id.t list;
    }

(** The disjoint union of successful graph states and invocation errors. *)
type ('vertex, 'edge, 'issue) outcome =
  | Success of ('vertex, 'edge) Graph.t
  | Error of 'issue error

(** A payload provider for each identity in the initial topology.
    The evaluator materializes these providers into a saved graph state. *)
type ('vertex, 'edge) assignment = {
  vertex : Graph.Vertex_id.t -> 'vertex;
  edge : Graph.Edge_id.t -> 'edge;
}

(** Ordered input states decoded into nested pairs ending in unit.
    [Nil] describes a zero-input policy; [Cons Nil] describes one input. *)
type (_, 'vertex, 'edge) ports =
  | Nil : (unit, 'vertex, 'edge) ports
  | Cons :
      ('p, 'vertex, 'edge) ports ->
      (('vertex, 'edge) Graph.t * 'p, 'vertex, 'edge) ports

(** Inputs are ordered states; repeated inputs are distinct ports.
    The evaluator supplies exactly [arity] inputs from the common state space.
    [check] describes applicability: only an empty issue list permits [run].
    [run] supplies payloads, never a replacement topology.
    Callbacks are expected to be pure; exceptions indicate implementation errors. *)
type ('vertex, 'edge, 'issue) t = private {
  arity : int;
  check : ('vertex, 'edge) Graph.t list -> 'issue list;
  run : ('vertex, 'edge) Graph.t list -> ('vertex, 'edge) assignment;
}

(** An identified use of a policy definition. Its identity also addresses
    its result. Inputs preserve port order and repetitions. *)
type ('vertex, 'edge, 'issue) invocation = {
  id : Invocation_id.t;
  inputs : Invocation_id.t list;
  definition : ('vertex, 'edge, 'issue) t;
}

(** Declare a call without executing callbacks. Identity uniqueness, input
    resolution, port counts and acyclicity are checked during assembly. *)
val invocation :
  Invocation_id.t ->
  ('vertex, 'edge, 'issue) t ->
  inputs:Invocation_id.t list ->
  ('vertex, 'edge, 'issue) invocation

(** Declare a policy without executing either callback.
    Arity is derived from [ports]; callbacks receive its typed input shape.
    [check] defaults to accepting all inputs. Internally, list inputs are
    decoded before invoking callbacks; a count mismatch raises [Invalid_argument]. *)
val make :
  ('p, 'vertex, 'edge) ports ->
  ?check:('p -> 'issue list) ->
  ('p -> ('vertex, 'edge) assignment) ->
  ('vertex, 'edge, 'issue) t

(** Lift a definition at a fixed invocation identity into a result operation.
    Construction executes no callbacks. Input states must belong to the
    initial topology's state space; program wiring supplies this invariant.

    Erroneous inputs block execution of both [check] and [run]. Their producer
    identities are deduplicated and sorted, without tracing root failures.
    Otherwise input order and repetitions are preserved for [check] and [run].
    Nonempty check issues are preserved as returned; an empty list permits run.

    Successful assignments are materialized once per identity using the initial
    topology, in vertex-then-edge assembly order. Exceptions propagate.
    The operation enforces the definition's input arity, including zero. *)
val lift :
  initial:('vertex, 'edge) Graph.t ->
  id:Invocation_id.t ->
  ('vertex, 'edge, 'issue) t ->
  ('vertex, 'edge, 'issue) outcome Clone.operation
