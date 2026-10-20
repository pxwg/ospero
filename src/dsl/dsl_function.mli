(** Checked project-defined DSL functions and raw handlers. *)
type _ argument =
  | Reference : Graph.Vertex_id.t argument
  | String : string argument

type _ arguments =
  | Nil : unit arguments
  | Cons : 'a argument * 'b arguments -> ('a * 'b) arguments

(** Body requirements determine the value received by the callback. *)
type ('action, _) body =
  | Forbidden : ('action, unit) body
  | Optional : ('action, 'action Observation.Source.content list option) body
  | Required : ('action, 'action Observation.Source.content list) body

type ('metadata, 'relation, 'consumption, 'error) t

(** Deferred calls can only be obtained through checked conversion.
    Constructing definitions and converting source do not execute callbacks. *)
type ('metadata, 'relation, 'consumption, 'error) action

type ('metadata, 'relation, 'consumption, 'error) registry

type check_error = {
  range : Dsl_syntax.range;
  message : string;
}

type registration_error = Duplicate_function of string

(** An explicitly empty body satisfies [Required]; an absent body does not. *)
val make :
  string ->
  args:'args arguments ->
  body:(('metadata, 'relation, 'consumption, 'error) action, 'body) body ->
  ('metadata Observation.context ->
   'args ->
   'body ->
   (('metadata, 'relation,
     ('metadata, 'relation, 'consumption, 'error) action, 'consumption)
      Observation.contribution list,
    'error list) result) ->
  ('metadata, 'relation, 'consumption, 'error) t

(** Raw handlers can emit content but cannot contribute definitions or relations. *)
val raw :
  string ->
  ('metadata Observation.context ->
   string ->
   ('consumption Observation.Observed.content list, 'error list) result) ->
  ('metadata, 'relation, 'consumption, 'error) t

val name : ('metadata, 'relation, 'consumption, 'error) t -> string

(** Functions and raw handlers share one namespace; duplicate names are rejected. *)
val register :
  ('metadata, 'relation, 'consumption, 'error) t list ->
  (('metadata, 'relation, 'consumption, 'error) registry,
   registration_error) result

(** Check every retained subtree, including argument and body requirements.
    [lookup] resolves project labels. Conversion stops at the first error. *)
val convert_body :
  lookup:(string -> Graph.Vertex_id.t option) ->
  ('metadata, 'relation, 'consumption, 'error) registry ->
  Dsl_syntax.content Dsl_syntax.located list ->
  (('metadata, 'relation, 'consumption, 'error) action
     Observation.Source.content list,
   check_error) result

val interpret :
  ('metadata, 'relation,
   ('metadata, 'relation, 'consumption, 'error) action,
   'consumption, 'error) Observation.interpreter
