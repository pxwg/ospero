(** Compile named policy calls into a single result-space morphism. *)

type issue =
  | Duplicate_identity of Policy.Invocation_id.t
  | Port_count_mismatch of {
      invocation : Policy.Invocation_id.t;
      expected : int;
      actual : int;
    }
  | Missing_input of {
      invocation : Policy.Invocation_id.t;
      port : int;
      source : Policy.Invocation_id.t;
    }
  | Cyclic_dependencies of Policy.Invocation_id.t list
      (** Unresolved calls, including descendants waiting on cycles. *)

(** Output identities correspond positionally to morphism results.
    The initial input comes first, followed by dependency layers.
    Each layer is ordered by invocation identity. *)
type ('vertex, 'edge, 'issue) compiled = private {
  morphism : ('vertex, 'edge, 'issue) Policy.outcome Clone.morphism;
  outputs : Policy.Invocation_id.t list;
}

(** Compile without executing policy callbacks or assignment providers.
    [input] names the single external input and shares the calls' namespace.
    Forward references, repeated ports, zero-input calls and unused results
    are allowed. All calls are included, not just ancestors of a final output.

    Apply the returned morphism to [[Policy.Success initial]].
    Compilation fixes the topology used to materialize every policy output.
    With no calls the morphism is identity on the initial result.
    Structural errors return no partial compilation. *)
val compile :
  initial:('vertex, 'edge) Graph.t ->
  input:Policy.Invocation_id.t ->
  ('vertex, 'edge, 'issue) Policy.invocation list ->
  (('vertex, 'edge, 'issue) compiled, issue list) result
