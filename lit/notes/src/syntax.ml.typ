#import "/reader/book.typ": chunk

= syntax.ml <core:src:syntax.ml>

#chunk(id: <source-core-src-syntax-ml>)[
```ocaml
open Frontend

module Args = struct
  type _ value =
    | String : string value
    | Bool : bool value
    | Int : int value
    | Contents : Text.t value
    | List : 'a value -> 'a Provenance.located list value
    | Record : Payload.field list value
    | Map : { carrier : 'a value; schema : 'b Schema.t; encode : 'b -> 'a } -> 'b value

  let string = String
  let bool = Bool
  let int = Int
  let contents = Contents
  let list item = List item
  let record = Record

  (* A plain record descriptor carries the original field occurrences. *)
  let rec schema : type a. a value -> a Schema.t = function
    | String -> Schema.string
    | Bool -> Schema.bool
    | Int -> Schema.int
    | Contents -> Schema.map (fun item -> item.Provenance.value) Schema.contents
    | List item -> Schema.list (Schema.located (schema item))
    | Record -> Schema.record_payload
    | Map refined -> refined.schema

  (* The vocabulary is spelled by the declarer, so values are never compared. *)
  let choice ~spell values =
    let choices = List.map (fun value -> spell value, value) values in
    let rec distinct = function
      | [] -> ()
      | (name, _) :: rest ->
          if List.mem_assoc name rest then
            invalid_arg ("Syntax.Args.choice: " ^ name ^ " is spelled twice");
          distinct rest
    in
    distinct choices;
    Map { carrier = String; schema = Schema.choice choices; encode = spell }

  let refine decode ~encode carrier =
    Map { carrier; schema = Schema.refine decode (schema carrier); encode }

  (* Each list element carries its own span, independently of the list span. *)
  let rec encode : type a. a value -> a Provenance.located -> Payload.t =
    fun descriptor occurrence ->
      let carry (value : Payload.value) = { occurrence with value } in
      match descriptor with
      | String -> carry (String occurrence.value)
      | Bool -> carry (Bool occurrence.value)
      | Int -> carry (Int occurrence.value)
      | Contents -> carry (Contents occurrence.value)
      | List item -> carry (List (List.map (encode item) occurrence.value))
      | Record -> carry (Record occurrence.value)
      | Map refined ->
          encode refined.carrier { occurrence with value = refined.encode occurrence.value }

  type _ items = Items : 'b value -> 'b Provenance.located list items

  (* A refined list is read as its carrier first, so only plain lists match. *)
  let items : type a. a value -> a items option = function
    | List item -> Some (Items item)
    | _ -> None

  type packed = Value : 'a value -> packed

  let rec carrier : type a. a value -> packed = function
    | String -> Value String
    | Bool -> Value Bool
    | Int -> Value Int
    | Contents -> Value Contents
    | Record -> Value Record
    | Map refined -> carrier refined.carrier
    | List item ->
        let Value item = carrier item in
        Value (List item)

  (* String choices affect decoding, but use the same string reader. *)
  let rec of_shape : Schema.shape -> packed = function
    | String _ -> Value string
    | Bool -> Value bool
    | Int -> Value int
    | Contents -> Value contents
    | Record _ -> Value record
    | List shape ->
        let Value item = of_shape shape in
        Value (list item)

  type (_, _) equality = Equal : ('a, 'a) equality

  let rec equal : type a b. a value -> b value -> (a, b) equality option =
    fun expected actual ->
      match expected, actual with
      | String, String -> Some Equal
      | Bool, Bool -> Some Equal
      | Int, Int -> Some Equal
      | Contents, Contents -> Some Equal
      | Record, Record -> Some Equal
      | List expected, List actual ->
          (match equal expected actual with
           | Some Equal -> Some Equal
           | None -> None)
      | _ -> None

  type ('args, 'a) fields = {
    values : (string * packed) list;
    read : 'a Schema.fields;
    write : 'args -> Payload.field list;
  }

  type 'args t = {
    values : (string * packed) list;
    schema : 'args Schema.t;
    write : 'args -> Payload.field list;
  }

  let empty = { values = []; read = Schema.no_fields; write = (fun _ -> []) }

  (* Each declaration uses the same descriptor for rule lookup and encoding. *)
  let field name descriptor read get =
    let write args =
      match get args with
      | None -> []
      | Some value ->
          [ { Payload.name = Provenance.located name;
              value = encode descriptor value } ]
    in
    { values = [ name, Value descriptor ]; read; write }

  let required name descriptor ~get =
    let read = Schema.required name (Schema.located (schema descriptor)) in
    field name descriptor read (fun args -> Some (get args))

  let optional name descriptor ~get =
    let read = Schema.option name (Schema.located (schema descriptor)) in
    field name descriptor read get

  let ( let+ ) fields make =
    { fields with read = Schema.(let+ ) fields.read make }

  let ( and+ ) (left : (_, _) fields) (right : (_, _) fields) =
    { values = left.values @ right.values;
      read = Schema.(and+ ) left.read right.read;
      write = (fun args -> left.write args @ right.write args) }

  let spec (fields : (_, _) fields) =
    { values = fields.values; schema = Schema.record fields.read; write = fields.write }
end

module Action = struct
  type 'args t = { name : string; input : 'args Args.t }
  type packed = Pack : 'args t -> packed

  let declare ~name input = { name; input }
  let name action = action.name
  let describe action = Schema.describe action.input.schema
  let parameters action = action.input.values

  (* Sugar synthesizes the name while its arguments retain their original spans. *)
  let invocation ?span action args =
    { Invocation.name = Provenance.located ?span action.name;
      arguments = action.input.write args }
end

module Frontend_input = struct
  (* Keep the input type tied to its semantic constructor in each entry. *)
  type 'action entry =
    | Entry : { declaration : 'args Action.t;
                decode : 'args -> ('action, Diagnostic.t list) result } -> 'action entry

  type ('metadata, 'action) t = {
    metadata : 'metadata Schema.t;
    actions : (string * 'action entry) list;
  }

  let action declaration ~decode = Entry { declaration; decode }
  let entry_name (Entry { declaration; _ }) = Action.name declaration

  let add entry input =
    let name = entry_name entry in
    if List.mem_assoc name input.actions then
      invalid_arg ("Syntax.Frontend_input: action " ^ name ^ " is already declared");
    { input with actions = input.actions @ [ name, entry ] }

  let replace entry input =
    let name = entry_name entry in
    if not (List.mem_assoc name input.actions) then
      invalid_arg ("Syntax.Frontend_input: no action " ^ name ^ " to replace");
    { input with actions =
        List.map (fun (key, old) -> key, if key = name then entry else old) input.actions }

  let create ~metadata entries =
    List.fold_left (fun input entry -> add entry input) { metadata; actions = [] } entries

  let find_action input name =
    match List.assoc_opt name input.actions with
    | None -> None
    | Some (Entry entry) -> Some (Action.Pack entry.declaration)

  let action_names input = List.map fst input.actions
  let metadata_shape input = Schema.describe input.metadata
  let decode_metadata input = Schema.decode input.metadata

  (* The arguments decode as a record located at the call's name. *)
  let decode_action input (invocation : Invocation.t) =
    let name = invocation.name in
    match List.assoc_opt name.value input.actions with
    | None ->
        Error [ Diagnostic.make ?span:name.span
          (Unknown_action { name = name.value; known = action_names input }) ]
    | Some (Entry { declaration; decode }) ->
        let arguments =
          Provenance.located ?span:name.span (Payload.Record invocation.arguments)
        in
        Result.bind (Schema.decode declaration.input.schema arguments) decode
end

type 'native document = {
  file : string;
  language : Text.Language.t;
  native : 'native;
}

type raw_note = Frontend.raw_note

type extracted = {
  notes : raw_note Provenance.located list;
  declared : Graph.Vertex_id.t Provenance.located list;
  diagnostics : Diagnostic.t list;
}

type 'native adapter = {
  language : Text.Language.t;
  extract : 'native document -> extracted;
  contents :
    Text.t Provenance.located -> (raw_note Provenance.located, Diagnostic.t list) result;
}

type 'native config = 'native adapter list

let configure adapters =
  List.iteri (fun index adapter ->
    let earlier = List.filteri (fun i _ -> i < index) adapters in
    if List.exists (fun other -> Text.Language.equal other.language adapter.language) earlier then
      invalid_arg ("Syntax.configure: two adapters for "
                   ^ Text.Language.to_string adapter.language))
    adapters;
  adapters

let unsupported ?span language =
  let message = "no syntax adapter for " ^ Text.Language.to_string language in
  Error [ Diagnostic.make ?span (Invalid message) ]

let with_adapter config ?span language run =
  match List.find_opt (fun adapter -> Text.Language.equal adapter.language language) config with
  | Some adapter -> run adapter
  | None -> unsupported ?span language

(* A document without an adapter contributes only its diagnostic. *)
let extract config document =
  let span = { Provenance.file = document.file; start = 0; stop = 0 } in
  match with_adapter config ~span document.language (fun adapter -> Ok (adapter.extract document)) with
  | Ok extracted -> extracted
  | Error diagnostics -> { notes = []; declared = []; diagnostics }

let parse_contents config (contents : Text.t Provenance.located) =
  with_adapter config ?span:contents.span contents.value.language
    (fun adapter -> adapter.contents contents)

(* Initial notes and nested declarations share the batch's identity list. *)
let parse_project config documents =
  let gather (notes, identities, diagnostics) document =
    let batch = extract config document in
    let roots = List.map (fun note -> note.Provenance.value.Observation.Source.id.Provenance.value) batch.notes in
    let declared = List.map (fun id -> id.Provenance.value) batch.declared in
    List.rev_append batch.notes notes,
    List.rev_append declared (List.rev_append roots identities),
    List.rev_append batch.diagnostics diagnostics
  in
  let notes, identities, diagnostics = List.fold_left gather ([], [], []) documents in
  { Observation.notes = List.rev notes; identities = List.rev identities },
  List.rev diagnostics
```
]

#chunk(id: <file-core-src-syntax-ml>, target: "core/src/syntax.ml")[
```ocaml
<<source-core-src-syntax-ml>>
```
]
