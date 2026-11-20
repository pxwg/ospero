(** The default language adapters. Each reads its own card declarations,
    metadata, named calls and values, and offers optional sugars bound to
    project actions through the rule tables. *)
module Typst = Lang_typst
module Org = Lang_org
module Markdown = struct end

(** The literal values shared by Typst and Markdown. *)
module Value = Value

(** The card layer the adapters share, for adapters over other parsers. *)
module Card = Card
