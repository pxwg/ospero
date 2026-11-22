#import "/reader/book.typ": card-source, chunk
#show: card-source

= failure.ml <core:src:failure.ml>

#chunk(id: <source-core-src-failure-ml>)[
```ocaml
type target = Vertex of Graph.Vertex_id.t | Edge of Graph.Edge_id.t

type id =
  | Syntax of int
  | Observation of int
  | Policy of string
  | Product of string * string option * target

let compare = Stdlib.compare
let syntax occurrence = Syntax occurrence
let observation occurrence = Observation occurrence
let policy invocation = Policy invocation
let policy_product ~invocation ~output target = Product (invocation, output, target)

type ('subject, 'detail) t = {
  id : id;
  subject : 'subject;
  detail : 'detail;
  causes : id list;
}
```
]

#chunk(id: <file-core-src-failure-ml>, target: "core/src/failure.ml")[
```ocaml
<<source-core-src-failure-ml>>
```
]
