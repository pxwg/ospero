open Ospero_kernel
open Frontend
module Args = Syntax.Args

type 'a matched =
  | No_match
  | Matched of 'a
  | Invalid of Diagnostic.t list

(* Rules are tried in registration order, newest first. A rule that recognizes
   malformed input owns the diagnostic and stops the search. *)
let rec first_match run = function
  | [] -> No_match
  | (_, rule) :: rest ->
      match run rule with
      | No_match -> first_match run rest
      | matched -> matched

(* Names identify rules for overriding; a duplicate or a missing target is a
   configuration mistake, reported at once. *)
let add_rule table ~name rule rules =
  if List.mem_assoc name rules then
    invalid_arg (table ^ ": " ^ name ^ " is already registered");
  (name, rule) :: rules

let replace_rule table ~name rule rules =
  if not (List.mem_assoc name rules) then
    invalid_arg (table ^ ": no rule " ^ name ^ " to replace");
  List.map (fun (key, old) -> key, if key = name then rule else old) rules

module Payload_rules = struct
  (* The reader lets a rule use the same table for an element or child field. *)
  type 'node reader = {
    read : 'a. 'a Args.value -> 'node Provenance.located -> 'a Provenance.located matched;
  }

  type 'node rule =
    | Rule : 'a Args.value *
        ('node Provenance.located -> 'node reader -> 'a Provenance.located matched) ->
        'node rule
    | Items :
        ('node Provenance.located -> 'node Provenance.located list Provenance.located matched) ->
        'node rule

  type 'node t = (string * 'node rule) list

  let empty = []

  let register ~name ~value run = add_rule "Payload_rules" ~name (Rule (value, run))
  let replace ~name ~value run = replace_rule "Payload_rules" ~name (Rule (value, run))
  let register_items ~name split = add_rule "Payload_rules" ~name (Items split)

  (* Every element is read; diagnostics from all elements are kept. *)
  let read_items : type node b.
      node reader -> b Args.value -> node Provenance.located list Provenance.located ->
      b Provenance.located list Provenance.located matched =
    fun reader item elements ->
      let read_element index element =
        let at = [ Diagnostic.Index index ] in
        match reader.read item element with
        | Matched value -> Ok value
        | No_match ->
            Error [ Diagnostic.make ?span:element.Provenance.span ~path:at
              (Invalid "no Payload rule matched this list element") ]
        | Invalid errors ->
            Error (List.map (fun (error : Diagnostic.t) ->
              { error with path = at @ error.path }) errors)
      in
      let results = List.mapi read_element elements.value in
      match List.concat_map (function Error e -> e | Ok _ -> []) results with
      | [] -> Matched { elements with value = List.filter_map Result.to_option results }
      | errors -> Invalid errors

  (* Skip rules for other value types before calling their matchers. *)
  let run_rule : type node a.
      node reader -> a Args.value -> node Provenance.located -> node rule ->
      a Provenance.located matched =
    fun reader expected node -> function
      | Rule (actual, run) ->
          (match Args.equal expected actual with
           | Some Equal -> run node reader
           | None -> No_match)
      | Items split ->
          match Args.items expected with
          | None -> No_match
          | Some (Args.Items item) ->
              match split node with
              | No_match -> No_match
              | Invalid errors -> Invalid errors
              | Matched elements -> read_items reader item elements

  let reader rules =
    let rec reader = { read = (fun expected node ->
      first_match (run_rule reader expected node) rules) }
    in
    reader

  let read reader expected node = reader.read expected node

  type 'node field = {
    name : string Provenance.located;
    value : 'node Provenance.located;
  }

  (* Keep field order and repetitions so the decoder can report duplicates.
     A refined value is read as its carrier; Frontend checks the refinement. *)
  let read_fields reader inputs fields =
    let read_field field =
      let name = field.name in
      match List.assoc_opt name.value inputs with
      | None ->
          Error [ Diagnostic.make ?span:name.span
            (Unknown_field { name = name.value; known = List.map fst inputs }) ]
      | Some (Args.Value declared) ->
          let Args.Value expected = Args.carrier declared in
          let path = [ Diagnostic.Field name.value ] in
          match read reader expected field.value with
          | Matched value -> Ok { Payload.name; value = Args.encode expected value }
          | No_match ->
              Error [ Diagnostic.make ?span:field.value.span ~path
                (Invalid "no Payload rule matched this field value") ]
          | Invalid errors ->
              Error (List.map (fun (error : Diagnostic.t) ->
                { error with path = path @ error.path }) errors)
    in
    let rec collect values errors = function
      | [] -> if errors = [] then Ok (List.rev values) else Error (List.rev errors)
      | field :: rest ->
          match read_field field with
          | Ok value -> collect (value :: values) errors rest
          | Error found -> collect values (List.rev_append found errors) rest
    in
    collect [] [] fields

  let read_arguments reader action fields =
    read_fields reader (Syntax.Action.parameters action) fields

  let read_metadata reader schema fields =
    let inputs = List.map (fun (field : Schema.field) ->
      field.name, Args.of_shape field.shape) schema in
    read_fields reader inputs fields
