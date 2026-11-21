#import "/reader/book.typ": chunk

= dune-project <dune-project>

#chunk(id: <source-dune-project>)[
```dune
(lang dune 3.24)
(name ospero)
(version 0.1.0)

(package
 (name ospero))
```
]

#chunk(id: <file-dune-project>, target: "dune-project")[
```dune
<<source-dune-project>>
```
]
