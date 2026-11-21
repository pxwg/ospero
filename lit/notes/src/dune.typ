#import "/reader/book.typ": chunk

= dune <core:src:dune>

#chunk(id: <source-core-src-dune>)[
```dune
(dirs :standard \ dsl)

(library
 (name ospero_kernel)
 (package ospero)
 (private_modules observation_edge_id))
```
]

#chunk(id: <file-core-src-dune>, target: "core/src/dune")[
```dune
<<source-core-src-dune>>
```
]
