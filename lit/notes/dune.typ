#import "/reader/book.typ": card-source, chunk
#show: card-source

= dune <dune>

#chunk(id: <source-dune>)[
```dune
(library
 (name ospero)
 (public_name ospero)
 (libraries ospero_kernel ospero_syntax))
```
]

#chunk(id: <file-dune>, target: "dune")[
```dune
<<source-dune>>
```
]
