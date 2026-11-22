#import "/reader/book.typ": card-source, chunk
#show: card-source

= text.ml <core:src:text.ml>

#chunk(id: <source-core-src-text-ml>)[
```ocaml
module Language = struct
  type t = string

  let of_string = function
    | "" -> Error "Language name must be non-empty"
    | name -> Ok name

  let to_string name = name
  let equal = String.equal
  let compare = String.compare
end

type t = {
  text : string;
  language : Language.t;
}
```
]

#chunk(id: <file-core-src-text-ml>, target: "core/src/text.ml")[
```ocaml
<<source-core-src-text-ml>>
```
]
