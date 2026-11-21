open Ospero_kernel
open Frontend
val language : Text.Language.t
type value = string
type heading = {
  level : int;
  title : string Provenance.located;
  properties : (string Provenance.located * value Provenance.located) list;
}
type node =
  | Keyword of {
      name : string Provenance.located;
      value : value Provenance.located;
      inner : node Provenance.located list;
    }
  | Block of {
      name : string Provenance.located;
      parameters : value Provenance.located;
      contents : Text.t Provenance.located;
      inner : node Provenance.located list;
    }
  | Link of {
      path : string Provenance.located;
      description : string Provenance.located option;
    }
  | Card of Card.nested

type context = value Card.context
val scan : file:string -> string -> (heading, value, node) Card.outline
val children : node -> node Provenance.located list

val values : value Rules.Payload_rules.t
val identities : heading Rules.Identity_rules.t
val actions : (node, context) Rules.Action_rules.t
val arguments :
  value Provenance.located ->
  (value Rules.Payload_rules.field list, Diagnostic.t list) result
val adapter :
  ?values:value Rules.Payload_rules.t ->
  ?identities:heading Rules.Identity_rules.t ->
  ?actions:(node, context) Rules.Action_rules.t ->
  ?define:string ->
  ?unknown_properties:[ `Ignore | `Report ] ->
  ('metadata, 'action) Syntax.Frontend_input.t ->
  string Syntax.adapter

module Sugar : sig
  val id_link :
    'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
  val include_keyword :
    'args Syntax.Action.t -> (string Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
  val nested_card :
    'args Syntax.Action.t ->
    (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
end
