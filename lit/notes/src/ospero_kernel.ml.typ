#import "/reader/book.typ": chunk

= ospero_kernel.ml <core:src:ospero_kernel.ml>

#chunk(id: <source-core-src-ospero-kernel-ml>)[
```ocaml
(** Public library modules. Internal helpers are deliberately not re-exported. *)
module Clone = Clone
module Failure = Failure
module Frontend = Frontend
module Graph = Graph
module Observation = Observation
module Policy = Policy
module Policy_report = Policy_report
module Policy_wiring = Policy_wiring
module Provenance = Provenance
module Schema = Schema
module Syntax = Syntax
module Text = Text
```
]

#chunk(id: <file-core-src-ospero-kernel-ml>, target: "core/src/ospero_kernel.ml")[
```ocaml
<<source-core-src-ospero-kernel-ml>>
```
]
