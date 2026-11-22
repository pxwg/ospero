#import "/reader/book.typ": card-source, chunk
#show: card-source

= card.mli <syntax:card.mli>

#chunk(id: <source-syntax-card-mli>)[
```ocaml
(** The card structure shared by language adapters. A scanner reports
    headings and body nodes; this layer decides which headings declare cards,
    nests them, reads metadata and assembles bodies with the rule tables.
    Contents of a [define] call are read back by the same language, so
    pre-registration and expansion take the ID from the same declaration.
    An adapter over another parser, such as a cached Org tree, supplies its
    own [language] and reuses the rest. *)
open Ospero_kernel
open Frontend

(** A nested card seen as a body node. [extent] runs from the card's first
    metadata line, or its heading, to the end of its last descendant. *)
type nested = { level : int; extent : Provenance.span }

(** What a body rule may use. [values] and [named] are the adapter's own, so a
    sugar reads values exactly as named calls do. *)
type 'value context = {
  level : int;  (** The heading level of the card whose body is read. *)
  slice : Provenance.span -> Text.t Provenance.located;
      (** Source text of a span, tagged with the adapter's language. *)
  values : 'value Rules.Payload_rules.reader;
  named :
    name:string Provenance.located -> ?body:Text.t Provenance.located ->
    'value Rules.Payload_rules.field list -> (Invocation.t, Diagnostic.t list) result;
      (** Resolve a named call. A trailing body is passed to the one parameter
          the action declares with [Args.contents]. *)
}

(** A heading reported by a scanner. Identity rules read [identity]; when one
    matches, the heading declares a card. Metadata the scanner could not read
    is [Error]; the card is still declared and its metadata reported. *)
type ('heading, 'value) heading = {
  level : int;
  identity : 'heading Provenance.located;
  title : Provenance.span;
  metadata : 'value Rules.Payload_rules.field list Frontend.read;
  metadata_span : Provenance.span option;
  start : int;  (** Where the card begins, including metadata written before it. *)
  body_start : int;  (** Where the body begins, after heading and metadata. *)
}

(** Everything a scanner finds in one text, in source order. [nodes] contains
    the nodes outside headings' metadata, nested nodes being reachable through
    [children]. *)
type ('heading, 'value, 'node) outline = {
  headings : ('heading, 'value) heading list;
  nodes : 'node Provenance.located list;
  closes : int list;
      (** Explicit card ends, in source order; each closes the innermost card
          still open where it stands. *)
}

type ('native, 'heading, 'value, 'node) language = {
  language : Text.Language.t;
  source : 'native -> string;
      (** The text the native document was read from. Spans index it. *)
  scan : file:string -> 'native -> ('heading, 'value, 'node) outline;
      (** Read a whole document. A scanner reports problems in the construct
          they belong to, such as unreadable metadata, and never gives up on
          the document. *)
  read : file:string -> string -> start:int -> ('heading, 'value, 'node) outline;
      (** Read Contents in place: scan from [start] to the end of the text,
          which is padded with newlines so that spans stay file offsets. *)
  nested : nested -> 'node;
  children : 'node -> 'node Provenance.located list;
      (** Nodes inside a node, read in its place when no body rule takes it. *)
}

(** Calls of the action named [define] have their Contents arguments read
    as cards whose IDs are pre-registered. With [~unknown_metadata:`Ignore],
    metadata fields the schema does not declare are dropped instead of
    reported.

    Failures degrade only their card. A heading whose identity rule answers
    [Invalid] declares no card and stays a section of the enclosing card,
    where its diagnostics stand as an unreadable action; outside every card
    they are document diagnostics. Unreadable metadata and body constructs
    stay in their note. Raises [Invalid_argument] unless the metadata schema
    describes a record. *)
val adapter :
  ('native, 'heading, 'value, 'node) language ->
  ?unknown_metadata:[ `Ignore | `Report ] ->
  values:'value Rules.Payload_rules.t ->
  identities:'heading Rules.Identity_rules.t ->
  actions:('node, 'value context) Rules.Action_rules.t ->
  define:string ->
  ('metadata, 'action) Syntax.Frontend_input.t ->
  'native Syntax.adapter

(** Bind nested cards to a define action, as the sugar ["nested-card"]. The
    Contents cover the card's metadata, heading and body; the depth is the
    difference of heading levels. *)
val nested_card :
  ('node -> nested option) ->
  'args Syntax.Action.t ->
  (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
  ('node, 'value context) Rules.Action_rules.t ->
  ('node, 'value context) Rules.Action_rules.t

(** A diagnostic at a span. *)
val invalid : ?span:Provenance.span -> string -> Diagnostic.t
```
]

#chunk(id: <file-syntax-card-mli>, target: "syntax/card.mli")[
```ocaml
<<source-syntax-card-mli>>
```
]
