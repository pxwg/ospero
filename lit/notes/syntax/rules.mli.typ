#import "/reader/book.typ": chunk

= rules.mli <syntax:rules.mli>

#chunk(id: <source-syntax-rules-mli>)[
```ocaml
(** Rule tables for writing Syntax adapters. Optional: an adapter whose
    parser already yields payloads and identities may skip them. *)
open Ospero_kernel
open Frontend

(** A rule can decline a node, accept it, or report why it is malformed.
    A rule table tries the next rule only after [No_match]. *)
type 'a matched =
  | No_match
  | Matched of 'a
  | Invalid of Diagnostic.t list

module Payload_rules : sig
  (** Value rules are selected by the carrier of the field being read. *)
  type 'node t
  type 'node reader

  val empty : 'node t

  (** Register a reading for one value type. Later registrations run first.
      Raises [Invalid_argument] if the name is taken. *)
  val register :
    name:string ->
    value:'a Syntax.Args.value ->
    ('node Provenance.located -> 'node reader -> 'a Provenance.located matched) ->
    'node t ->
    'node t

  (** Override the rule of this name in place. Raises [Invalid_argument] if
      there is none. *)
  val replace :
    name:string ->
    value:'a Syntax.Args.value ->
    ('node Provenance.located -> 'node reader -> 'a Provenance.located matched) ->
    'node t ->
    'node t

  (** Register a reading for lists of any item type: split the node into
      element nodes, each read with the item descriptor. Element diagnostics
      carry their index. Raises [Invalid_argument] if the name is taken. *)
  val register_items :
    name:string ->
    ('node Provenance.located -> 'node Provenance.located list Provenance.located matched) ->
    'node t ->
    'node t

  (** A rule can reuse the reader to extract values from child nodes. *)
  val read : 'node reader -> 'a Syntax.Args.value -> 'node Provenance.located ->
    'a Provenance.located matched

  val reader : 'node t -> 'node reader

  (** A named field before its value has been read. *)
  type 'node field = {
    name : string Provenance.located;
    value : 'node Provenance.located;
  }

  (** Read named fields using the declaration. Keep order and duplicates for
      Frontend decoding. Report unknown fields and unreadable values here. *)
  val read_arguments :
    'node reader -> 'args Syntax.Action.t -> 'node field list ->
    (Payload.field list, Diagnostic.t list) result

  (** Use the same readers for metadata fields described by a record schema.
      A dotted key such as [capture.type] writes a field of a record field,
      so [:CAPTURE.TYPE:] and [capture = { type = ... }] read alike. *)
  val read_metadata :
    'node reader -> Schema.field list -> 'node field list ->
    (Payload.field list, Diagnostic.t list) result
end

module Identity_rules : sig
  (** Identity rules run at declarations, such as a note heading. *)
  type 'node t

  val empty : 'node t

  (** Raises [Invalid_argument] if the name is taken. *)
  val register :
    name:string ->
    ('node Provenance.located -> Graph.Vertex_id.t Provenance.located matched) ->
    'node t ->
    'node t

  (** Raises [Invalid_argument] if there is no rule of this name. *)
  val replace :
    name:string ->
    ('node Provenance.located -> Graph.Vertex_id.t Provenance.located matched) ->
    'node t ->
    'node t

  val read : 'node t -> 'node Provenance.located -> Graph.Vertex_id.t Provenance.located matched
end

module Action_rules : sig
  (** An action found in a body, and the source it takes out of the
      surrounding text. [taken = None] takes nothing. *)
  type occurrence = {
    call : Invocation.t Provenance.located;
    taken : Provenance.span option;
  }

  (** Action rules run in a note body. Each rule is a syntax sugar, named for
      the form it reads, such as ["at-reference"]; several sugars may write
      the same action. The context supplies the lookups and value readers the
      adapter makes available to its rules. Later rules run first. *)
  type ('node, 'context) t

  val empty : ('node, 'context) t

  (** Raises [Invalid_argument] if the sugar is taken. *)
  val register :
    sugar:string ->
    ('node Provenance.located -> 'context -> occurrence matched) ->
    ('node, 'context) t ->
    ('node, 'context) t

  (** Override a sugar in place. Raises [Invalid_argument] if there is none,
      so a misspelled override cannot pass silently. *)
  val replace :
    sugar:string ->
    ('node Provenance.located -> 'context -> occurrence matched) ->
    ('node, 'context) t ->
    ('node, 'context) t

  (** Register a sugar that reads the arguments of an action. The call is
      located at the node; it takes [taken node], the node's span by default. *)
  val bind :
    sugar:string ->
    ?taken:('node Provenance.located -> Provenance.span option) ->
    'args Syntax.Action.t ->
    ('node Provenance.located -> 'context -> 'args matched) ->
    ('node, 'context) t ->
    ('node, 'context) t

  (** [bind], overriding an existing sugar. *)
  val rebind :
    sugar:string ->
    ?taken:('node Provenance.located -> Provenance.span option) ->
    'args Syntax.Action.t ->
    ('node Provenance.located -> 'context -> 'args matched) ->
    ('node, 'context) t ->
    ('node, 'context) t

  val read : ('node, 'context) t -> 'context -> 'node Provenance.located ->
    occurrence matched

  (** A body span of [source]: verbatim text around the actions read from its
      nodes, in node order. An action stands at the start of what it takes;
      with nothing taken, at its call's position, keeping the text there; an
      unlocated call follows the preceding content.

      A node may arrive already known to be unreadable ([Error]). Such a node,
      a rule answering [Invalid], or an action placed outside the body or over
      a preceding one becomes an unreadable action at its start, keeping its
      text. The body is always assembled; its failures stay in place. *)
  val body :
    ('node, 'context) t -> 'context -> source:Text.t -> Provenance.span ->
    ('node, Diagnostic.t list) result Provenance.located list ->
    Invocation.t Frontend.read Observation.Source.content Provenance.located list

  (** Resolve the name and extract the arguments of a named call. *)
  val named :
    ('metadata, 'action) Syntax.Frontend_input.t ->
    'node Payload_rules.reader ->
    name:string Provenance.located ->
    'node Payload_rules.field list ->
    (Invocation.t, Diagnostic.t list) result
end
```
]

#chunk(id: <file-syntax-rules-mli>, target: "syntax/rules.mli")[
```ocaml
<<source-syntax-rules-mli>>
```
]
