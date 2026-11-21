#import "/reader/book.typ": chunk

= 文学编程工具的构建目标 <lit:dune>

Dune 构建命令行入口，并从 Ospero 库和共享模型链接所需接口。

#chunk(id: <source-lit-dune>)[
```dune
(data_only_dirs notes out reader)

(executable
 (name lit)
 (modules lit lit_reader)
 (optional)
 (libraries lit_engine ospero unix str yojson))
```
]

#chunk(id: <file-lit-dune>, target: "lit/dune")[
```dune
<<source-lit-dune>>
```
]
