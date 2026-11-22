#import "/reader/book.typ": card-source, chunk
#show: card-source

= policy_report.ml <core:src:policy_report.ml>

#chunk(id: <source-core-src-policy-report-ml>)[
```ocaml
module Id_map = Map.Make (struct
  type t = Failure.id
  let compare = Failure.compare
end)
module Id_set = Set.Make (struct
  type t = Failure.id
  let compare = Failure.compare
end)
module Card_map = Map.Make (Graph.Vertex_id)
module Invocation_map = Map.Make (Policy.Invocation_id)

type ('observation_error, 'policy_issue) entry =
  | Syntax of (unit, Frontend.Diagnostic.t) Failure.t
  | Observation of 'observation_error Observation.failure
  | Policy of 'policy_issue Policy.failure

type integrity_issue =
  | Duplicate_record of Failure.id
  | Missing_cause of { record : Failure.id; cause : Failure.id }

type ('observation_error, 'policy_issue) t = {
  entries : ('observation_error, 'policy_issue) entry list;
  by_id : ('observation_error, 'policy_issue) entry Id_map.t;
  by_card : ('observation_error, 'policy_issue) entry list Card_map.t;
  by_invocation : ('observation_error, 'policy_issue) entry list Invocation_map.t;
  effects : Failure.id list Id_map.t;
  roots : ('observation_error, 'policy_issue) entry list;
  integrity_issues : integrity_issue list;
}

type ('observation_error, 'policy_issue) impact = {
  entries : ('observation_error, 'policy_issue) entry list;
  edges : (Failure.id * Failure.id) list;
}

let id = function
  | Syntax record -> record.Failure.id
  | Observation record -> record.Failure.id
  | Policy record -> record.Failure.id

let causes = function
  | Syntax record -> record.Failure.causes
  | Observation record -> record.Failure.causes
  | Policy record -> record.Failure.causes

let card = function
  | Observation record -> Some (Observation.failure_owner record)
  | Policy { subject = Policy.Product (_, product); _ } -> Some product.card
  | Policy { subject = Policy.Invocation _; _ } | Syntax _ -> None

let invocation = function
  | Policy { subject = Policy.Invocation id | Policy.Product (id, _); _ } -> Some id
  | Syntax _ | Observation _ -> None

let prepend value = function
  | None -> Some [value]
  | Some values -> Some (value :: values)

let make entries =
  let by_id, unique, duplicates = List.fold_left (fun (by_id, unique, duplicates) entry ->
    let key = id entry in
    if Id_map.mem key by_id then by_id, unique, Duplicate_record key :: duplicates
    else Id_map.add key entry by_id, entry :: unique, duplicates)
    (Id_map.empty, [], []) entries in
  let entries = List.rev unique in
  let by_card, by_invocation, effects, roots, missing =
    List.fold_left (fun (by_card, by_invocation, effects, roots, missing) entry ->
      let by_card = match card entry with
        | None -> by_card
        | Some card -> Card_map.update card (prepend entry) by_card in
      let by_invocation = match invocation entry with
        | None -> by_invocation
        | Some invocation -> Invocation_map.update invocation (prepend entry) by_invocation in
      let record = id entry in
      let causes = List.sort_uniq Failure.compare (causes entry) in
      let effects, missing = List.fold_left (fun (effects, missing) cause ->
        if Id_map.mem cause by_id then Id_map.update cause (prepend record) effects, missing
        else effects, Missing_cause { record; cause } :: missing) (effects, missing) (List.rev causes) in
      let roots = if causes = [] then entry :: roots else roots in
      by_card, by_invocation, effects, roots, missing)
      (Card_map.empty, Invocation_map.empty, Id_map.empty, [], []) unique in
  { entries; by_id; by_card; by_invocation; effects; roots;
    integrity_issues = List.rev_append duplicates missing }

let of_evaluation ~syntax ~observation ~outcomes =
  let read = List.mapi (fun ordinal detail ->
    Syntax { Failure.id = Failure.syntax ordinal; subject = (); detail; causes = [] }) syntax in
  let observed = List.map (fun record -> Observation record)
      (Observation.failure_records observation) in
  let computed = List.concat_map (fun (_, outcome) ->
    List.map (fun record -> Policy record) outcome.Policy.records) outcomes in
  make (read @ observed @ computed)

let entries (report : (_, _) t) = report.entries
let roots report = report.roots
let integrity_issues report = report.integrity_issues
let find report id = Id_map.find_opt id report.by_id
let for_card report card = Card_map.find_opt card report.by_card |> Option.value ~default:[]
let for_invocation report id =
  Invocation_map.find_opt id report.by_invocation |> Option.value ~default:[]

let impact report origin =
  Option.map (fun origin_entry ->
    let pending = Queue.create () in
    Queue.add origin_entry pending;
    let rec visit seen entries edges =
      match Queue.take_opt pending with
      | None -> { entries = List.rev entries; edges = List.rev edges }
      | Some entry ->
          let source = id entry in
          let children = Id_map.find_opt source report.effects |> Option.value ~default:[] in
          let seen, edges = List.fold_left (fun (seen, edges) child ->
            let edges = (source, child) :: edges in
            if Id_set.mem child seen then seen, edges
            else begin
              Queue.add (Id_map.find child report.by_id) pending;
              Id_set.add child seen, edges
            end) (seen, edges) children in
          visit seen (entry :: entries) edges
    in
    visit (Id_set.singleton origin) [] []) (find report origin)
```
]

#chunk(id: <file-core-src-policy-report-ml>, target: "core/src/policy_report.ml")[
```ocaml
<<source-core-src-policy-report-ml>>
```
]
