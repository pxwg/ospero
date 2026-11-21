#import "/reader/book.typ": chunk

= frontend.mli <core:src:frontend.mli>

#chunk(id: <source-core-src-frontend-mli>)[
```ocaml
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

(** A problem reported while extracting or decoding input. *)
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
    | Missing_identity of { insertion : Provenance.span option; prefix : string; suffix : string }
        (** A card declaration without an ID. Writing [prefix ^ id ^ suffix] at
            the empty [insertion] span declares one. *)

  type t = {
    problem : problem;
    path : segment list;
        (** Outermost first; empty at the decoded value itself. *)
    span : Provenance.span option;
        (** The range to report, when known. This may be an enclosing range. *)
  }

  val make : ?path:segment list -> ?span:Provenance.span -> problem -> t

  (** Supply an enclosing range only when the diagnostic has no range. *)
  val with_fallback_span : Provenance.span option -> t -> t
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

(** What Syntax read from the source: a value for later decoding, or the
    diagnostics explaining why the construct could not be read. *)
type 'a read = ('a, Diagnostic.t list) result

(** A note as Syntax hands it over. Metadata and each action keep their own
    reading outcome, so one unreadable construct degrades only its card. *)
type raw_note = (Payload.value read, Invocation.t read) Observation.Source.note

type raw_project = (Payload.value read, Invocation.t read) Observation.project

type 'a decoded = ('a, Diagnostic.t list) result

(** Why an action is unavailable: Syntax could not read the call, or the
    call was read but did not decode. *)
type action_failure =
  | Unread of Diagnostic.t list
  | Undecoded of Invocation.t * Diagnostic.t list

type 'a decoded_action = ('a, action_failure) result

type 'error failure =
  | Metadata_decode of Diagnostic.t list
      (** Unreadable or undecodable metadata. *)
  | Action_decode of action_failure
  | Interpretation of 'error

(** Decode the current Source layer. Identity, text, provenance and order
    are preserved. Metadata and each action retain their own outcome; reading
    failures pass through unchanged. Contents retained by an action are not
    decoded here. *)
module type DECODER = sig
  type metadata
  type action

  val decode_source :
    raw_note Provenance.located ->
    (metadata decoded, action decoded_action) Observation.Source.note Provenance.located

  val decode_project :
    raw_project -> (metadata decoded, action decoded_action) Observation.project
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

  (** Interpret a decoded action into ordered contributions. A generated note
      can itself carry decoding failures. *)
  val interpret :
    action ->
    (metadata decoded, relation, action decoded_action, consumption, error)
      Observation.contribution list
end

module Make (Frontend : FRONTEND) : sig
  (** Decode, expand, and assemble a graph together with all failure contributions. *)
  val observe :
    raw_project ->
    (Frontend.metadata decoded, Frontend.relation, Frontend.consumption,
     Frontend.error failure) Observation.t
end
```
]

#chunk(id: <file-core-src-frontend-mli>, target: "core/src/frontend.mli")[
```ocaml
<<source-core-src-frontend-mli>>
```
]
