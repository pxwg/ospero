type value = Dsl_syntax.value =
  | String of string
  | Int of int
  | Bool of bool
  | List of value Dsl_syntax.located list
  | Record of field list

and field = Dsl_syntax.field = {
  name : string Dsl_syntax.located;
  value : value Dsl_syntax.located;
}

type diagnostic = {
  range : Dsl_syntax.range;
  message : string;
}

(** Successful decoding produces a value of the project's OCaml type. *)
type 'a decoder =
  value Dsl_syntax.located -> ('a, diagnostic list) result

let expected (input : value Dsl_syntax.located) kind =
  Error [{ range = input.range; message = "Expected " ^ kind }]

let string : string decoder = fun input ->
  match input.value with
  | String value -> Ok value
  | _ -> expected input "a string"

let int : int decoder = fun input ->
  match input.value with
  | Int value -> Ok value
  | _ -> expected input "an integer"

let bool : bool decoder = fun input ->
  match input.value with
  | Bool value -> Ok value
  | _ -> expected input "a boolean"

let list (decode : 'a decoder) : 'a list decoder = fun input ->
  match input.value with
  | List elements ->
      let rec collect values errors failed = function
        | [] ->
            if failed then Error (List.rev errors)
            else Ok (List.rev values)
        | element :: rest ->
            match decode element with
            | Ok value -> collect (value :: values) errors failed rest
            | Error issues ->
                collect values (List.rev_append issues errors) true rest
      in
      collect [] [] false elements
  | _ -> expected input "a list"

type _ field_rule =
  | Required : string * 'a decoder -> 'a field_rule
  | Optional : string * 'a decoder -> 'a option field_rule
  | Default : string * 'a decoder * 'a -> 'a field_rule

let required name decode = Required (name, decode)
let optional name decode = Optional (name, decode)
let default name decode value = Default (name, decode, value)

(** Absence selects optional/default behavior; present values must decode. *)
let decode_field : type a.
    range:Dsl_syntax.range ->
    a field_rule ->
    value Dsl_syntax.located option ->
    (a, diagnostic list) result =
  fun ~range rule supplied ->
    match rule, supplied with
    | Required (name, _), None ->
        Error [{ range; message = Printf.sprintf "Missing field '%s'" name }]
    | Required (_, decode), Some value -> decode value
    | Optional _, None -> Ok None
    | Optional (_, decode), Some value -> Result.map Option.some (decode value)
    | Default (_, _, value), None -> Ok value
    | Default (_, decode, _), Some value -> decode value

type _ fields =
  | Nil : unit fields
  | Cons : 'a field_rule * 'b fields -> ('a * 'b) fields

module Name_map = Map.Make (String)
module Name_set = Set.Make (String)

let field_name : type a. a field_rule -> string = function
  | Required (name, _) -> name
  | Optional (name, _) -> name
  | Default (name, _, _) -> name

let rec schema_names : type a. Name_set.t -> a fields -> Name_set.t =
  fun names -> function
    | Nil -> names
    | Cons (rule, rest) ->
        let name = field_name rule in
        if Name_set.mem name names then
          invalid_arg (Printf.sprintf "Duplicate schema field '%s'" name);
        schema_names (Name_set.add name names) rest

let rec decode_fields : type a.
    range:Dsl_syntax.range ->
    a fields ->
    value Dsl_syntax.located Name_map.t ->
    (a, diagnostic list) result =
  fun ~range rules supplied ->
    match rules with
    | Nil -> Ok ()
    | Cons (rule, rest) ->
        let head =
          decode_field ~range rule (Name_map.find_opt (field_name rule) supplied)
        in
        let tail = decode_fields ~range rest supplied in
        match head, tail with
        | Ok value, Ok values -> Ok (value, values)
        | Error errors, Ok _ | Ok _, Error errors -> Error errors
        | Error first, Error rest -> Error (first @ rest)

(** Duplicate schema names raise Invalid_argument when constructing the decoder.
    Input diagnostics list structural errors first, then errors in schema order.
    The builder runs only after all fields pass validation. *)
let record rules build =
  let names = schema_names Name_set.empty rules in
  let decode : _ decoder = fun input ->
    match input.value with
    | Record fields ->
        let supplied, structural_errors =
          List.fold_left
            (fun (supplied, errors) (field : field) ->
              let name = field.name.value in
              let errors =
                if Name_set.mem name names then errors
                else { range = field.name.range;
                       message = Printf.sprintf "Unknown field '%s'" name }
                     :: errors
              in
              if Name_map.mem name supplied then
                (supplied,
                 { range = field.name.range;
                   message = Printf.sprintf "Duplicate field '%s'" name }
                 :: errors)
              else (Name_map.add name field.value supplied, errors))
            (Name_map.empty, []) fields
        in
        let structural_errors = List.rev structural_errors in
        let decoded = decode_fields ~range:input.range rules supplied in
        (match structural_errors, decoded with
         | [], Ok values -> Ok (build values)
         | errors, Ok _ -> Error errors
         | errors, Error field_errors -> Error (errors @ field_errors))
    | _ -> expected input "a record"
  in
  decode
