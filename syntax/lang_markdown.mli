open Ospero_kernel
val language : Text.Language.t
type value = Value.t
type metadata = {
  fields : Value.field list;
  diagnostics : Frontend.Diagnostic.t list;
  insertion : Provenance.span;
}
type heading = {
  level : int;
  title : string Provenance.located;
  metadata : metadata option;
}
type node =
  | Directive of {
      name : string Provenance.located;
      arguments : Value.field list Frontend.read;
      body : Text.t Provenance.located option;
      inner : node Provenance.located list;
    }
  | Card of Card.nested

type context = value Card.context

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
  val nested_card :
    'args Syntax.Action.t ->
    (contents:Text.t Provenance.located -> depth:int Provenance.located -> 'args) ->
    (node, context) Rules.Action_rules.t -> (node, context) Rules.Action_rules.t
end
