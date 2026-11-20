(** Frontend contracts: decode raw Source into typed Source, then interpret
    typed actions. Syntax adapters produce the raw project; Observation
    expands and assembles the decoded project. *)

(** Undecoded field values shared by metadata and invocation arguments.
    Decoding assigns them project-defined meaning. *)
module Payload : sig
  (** A value occurrence. [None] means no direct source location is known. *)
  type t = value Provenance.located

  and value =
    | String of string
    | Bool of bool
    | Int of int
    | List of t list
    | Record of field list
        (** Fields keep their source order, including duplicate names. *)
    | Contents of Text.t
        (** Content kept for later processing, such as rich-text fields or
            nested note bodies. The text is the fixed snapshot taken by the
            current scan; the enclosing occurrence locates it in the source. *)

  and field = {
    name : string Provenance.located;
    value : t;
  }

  (** The constructor of a value, without its contents. *)
  module Kind : sig
    type t = String | Bool | Int | List | Record | Contents

    val of_value : value -> t
  end
end

(** An undecoded action call in a note body.
    The enclosing body occurrence locates the whole invocation. *)
module Invocation : sig
  type t = {
    name : string Provenance.located;
    arguments : Payload.field list;
        (** Named payloads in source order, including duplicate names. *)
  }
end

(** A problem reported while extracting or decoding input.
    [None] means no direct source location is known. *)
module Diagnostic : sig
  (** A step from the decoded value towards the offending occurrence. *)
  type segment =
    | Field of string
    | Index of int

  type problem =
    | Type_mismatch of { expected : Payload.Kind.t; given : Payload.Kind.t }
    | Missing_field of string
        (** Reported at the enclosing record. *)
    | Unknown_field of { name : string; known : string list }
    | Duplicate_field of string
    | Invalid_choice of { given : string; choices : string list }
    | Unknown_action of { name : string; known : string list }
    | Invalid of string
        (** A project-defined constraint rejected a well-formed value. *)

  type t = {
    problem : problem;
    path : segment list;
        (** Outermost first; empty at the decoded value itself. *)
    span : Provenance.span option;
  }

  val make : ?path:segment list -> ?span:Provenance.span -> problem -> t
end

(** Project-supplied rules for the values occurring in the current layer. *)
module type DECODING = sig
  type metadata
  type action

  val decode_metadata :
    Payload.t -> (metadata, Diagnostic.t list) result

  (** Construct an action without executing its interpretation. *)
  val decode_action :
    Invocation.t -> (action, Diagnostic.t list) result
end

(** Current-layer Source decoding, reusable for top-level and nested input. *)
module type DECODER = sig
  type metadata
  type action

  (** Decode the note's metadata and the invocations directly in its body.
      The raw metadata occurrence is passed to [decode_metadata] as a
      located [Payload.t].
      Identity, title, text, order and provenance are preserved.
      Contents retained by an action are not decoded here. *)
  val decode_source :
    (Payload.value, Invocation.t) Observation.Source.note Provenance.located ->
    ((metadata, action) Observation.Source.note Provenance.located,
     Diagnostic.t list) result

  (** Decode every initial note; registered identities are kept unchanged.
      Diagnostics from all notes are reported together. *)
  val decode_project :
    (Payload.value, Invocation.t) Observation.project ->
    ((metadata, action) Observation.project, Diagnostic.t list) result
end

(** Derive both decoding entries from the same current-layer traversal. *)
module Decode (Rules : DECODING) :
  DECODER
    with type metadata = Rules.metadata
     and type action = Rules.action

(** A complete frontend: decoding plus an independent interpreter.
    An interpreter handling Contents obtains the next typed Source layer with
    [Syntax.parse_contents] followed by [decode_source]. *)
module type FRONTEND = sig
  include DECODER

  type relation
  type consumption
  type error

  (** Interpret a decoded action into ordered contributions.
      Observation owns recursive expansion and note-context switching.
      Prefer exhaustive matching without a wildcard when [action] is a variant. *)
  val interpret :
    (metadata, relation, action, consumption, error) Observation.interpreter
end

module Make (Frontend : FRONTEND) : sig
  type error =
    | Decode of Diagnostic.t list
    | Observe of Frontend.error Observation.issue list

  (** Decode the raw project, expand actions, then assemble the observation.
      Stop at the first failing stage; policy evaluation remains separate. *)
  val observe :
    (Payload.value, Invocation.t) Observation.project ->
    ((Frontend.metadata, Frontend.relation, Frontend.consumption) Observation.t,
     error) result
end
