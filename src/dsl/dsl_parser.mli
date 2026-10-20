type error = {
  range : Dsl_syntax.range;
  message : string;
}

(** Parse label and note declarations, preserving body whitespace.
    Identifiers use ASCII letters, underscores, digits and apostrophes;
    the first character must be a letter or underscore.
    Strings support quote, backslash, n, r and t escapes.
    In bodies, backslash escapes @, brackets and backslash.
    Balanced brackets are ordinary text; @ introduces a function call.
    Optional call bodies may follow whitespace.
    String ranges include quotes. Parsing stops at the first syntax error.
    Typst block delimiters and metadata syntax are not yet defined. *)
val parse : file:string -> string -> (Dsl_syntax.file, error) result
