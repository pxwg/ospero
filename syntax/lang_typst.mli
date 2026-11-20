(** The default Typst adapter.

    A heading preceded by a [///] block declares a card: the block holds TOML
    metadata and the heading's trailing [<label>] is the card's ID. A named
    call is [#zk.review(target: "b")\[body\]]. Arguments are read statically:
    strings, booleans, integers, arrays, dictionaries, labels and content
    blocks. An argument that needs evaluation is reported. Raw text,
    comments, math and statements such as [#let] are skipped. *)
open Ospero_kernel

val language : Text.Language.t

type value = Value.t

(** The identity rules read this at each heading. [metadata] is [None]
    without a [///] block, and [Some (Error _)] when the block is not valid
    TOML; the heading still declares a card. *)
type heading = {
  level : int;
  title : string Provenance.located;
  label : string Provenance.located option;
  metadata : Value.field list Frontend.read option;
}

type node =
  | Call of {
      name : string Provenance.located;  (** The callee path, such as [zk.review]. *)
      arguments : argument list;
      trailing : Text.t Provenance.located list;  (** Content blocks after the arguments. *)
      inner : node Provenance.located list;  (** Nodes inside content blocks. *)
    }
  | Reference of {
      target : string Provenance.located;
      supplement : Text.t Provenance.located option;
          (** [@b\[shown\]]; an empty [\[\]] differs from none. *)
    }
  | Card of Card.nested

and argument = {
  name : string Provenance.located option;  (** [None] for a positional argument. *)
  value : value Provenance.located;
}

type context = value Card.context

val values : value Rules.Payload_rules.t

(** ["heading-label"]: the trailing label of a heading with a [///] block. *)
val identities : heading Rules.Identity_rules.t

(** ["named-call"]: calls through the [zk.] path. *)
val actions : (node, context) Rules.Action_rules.t

val adapter :
  ?values:value Rules.Payload_rules.t ->
  ?identities:heading Rules.Identity_rules.t ->
  ?actions:(node, context) Rules.Action_rules.t ->
  ?define:string ->
  ('metadata, 'action) Syntax.Frontend_input.t ->
  string Syntax.adapter

module Sugar : sig
  (** ["at-reference"] for [@b] and ["ref-call"] for [#ref(<b>)]. A
      supplement is taken with the reference and left to rendering. *)
  val references :
    'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t

  (** ["include-note"]: [#include-note\[@b\]]. *)
  val include_note :
    'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t

  (** ["nested-card"]: a card heading below the current card. *)
  val nested_card :
    'args Syntax.Action.t ->
    (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
end
