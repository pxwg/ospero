module Invocation_id = struct
  type t = string

  let of_string value =
    if value = "" then Error "Invocation ID must not be empty"
    else Ok value

  let to_string value = value
  let compare = String.compare
end

module Output_map = Map.Make (String)
module Cause_set = Set.Make (struct
  type t = Failure.id
  let compare = Failure.compare
end)

type 'a availability =
  | Ready of 'a
  | Degraded of 'a * Failure.id
  | Unavailable of Failure.id

module State = struct
  type ('vertex, 'edge) output = {
    products : ('vertex availability, 'edge availability) Graph.t;
    graph : ('vertex, 'edge) Graph.t option Lazy.t;
    unavailable : Cause_set.t;
    degraded : Cause_set.t;
  }

  type ('vertex, 'edge) t = {
    primary : ('vertex, 'edge) output;
    named : ('vertex, 'edge) output Output_map.t;
    observation_causes : (Observation.product -> Graph.Vertex_id.t -> Failure.id list) option;
  }

  let observation_causes state product id =
    Option.map (fun lookup -> lookup product id) state.observation_causes

  let output ?name state = match name with
    | None -> Some state.primary
    | Some name -> Output_map.find_opt name state.named

  let products ?name state = Option.map (fun o -> o.products) (output ?name state)
  let graph ?name state = Option.bind (output ?name state) (fun o -> Lazy.force o.graph)

  let vertex ?name state id =
    Option.bind (products ?name state) (fun graph -> Graph.find_vertex graph id)
    |> Option.map (fun vertex -> vertex.Graph.note)

  let edge ?name state id =
    Option.bind (products ?name state) (fun graph -> Graph.find_edge graph id)
    |> Option.map (fun edge -> edge.Graph.relation)
end

type 'issue error =
  | Failure of {
      invocation : Invocation_id.t;
      issues : 'issue list;
    }
  | Blocked of {
      invocation : Invocation_id.t;
      dependencies : Invocation_id.t list;
    }

type ('vertex, 'edge, 'issue) status =
  | Success of ('vertex, 'edge) State.t
  | Error of 'issue error

type product = {
  output : string option;
  target : Failure.target;
  card : Graph.Vertex_id.t;
}

type subject = Invocation of Invocation_id.t | Product of Invocation_id.t * product

type 'issue failure_detail =
  | Failed of 'issue error
  | Used_fallback
  | Used_degraded_input
  | Product_failed of 'issue list
  | Product_blocked

type 'issue failure = (subject, 'issue failure_detail) Failure.t

