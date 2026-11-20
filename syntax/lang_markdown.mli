(** The default Markdown adapter.

    A heading followed by a [zk-meta] fence declares a card; the fence holds
    TOML metadata whose [id] is the card's ID. A named call is a [:::zk-review]
    container; a leading [toml zk-args] fence holds the arguments and the rest
    is the body. TOML arrays read as lists and tables as records. *)
open Ospero_kernel

val language : Text.Language.t

type value = Value.t

(** The identity rules read this at each heading. [metadata] is [None]
    without a [zk-meta] fence. *)
type heading = {
  level : int;
  title : string Provenance.located;
  metadata : Value.field list option;
}

type node =
  | Directive of {
      name : string Provenance.located;
      arguments : Value.field list;
      body : Text.t Provenance.located option;
      inner : node Provenance.located list;  (** Directives in the body. *)
    }
  | Card of Card.nested

type context = value Card.context

val values : value Rules.Payload_rules.t

(** ["meta-id"]: the [id] string of the [zk-meta] fence. *)
val identities : heading Rules.Identity_rules.t

(** ["named-directive"]: calls through the [zk-] prefix. *)
val actions : (node, context) Rules.Action_rules.t

val adapter :
  ?values:value Rules.Payload_rules.t ->
  ?identities:heading Rules.Identity_rules.t ->
  ?actions:(node, context) Rules.Action_rules.t ->
  ?define:string ->
  ('metadata, 'action) Syntax.Frontend_input.t ->
  string Syntax.adapter

module Sugar : sig
  (** ["nested-card"]: a card heading below the current card. *)
  val nested_card :
    'args Syntax.Action.t ->
    (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
end
