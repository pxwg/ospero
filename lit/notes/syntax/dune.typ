#import "/reader/book.typ": chunk

= dune <syntax:dune>

#chunk(id: <source-syntax-dune>)[
```dune
(library
 (name ospero_syntax)
 (package ospero)
 (libraries ospero_kernel))
```
]

#chunk(id: <file-syntax-dune>, target: "syntax/dune")[
```dune
<<source-syntax-dune>>
```
]
