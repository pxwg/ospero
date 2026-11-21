#import "/reader/book.typ": chunk

= 共享模型的依赖 <lit:engine:dune>

共享模型通过 Ospero 的公共接口解析声明、解释动作并装配观察结果。

#chunk(id: <source-lit-engine-dune>)[
```dune
(library
 (name lit_engine)
 (wrapped false)
 (libraries ospero unix str))
```
]

#chunk(id: <file-lit-engine-dune>, target: "lit/engine/dune")[
```dune
<<source-lit-engine-dune>>
```
]