end

module Identity_rules = struct
  type 'node t =
    (string * ('node Provenance.located -> Graph.Vertex_id.t Provenance.located matched)) list

  let empty = []
  let register ~name = add_rule "Identity_rules" ~name
  let replace ~name = replace_rule "Identity_rules" ~name

  (* A successful rule supplies the span of the declared ID. *)
  let read rules node = first_match (fun run -> run node) rules
end

module Action_rules = struct
  type occurrence = {
    call : Invocation.t Provenance.located;
    taken : Provenance.span option;
  }

  type ('node, 'context) t =
    (string * ('node Provenance.located -> 'context -> occurrence matched)) list

  let empty = []
  let register ~sugar = add_rule "Action_rules" ~name:sugar
  let replace ~sugar = replace_rule "Action_rules" ~name:sugar

  (* The sugar's node locates the call and its name; the arguments locate the values. *)
  let binding ?(taken = fun (node : _ Provenance.located) -> node.span) action extract =
    fun node context ->
      match extract node context with
      | No_match -> No_match
      | Invalid errors -> Invalid errors
      | Matched args ->
          let span = node.Provenance.span in
          let call = Syntax.Action.invocation ?span action args in
          Matched { call = Provenance.located ?span call; taken = taken node }

  let bind ~sugar ?taken action extract = register ~sugar (binding ?taken action extract)
  let rebind ~sugar ?taken action extract = replace ~sugar (binding ?taken action extract)

  (* The adapter supplies its lookup and value-reading context at the call site. *)
  let read rules context node = first_match (fun run -> run node context) rules

  (* The source an occurrence occupies: what it takes, else the point where its
     call stands. An unlocated call occupies nothing and joins at the cursor. *)
  let place { call; taken } =
    match taken, call.Provenance.span with
    | Some taken, _ -> Some taken
    | None, Some (at : Provenance.span) -> Some { at with stop = at.start }
    | None, None -> None

  (* The cursor only moves forward. Each placed action cuts the text up to its
     start and resumes after what it takes. *)
  let body rules context ~(source : Text.t) (span : Provenance.span) nodes =
    let problem (at : Provenance.span) message = Diagnostic.make ~span:at (Invalid message) in
    let text start stop =
      if start >= stop then []
      else
        let value = { source with text = String.sub source.text start (stop - start) } in
        [ Provenance.located ~span:{ span with start; stop } (Observation.Source.Text value) ]
    in
    let inside (at : Provenance.span) =
      at.file = span.file && span.start <= at.start && at.start <= at.stop && at.stop <= span.stop
    in
    let step (cursor, contents, errors) node =
      match read rules context node with
      | No_match -> cursor, contents, errors
      | Invalid found -> cursor, contents, List.rev_append found errors
      | Matched occurrence ->
          let action = Provenance.map (fun call -> Observation.Source.Action call) occurrence.call in
          match place occurrence with
          | None -> cursor, action :: contents, errors
          | Some at when not (inside at) ->
              cursor, contents, problem at "action source lies outside its body" :: errors
          | Some at when at.start < cursor ->
              cursor, contents, problem at "action source overlaps a preceding action" :: errors
          | Some at -> at.stop, action :: List.rev_append (text cursor at.start) contents, errors
    in
    if not (0 <= span.start && span.start <= span.stop && span.stop <= String.length source.text)
    then Error [ problem span "body span lies outside its source" ]
    else
      let cursor, contents, errors = List.fold_left step (span.start, [], []) nodes in
      match errors with
      | [] -> Ok (List.rev_append contents (text cursor span.stop))
      | _ -> Error (List.rev errors)

  (* The adapter finds the name and field boundaries. The declaration supplies
     the expected value descriptors for those fields. *)
  let named frontend reader ~(name : string Provenance.located) fields =
    match Syntax.Frontend_input.find_action frontend name.value with
    | None ->
        let known = Syntax.Frontend_input.action_names frontend in
        Error [ Diagnostic.make ?span:name.span (Unknown_action { name = name.value; known }) ]
    | Some (Syntax.Action.Pack action) ->
        Result.map (fun arguments -> { Invocation.name; arguments })
          (Payload_rules.read_arguments reader action fields)
end
