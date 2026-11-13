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
    Metadata uses records with whitespace-separated name = value fields,
    comma-separated lists, strings, signed decimal integers and booleans.
    Metadata records and lists can nest; trailing commas are not accepted.
    Raw blocks use raw FORMAT {|source|} or raw FORMAT {TAG|source|TAG}.
    FORMAT and nonempty TAG follow identifier rules; FORMAT is unrestricted
    by language names. Whitespace separates raw, FORMAT and the delimiter.
    Only complete opening sequences at identifier boundaries introduce raw
    blocks. Their contents are preserved byte-for-byte until the exact closing
    delimiter; source ranges exclude delimiters. *)
val parse : file:string -> string -> (Dsl_syntax.file, error) result
