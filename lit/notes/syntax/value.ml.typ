#import "/reader/book.typ": card-source, chunk
#show: card-source

= value.ml <syntax:value.ml>

#chunk(id: <source-syntax-value-ml>)[
```ocaml
open Ospero_kernel
open Frontend
module Payload_rules = Rules.Payload_rules

type t =
  | String of string
  | Int of int
  | Bool of bool
  | Array of t Provenance.located list
  | Table of field list
  | Contents of Text.t
  | Label of string
  | Other of string

and field = string Provenance.located * t Provenance.located

let fields = List.map (fun (name, value) -> { Payload_rules.name; value })

(* A record field has no declaration of its own, so its value keeps the shape
   it was written in. *)
let rec payload (value : t Provenance.located) : (Payload.t, Diagnostic.t list) result =
  let carry (v : Payload.value) = Ok { value with Provenance.value = v } in
  match value.value with
  | String s -> carry (String s)
  | Int i -> carry (Int i)
  | Bool b -> carry (Bool b)
  | Contents c -> carry (Contents c)
  | Array items ->
      Result.map (fun items -> { value with value = Payload.List items }) (all payload items)
  | Table entries ->
      Result.map (fun fields -> { value with value = Payload.Record fields }) (record entries)
  | Label _ | Other _ ->
      Error [ Diagnostic.make ?span:value.span (Invalid "this value has no static reading") ]

and record entries =
  all (fun (name, value) ->
    Result.map (fun value -> { Payload.name; value }) (payload value)) entries

and all : 'a 'b. ('a -> ('b, Diagnostic.t list) result) -> 'a list -> ('b list, Diagnostic.t list) result =
  fun f items ->
    let results = List.map f items in
    match List.concat_map (function Error e -> e | Ok _ -> []) results with
    | [] -> Ok (List.filter_map Result.to_option results)
    | errors -> Error errors

let scalar read = fun (node : t Provenance.located) _ ->
  match read node.value with
  | Some value -> Rules.Matched { node with value }
  | None -> Rules.No_match

let rules =
  let open Payload_rules in
  empty
  |> register ~name:"string" ~value:Syntax.Args.string
       (scalar (function String s -> Some s | _ -> None))
  |> register ~name:"int" ~value:Syntax.Args.int
       (scalar (function Int i -> Some i | _ -> None))
  |> register ~name:"bool" ~value:Syntax.Args.bool
       (scalar (function Bool b -> Some b | _ -> None))
  |> register ~name:"contents" ~value:Syntax.Args.contents
       (scalar (function Contents c -> Some c | _ -> None))
  |> register_items ~name:"array" (fun node ->
       match node.value with
       | Array items -> Matched { node with value = items }
       | _ -> No_match)
  |> register ~name:"table" ~value:Syntax.Args.record (fun node _ ->
       match node.value with
       | Table entries ->
           (match record entries with
            | Ok fields -> Matched { node with value = fields }
            | Error errors -> Invalid errors)
       | _ -> No_match)
```
]

#chunk(id: <file-syntax-value-ml>, target: "syntax/value.ml")[
```ocaml
<<source-syntax-value-ml>>
```
]
