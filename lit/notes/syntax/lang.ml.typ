#import "/reader/book.typ": card-source, chunk
#show: card-source

= lang.ml <syntax:lang.ml>

#chunk(id: <source-syntax-lang-ml>)[
```ocaml
(** The default language adapters. Each reads its own card declarations,
    metadata, named calls and values, and offers optional sugars bound to
    project actions through the rule tables. *)
module Typst = Lang_typst
module Org = Lang_org
module Markdown = Lang_markdown

(** The literal values shared by Typst and Markdown. *)
module Value = Value

(** The card layer the adapters share, for adapters over other parsers. *)
module Card = Card
```
]

#chunk(id: <file-syntax-lang-ml>, target: "syntax/lang.ml")[
```ocaml
<<source-syntax-lang-ml>>
```
]
