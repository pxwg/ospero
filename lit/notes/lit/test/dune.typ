#import "/reader/book.typ": chunk

= dune <lit:test:dune>

#chunk(id: <source-lit-test-dune>)[
```dune
(test
 (name examples)
 (libraries ospero))
```
]

#chunk(id: <file-lit-test-dune>, target: "lit/test/dune")[
```dune
<<source-lit-test-dune>>
```
]
