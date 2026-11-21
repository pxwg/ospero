#import "/reader/book.typ": chunk

= policy_report.mli <core:src:policy_report.mli>

#chunk(id: <source-core-src-policy-report-mli>)[
```ocaml
(** Terminal report for one project run. Records retain their typed details and
    direct causes. Report construction neither evaluates policies nor alters values. *)

type ('observation_error, 'policy_issue) entry =
  | Syntax of (unit, Frontend.Diagnostic.t) Failure.t
  | Observation of 'observation_error Observation.failure
  | Policy of 'policy_issue Policy.failure

type integrity_issue =
  | Duplicate_record of Failure.id
  | Missing_cause of { record : Failure.id; cause : Failure.id }

type ('observation_error, 'policy_issue) t

type ('observation_error, 'policy_issue) impact = {
  entries : ('observation_error, 'policy_issue) entry list;
  edges : (Failure.id * Failure.id) list;
      (** Direct edges oriented from cause to effect. *)
}

(** Supply the observation and all the outcomes from its associated evaluation.
    [syntax] holds the extraction diagnostics no card owns; each is a root. *)
val of_evaluation :
  syntax:Frontend.Diagnostic.t list ->
  observation:('metadata, 'relation, 'consumption, 'error) Observation.t ->
  outcomes:(Policy.Invocation_id.t * ('metadata Graph.note, 'relation, 'issue) Policy.outcome) list ->
  ('error, 'issue) t

val id : ('error, 'issue) entry -> Failure.id
val causes : ('error, 'issue) entry -> Failure.id list
val entries : ('error, 'issue) t -> ('error, 'issue) entry list
val roots : ('error, 'issue) t -> ('error, 'issue) entry list
val find : ('error, 'issue) t -> Failure.id -> ('error, 'issue) entry option
val for_card : ('error, 'issue) t -> Graph.Vertex_id.t -> ('error, 'issue) entry list
val for_invocation :
  ('error, 'issue) t -> Policy.Invocation_id.t -> ('error, 'issue) entry list
val integrity_issues : ('error, 'issue) t -> integrity_issue list

(** Return the origin and all its reachable effects, each once. Includes all
    direct edges encountered, including separate paths to a shared effect.
    An unknown origin returns [None]. *)
val impact : ('error, 'issue) t -> Failure.id -> ('error, 'issue) impact option
```
]

#chunk(id: <file-core-src-policy-report-mli>, target: "core/src/policy_report.mli")[
```ocaml
<<source-core-src-policy-report-mli>>
```
]
