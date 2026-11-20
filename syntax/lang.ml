(** The default language adapters. Each reads its own card declarations,
    metadata, named calls and values, and offers optional sugars bound to
    project actions through the rule tables. *)
module Typst = struct end
module Org = struct end
module Markdown = struct end

(** The literal values shared by Typst and Markdown. *)
module Value = Value
