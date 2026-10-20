(** Checked project-defined DSL functions and raw handlers. *)
type _ argument =
  | Reference : Graph.Vertex_id.t argument
  | String : string argument

type _ arguments =
  | Nil : unit arguments
  | Cons : 'a argument * 'b arguments -> ('a * 'b) arguments

type body_requirement = Forbidden | Optional | Required

type ('metadata, 'relation, 'action, 'consumption, 'error) t

(** Deferred calls can only be obtained through checked conversion.
    Constructing definitions and converting source do not execute callbacks. *)
type ('metadata, 'relation, 'consumption, 'error) action

type ('metadata, 'relation, 'action, 'consumption, 'error) registry

type check_error = {
  range : Dsl_syntax.range;
  message : string;
}

type registration_error = Duplicate_function of string

(** [body] defaults to [Forbidden]. An explicitly empty body satisfies [Required]. *)
val make :
  string ->
  args:'args arguments ->
  ?body:body_requirement ->
  ('metadata Observation.context ->
   'args ->
   'action Observation.Source.content list option ->
   (('metadata, 'relation, 'action, 'consumption) Observation.contribution list,
    'error list) result) ->
  ('metadata, 'relation, 'action, 'consumption, 'error) t

(** Raw handlers can emit content but cannot contribute definitions or relations. *)
val raw :
  string ->
  ('metadata Observation.context ->
   string ->
   ('consumption Observation.Observed.content list, 'error list) result) ->
  ('metadata, 'relation, 'action, 'consumption, 'error) t

val name : ('metadata, 'relation, 'action, 'consumption, 'error) t -> string

(** Functions and raw handlers share one namespace; duplicate names are rejected. *)
val register :
  ('metadata, 'relation, 'action, 'consumption, 'error) t list ->
  (('metadata, 'relation, 'action, 'consumption, 'error) registry,
   registration_error) result

(** Check every retained subtree, including argument and body requirements.
    [lookup] resolves project labels. Conversion stops at the first error. *)
val convert_body :
  lookup:(string -> Graph.Vertex_id.t option) ->
  ('metadata, 'relation,
   ('metadata, 'relation, 'consumption, 'error) action,
   'consumption, 'error) registry ->
  Dsl_syntax.content Dsl_syntax.located list ->
  (('metadata, 'relation, 'consumption, 'error) action
     Observation.Source.content list,
   check_error) result

val interpret :
  ('metadata, 'relation,
   ('metadata, 'relation, 'consumption, 'error) action,
   'consumption, 'error) Observation.interpreter
