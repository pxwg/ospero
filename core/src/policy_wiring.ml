module Id = Policy.Invocation_id
module Id_set = Set.Make (Id)
module Id_map = Map.Make (Id)

type issue =
  | Duplicate_identity of Id.t
  | Port_count_mismatch of {
      invocation : Id.t;
      expected : int;
      actual : int;
    }
  | Missing_input of {
      invocation : Id.t;
      port : int;
      source : Id.t;
    }
  | Cyclic_dependencies of Id.t list

type ('vertex, 'edge, 'issue) compiled = {
  initial : ('vertex, 'edge) Graph.t;
  morphism : ('vertex, 'edge, 'issue) Policy.outcome Clone.morphism;
  outputs : Id.t list;
}

let validate input calls =
  let identities, duplicates =
    List.fold_left
      (fun (identities, issues) (call : _ Policy.invocation) ->
        if Id_set.mem call.id identities then
          identities, Duplicate_identity call.id :: issues
        else Id_set.add call.id identities, issues)
      (Id_set.singleton input, []) calls
  in
  let issues =
    List.fold_left
      (fun issues (call : _ Policy.invocation) ->
        let expected = call.definition.arity in
        let actual = List.length call.inputs in
        let issues =
          if expected = actual then issues
          else Port_count_mismatch { invocation = call.id; expected; actual } :: issues
        in
        List.fold_left
          (fun issues (port, source) ->
            if Id_set.mem source identities then issues
            else Missing_input { invocation = call.id; port; source } :: issues)
          issues (List.mapi (fun port source -> port, source) call.inputs))
      duplicates calls
  in
  List.rev issues

let compile ~initial ~input calls =
  match validate input calls with
  | _ :: _ as issues -> Error issues
  | [] ->
      let rec compose_layers slots outputs morphism pending =
        match pending with
        | [] -> Ok { initial; morphism; outputs }
        | _ ->
            let ready, waiting =
              List.partition
                (fun (call : _ Policy.invocation) ->
                  List.for_all (fun id -> Id_map.mem id slots) call.inputs)
                pending
            in
            match ready with
            | [] ->
                Error [Cyclic_dependencies (
                  List.map (fun (call : _ Policy.invocation) -> call.id) pending
                  |> List.sort Id.compare)]
            | _ ->
                let ready =
                  List.sort
                    (fun (a : _ Policy.invocation) (b : _ Policy.invocation) ->
                      Id.compare a.id b.id)
                    ready
                in
                let count = Clone.target morphism in
                let operations =
                  List.map
                    (fun (call : _ Policy.invocation) ->
                      let ports =
                        Clone.tuple count
                          (List.map
                            (fun id -> Clone.projection count (Id_map.find id slots))
                            call.inputs)
                      in
                      Clone.bind (Policy.lift ~initial ~id:call.id call.definition) ports)
                    ready
                in
                (* H = <pi_0, ..., pi_(m-1), h_1, ..., h_k>. *)
                let layer =
                  Clone.tuple count
                    (List.init count (Clone.projection count) @ operations)
                in
                let ids = List.map (fun (call : _ Policy.invocation) -> call.id) ready in
                let slots, _ =
                  List.fold_left
                    (fun (slots, slot) id -> Id_map.add id slot slots, slot + 1)
                    (slots, count) ids
                in
                (* F_next = H composed with F; projections reuse saved results. *)
                compose_layers slots (outputs @ ids)
                  (Clone.compose ~after:layer ~before:morphism) waiting
      in
      compose_layers (Id_map.singleton input 0) [input] (Clone.identity 1) calls

let evaluate compiled =
  Clone.apply compiled.morphism [Policy.Success compiled.initial]
  |> List.combine compiled.outputs
