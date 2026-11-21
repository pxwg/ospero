open Ospero_kernel
val language : Text.Language.t
type value = Value.t
type heading = {
  level : int;
  title : string Provenance.located;
  label : string Provenance.located option;
  metadata : Value.field list Frontend.read option;
}
type node =
  | Call of {
      name : string Provenance.located;
      arguments : argument list;
      trailing : Text.t Provenance.located list;
      inner : node Provenance.located list;
    }
  | Reference of {
      target : string Provenance.located;
      supplement : Text.t Provenance.located option;
          (** Omitted and empty supplements are both [None]. *)
    }
  | Card of Card.nested
  | Label of string
  | Statement of {
      keyword : string;
      path : string Provenance.located option;
    }

and argument = {
  name : string Provenance.located option;
  value : value Provenance.located;
}
type context = value Card.context

val scan : file:string -> string -> (heading, value, node) Card.outline

val children : node -> node Provenance.located list
val values : value Rules.Payload_rules.t

val identities : heading Rules.Identity_rules.t

val actions : (node, context) Rules.Action_rules.t

val adapter :
  ?values:value Rules.Payload_rules.t ->
  ?identities:heading Rules.Identity_rules.t ->
  ?actions:(node, context) Rules.Action_rules.t ->
  ?define:string ->
  ('metadata, 'action) Syntax.Frontend_input.t ->
  string Syntax.adapter
module Sugar : sig
  val references :
    'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t

  val include_note :
    'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t

  val nested_card :
    'args Syntax.Action.t ->
    (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
end
