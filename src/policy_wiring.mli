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

(** A compiled morphism bound to its initial state.
    The morphism is hidden so callers cannot substitute an external graph. *)
type ('vertex, 'edge, 'issue) compiled

(** Compile without executing policy callbacks or assignment providers.
    [input] names the single external input and shares the calls' namespace.
    Forward references, repeated ports, zero-input calls and unused results
    are allowed. All calls are included, not just ancestors of a final output.

    Compilation captures [initial] as the sole external input and fixes
    the topology used to materialize every policy output.
    With no calls the morphism is identity on the initial result.
    Structural errors return no partial compilation. *)
val compile :
  initial:('vertex, 'edge) Graph.t ->
  input:Policy.Invocation_id.t ->
  ('vertex, 'edge, 'issue) Policy.invocation list ->
  (('vertex, 'edge, 'issue) compiled, issue list) result

(** Evaluate on the captured initial state and associate results with identities.
    The initial input comes first, followed by dependency layers, each ordered
    by invocation identity. Each call is evaluated once per evaluation;
    separate evaluations rerun the computation. Callback exceptions propagate. *)
val evaluate :
  ('vertex, 'edge, 'issue) compiled ->
  (Policy.Invocation_id.t * ('vertex, 'edge, 'issue) Policy.outcome) list
