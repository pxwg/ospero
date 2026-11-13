(** Standard frontend contract and observation driver. *)
module type FRONTEND = sig
  type metadata
  type relation
  type consumption
  type action
  type error
  type parse_error
  type input

  (** Produce registered identities and initial notes with optional provenance.
      Parsing constructs actions; it does not execute their interpretation. *)
  val parse :
    input ->
    ((metadata, action) Observation.project, parse_error list) result

  (** Interpret frontend-defined actions into ordered contributions.
      Observation owns recursive expansion and note-context switching.
      Prefer exhaustive matching without a wildcard when [action] is a variant. *)
  val interpret :
    (metadata, relation, action, consumption, error) Observation.interpreter
end

module Make (Frontend : FRONTEND) : sig
  type error =
    | Parse of Frontend.parse_error list
    | Observe of Frontend.error Observation.issue list

  (** Parse, expand actions, then assemble the observation.
      Stop at the first failing stage; policy evaluation remains separate. *)
  val observe :
    Frontend.input ->
    ((Frontend.metadata, Frontend.relation, Frontend.consumption) Observation.t,
     error) result
end
