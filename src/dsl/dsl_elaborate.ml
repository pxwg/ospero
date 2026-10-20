module Name_map = Map.Make (String)
module Identity_set = Set.Make (Graph.Vertex_id)

type issue =
  | Duplicate_label of {
      name : string;
      first : Dsl_syntax.range;
      duplicate : Dsl_syntax.range;
    }
  | Invalid_identity of {
      range : Dsl_syntax.range;
      message : string;
    }
  | Unknown_note_target of string Dsl_syntax.located
  | Invalid_call of Dsl_function.check_error

type labels = {
  bindings : Graph.Vertex_id.t Name_map.t;
  identities : Graph.Vertex_id.t list;
}

let lookup labels name = Name_map.find_opt name labels.bindings

(** Collect the project-wide label space before resolving any note or call. *)
let collect_labels (files : Dsl_syntax.file list) =
  let names = ref Name_map.empty in
  let bindings = ref Name_map.empty in
  let seen = ref Identity_set.empty in
  let identities = ref [] in
  let issues = ref [] in
  List.iter
    (List.iter (fun (declaration : Dsl_syntax.declaration Dsl_syntax.located) ->
      match declaration.value with
      | Dsl_syntax.Note _ -> ()
      | Dsl_syntax.Label label ->
          let duplicate =
            match Name_map.find_opt label.name.value !names with
            | None ->
                names := Name_map.add label.name.value label.name.range !names;
                false
            | Some first ->
                issues := Duplicate_label {
                  name = label.name.value;
                  first;
                  duplicate = label.name.range;
                } :: !issues;
                true
          in
          match Graph.Vertex_id.of_string label.identity.value with
          | Error message ->
              issues := Invalid_identity {
                range = label.identity.range;
                message;
              } :: !issues
          | Ok id ->
              if not duplicate then begin
                bindings := Name_map.add label.name.value id !bindings;
                if not (Identity_set.mem id !seen) then begin
                  seen := Identity_set.add id !seen;
                  identities := id :: !identities
                end
              end))
    files;
  match List.rev !issues with
  | [] -> Ok { bindings = !bindings; identities = List.rev !identities }
  | issues -> Error issues

(** Explicit notes share the supplied metadata until metadata syntax is defined.
    Duplicate definitions remain visible to Observation. *)
let elaborate ~metadata registry files =
  match collect_labels files with
  | Error issues -> Error issues
  | Ok labels ->
      let resolve = lookup labels in
      let notes = ref [] in
      let issues = ref [] in
      List.iter
        (List.iter (fun (declaration : Dsl_syntax.declaration Dsl_syntax.located) ->
          match declaration.value with
          | Dsl_syntax.Label _ -> ()
          | Dsl_syntax.Note note ->
              let target = resolve note.target.value in
              (match target with
               | None -> issues := Unknown_note_target note.target :: !issues
               | Some _ -> ());
              let body =
                Dsl_function.convert_body ~lookup:resolve registry note.body
              in
              (match body with
               | Error error -> issues := Invalid_call error :: !issues
               | Ok _ -> ());
              match target, body with
              | Some id, Ok body ->
                  notes := {
                    Observation.Source.id;
                    title = note.title.value;
                    metadata;
                    body;
                  } :: !notes
              | _ -> ()))
        files;
      match List.rev !issues with
      | [] ->
          Ok {
            Observation.identities = labels.identities;
            notes = List.rev !notes;
          }
      | issues -> Error issues