type ('vertex, 'edge, 'issue) outcome = {
  result : ('vertex, 'edge, 'issue) status;
  records : 'issue failure list;
}

type ('vertex, 'edge) assignment = {
  vertex : Graph.Vertex_id.t -> 'vertex;
  edge : Graph.Edge_id.t -> 'edge;
}

type ('value, 'issue) product_decision =
  | Produce of 'value
  | Derive of 'value * Failure.id list
  | Recover_product of 'value * Failure.id list
  | Reject_product of 'issue list
  | Block_product of Failure.id list

(* A value with the exceptional inputs it used, or the causes that leave it
   unavailable. Combinators accumulate causes, so callers never write them. *)
module Product = struct
  type 'a t =
    | Available of 'a * Cause_set.t
    | Unavailable of Cause_set.t

  let return value = Available (value, Cause_set.empty)

  let unavailable causes =
    if causes = [] then invalid_arg "Policy.Product.unavailable: no cause";
    Unavailable (Cause_set.of_list causes)

  let of_availability = function
    | Ready value -> return value
    | Degraded (value, cause) -> Available (value, Cause_set.singleton cause)
    | Unavailable cause -> Unavailable (Cause_set.singleton cause)

  let read kind = function
    | Some availability -> of_availability availability
    | None -> invalid_arg ("Policy.Product." ^ kind ^ ": unknown identity or output")

  let vertex ?name state id = read "vertex" (State.vertex ?name state id)
  let edge ?name state id = read "edge" (State.edge ?name state id)

  let map f = function
    | Available (value, causes) -> Available (f value, causes)
    | Unavailable causes -> Unavailable causes

  let bind product f =
    match product with
    | Unavailable causes -> Unavailable causes
    | Available (value, used) -> (
        match f value with
        | Available (value, more) -> Available (value, Cause_set.union used more)
        | Unavailable causes -> Unavailable causes)

  (* Both sides are read, so every unavailable input is cited. *)
  let both a b =
    match (a, b) with
    | Available (x, c), Available (y, d) -> Available ((x, y), Cause_set.union c d)
    | Unavailable c, Unavailable d -> Unavailable (Cause_set.union c d)
    | Unavailable c, Available _ | Available _, Unavailable c -> Unavailable c

  let all products =
    List.fold_right (fun p rest -> map (fun (x, xs) -> x :: xs) (both p rest)) products
      (return [])

  let ( let+ ) product f = map f product
  let ( and+ ) = both
  let ( let* ) = bind
  let ( and* ) = both

  let decide = function
    | Available (value, causes) when Cause_set.is_empty causes -> Produce value
    | Available (value, causes) -> Derive (value, Cause_set.elements causes)
    | Unavailable causes -> Block_product (Cause_set.elements causes)
end

type ('vertex, 'edge, 'issue) product_assignment =
  (('vertex, 'issue) product_decision, ('edge, 'issue) product_decision) assignment

type ('vertex, 'edge, 'issue) outputs = {
  primary : ('vertex, 'edge, 'issue) product_assignment;
  named : (string * ('vertex, 'edge, 'issue) product_assignment) list;
}

type (_, 'vertex, 'edge) ports =
  | Nil : (unit, 'vertex, 'edge) ports
  | Cons :
      ('p, 'vertex, 'edge) ports ->
      (('vertex, 'edge) Graph.t * 'p, 'vertex, 'edge) ports
  | Cons_state :
      ('p, 'vertex, 'edge) ports ->
      (('vertex, 'edge) State.t * 'p, 'vertex, 'edge) ports

type ('vertex, 'edge, 'issue) decision =
  | Apply of ('vertex, 'edge) assignment
  | Recover of ('vertex, 'edge) assignment * Failure.id list
  | Reject of 'issue list
  | Block_on of Failure.id list
  | Publish of ('vertex, 'edge, 'issue) outputs

type ('vertex, 'edge, 'issue) t = {
  arity : int;
  decide : ('vertex, 'edge) State.t list ->
    (('vertex, 'edge, 'issue) decision * Failure.id list, Failure.id list) result;
}

type ('vertex, 'edge, 'issue) invocation = {
  id : Invocation_id.t;
  inputs : Invocation_id.t list;
  definition : ('vertex, 'edge, 'issue) t;
}

(* Complete-graph ports consume their entire primary output. State ports let
   the rule attribute reads to individual products instead. *)
let rec decode_ports : type p v e. (p, v, e) ports -> (v, e) State.t list ->
    (p * Cause_set.t, Cause_set.t) result =
  fun ports states ->
    match ports, states with
    | Nil, [] -> Ok ((), Cause_set.empty)
    | Cons rest, state :: states ->
        let primary = state.State.primary in
        (match Lazy.force primary.graph, decode_ports rest states with
         | Some graph, Ok (tail, causes) ->
             Ok ((graph, tail), Cause_set.union primary.degraded causes)
         | Some _, Error causes -> Error causes
         | None, Ok _ -> Error primary.unavailable
         | None, Error causes -> Error (Cause_set.union primary.unavailable causes))
    | Cons_state rest, state :: states ->
        Result.map (fun (tail, causes) -> (state, tail), causes) (decode_ports rest states)
    | _ -> invalid_arg "Policy input count mismatch"

let rec port_count : type p v e. (p, v, e) ports -> int = function
  | Nil -> 0
  | Cons rest -> 1 + port_count rest
  | Cons_state rest -> 1 + port_count rest

let arity definition = definition.arity

let make_deciding ports decide =
  {
    arity = port_count ports;
    decide = (fun states ->
      match decode_ports ports states with
      | Ok (inputs, causes) -> Ok (decide inputs, Cause_set.elements causes)
      | Error causes -> Error (Cause_set.elements causes));
  }

let make ports ?(check = fun _ -> []) run =
  make_deciding ports (fun inputs ->
    match check inputs with
    | [] -> Apply (run inputs)
    | issues -> Reject issues)

let complete_output ?cause graph =
  let mark value = match cause with
    | None -> Ready value
    | Some cause -> Degraded (value, cause)
  in
  let products = Graph.map graph
    ~vertex:(fun vertex -> mark vertex.note)
    ~edge:(fun edge -> mark edge.relation) in
  { State.products;
    graph = lazy (Some graph);
    unavailable = Cause_set.empty;
    degraded = Option.fold ~none:Cause_set.empty ~some:Cause_set.singleton cause }

let initial ?observation_causes graph =
  { result = Success {
      primary = complete_output graph;
      named = Output_map.empty;
      observation_causes;
    };
    records = [] }

let require_causes = function
  | [] -> invalid_arg "Policy: this decision requires a direct cause"
  | causes -> causes

let materialize_products ~initial ~invocation ~inherited outputs =
  let invocation_name = Invocation_id.to_string invocation in
  let materialize output assignment =
    let records = ref [] in
    let unavailable = ref Cause_set.empty in
    let degraded = ref Cause_set.empty in
    let cell target card decision =
      let status detail causes value =
        let id = Failure.policy_product ~invocation:invocation_name ~output target in
        let subject = Product (invocation, { output; target; card }) in
        let causes = List.sort_uniq Failure.compare causes in
        records := { Failure.id; subject; detail; causes } :: !records;
        match value with
        | Some value ->
            degraded := Cause_set.add id !degraded;
            Degraded (value, id)
        | None ->
            unavailable := Cause_set.add id !unavailable;
            Unavailable id
      in
      match decision with
      | Produce value ->
          (match inherited with
           | [] -> Ready value
           | causes -> status Used_degraded_input causes (Some value))
      | Derive (value, causes) ->
          status Used_degraded_input (require_causes causes @ inherited) (Some value)
      | Recover_product (value, causes) ->
          status Used_fallback (require_causes causes @ inherited) (Some value)
      | Reject_product issues -> status (Product_failed issues) [] None
      | Block_product causes -> status Product_blocked (require_causes causes) None
    in
    let products = Graph.map initial
      ~vertex:(fun vertex ->
        cell (Failure.Vertex vertex.id) vertex.id (assignment.vertex vertex.id))
      ~edge:(fun edge ->
        cell (Failure.Edge edge.id) edge.source (assignment.edge edge.id)) in
    let unavailable = !unavailable in
    let graph = lazy (
      if Cause_set.is_empty unavailable then
        let value = function
          | Ready value | Degraded (value, _) -> value
          | Unavailable _ -> assert false
        in
        Some (Graph.map products ~vertex:(fun v -> value v.note)
          ~edge:(fun e -> value e.relation))
      else None)
    in
    { State.products; graph; unavailable; degraded = !degraded },
    List.rev !records
  in
  let named_assignments = List.fold_left (fun by_name (name, assignment) ->
    if Output_map.mem name by_name then invalid_arg "Policy: duplicate named output";
    Output_map.add name assignment by_name) Output_map.empty outputs.named in
  let primary, primary_records = materialize None outputs.primary in
  let named, records = Output_map.fold (fun name assignment (named, records) ->
    let output, found = materialize (Some name) assignment in
    Output_map.add name output named, List.rev_append found records)
    named_assignments (Output_map.empty, List.rev primary_records) in
  { result = Success { primary; named; observation_causes = None }; records = List.rev records }

let lift ~initial ~id definition =
  let invocation_record detail causes =
    { Failure.id = Failure.policy (Invocation_id.to_string id);
      subject = Invocation id;
      detail;
      causes = List.sort_uniq Failure.compare causes }
  in
  let fail error causes =
    { result = Error error; records = [invocation_record (Failed error) causes] }
  in
  let blocked dependencies causes = fail (Blocked { invocation = id; dependencies }) causes in
  let complete assignment records =
    let graph = Graph.map initial
      ~vertex:(fun vertex -> assignment.vertex vertex.id)
      ~edge:(fun edge -> assignment.edge edge.id) in
    let cause = match records with [] -> None | record :: _ -> Some record.Failure.id in
    let primary = complete_output ?cause graph in
    { result = Success { primary; named = Output_map.empty; observation_causes = None }; records }
  in
  Clone.operation definition.arity (fun inputs ->
    let states, dependencies, causes = List.fold_left
      (fun (states, dependencies, causes) input ->
        match input.result with
        | Success state -> state :: states, dependencies, causes
        | Error (Failure { invocation; _ } | Blocked { invocation; _ }) ->
            let causes = List.fold_left (fun causes record -> record.Failure.id :: causes)
              causes input.records in
            states, invocation :: dependencies, causes)
      ([], [], []) inputs in
    match dependencies with
    | _ :: _ -> blocked (List.sort_uniq Invocation_id.compare dependencies) causes
    | [] ->
        match definition.decide (List.rev states) with
        | Error causes -> blocked [] causes
        | Ok (decision, inherited) ->
            match decision with
            | Apply assignment ->
                let records = match inherited with
                  | [] -> []
                  | causes -> [invocation_record Used_degraded_input causes]
                in
                complete assignment records
            | Recover (assignment, causes) ->
                complete assignment [invocation_record Used_fallback (require_causes causes @ inherited)]
            | Reject issues -> fail (Failure { invocation = id; issues }) []
            | Block_on causes -> blocked [] (require_causes causes)
            | Publish outputs -> materialize_products ~initial ~invocation:id ~inherited outputs)
