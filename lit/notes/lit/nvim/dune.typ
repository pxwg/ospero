#import "/reader/book.typ": chunk

= 编辑器服务的构建目标 <lit:nvim:dune>

Dune 将语言服务链接到构建命令使用的同一份模型。

#chunk(id: <source-lit-nvim-dune>)[
```dune
(executable
 (name lit_lsp)
 (modules lit_lsp lit_ocaml)
 (optional)
 (libraries lit_engine ospero yojson uri unix str lwt.unix))
```
]

#chunk(id: <file-lit-nvim-dune>, target: "lit/nvim/dune")[
```dune
<<source-lit-nvim-dune>>
```
]
