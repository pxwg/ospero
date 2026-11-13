(** Resolve project-wide labels and check source before observation. *)
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
  | Invalid_metadata of Dsl_metadata.diagnostic

(** Collect labels across all files before resolving notes and calls.
    Each explicit note uses [decode_metadata]; omission supplies an empty record.
    Duplicate note definitions remain visible to Observation.
    Function and raw-handler callbacks are deferred, not executed here. *)
val elaborate :
  decode_metadata:'metadata Dsl_metadata.decoder ->
  ('metadata, 'relation, 'consumption, 'error) Dsl_function.registry ->
  Dsl_syntax.file list ->
  (('metadata, ('metadata, 'relation, 'consumption, 'error) Dsl_function.action)
     Observation.project,
   issue list) result
