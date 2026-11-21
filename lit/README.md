# Ospero 的 Typst 文学编程环境

运行 `./lit/edit` 可以在 Neovim 打开导览。`:LitNew` 新建卡片，`zf` 按标题搜索，`K` 查看当前引用。跳转、反向引用和补全使用 `ospero-lit` 提供的标准 LSP 接口。编辑器与构建命令需要装有项目依赖的 OCaml/opam 环境，以及 `yojson` 和 `uri`。Tinymist 以 `lit/` 为根目录按单文件工作。单篇卡片可直接编译，跨卡片引用的标题、跳转和诊断由 `ospero-lit` 提供。生成网页还需要支持 HTML 输出的 Typst，本项目用 0.15.1 验证。

同一个 opam switch 中装有 `ocaml-lsp-server`（`ocamllsp`）时，Lit 会把 tangle 结果投影到临时 Dune 工作区。Neovim 原生 LSP 客户端在隐藏的生成文件缓冲区上启动 `ocamllsp`。跳转、诊断和编辑的坐标由 Ospero 的 tangle 投影转换。`K` 和 `gd` 在 OCaml 代码中查看类型和跳转定义，在 `<<id>>` 上仍然定位卡片。引用和单一展开位置的补全使用标准 LSP 接口。多个展开实例的 hover 按结果合并，结果有差异时显示各自的拼接位置。Rename 只有在修改卡片后重新拼接能精确复现 OCaml 服务所请求的编辑时才会提交。未保存的改动通过 LSP 同步，保存后 Dune 会重新构建。`ocamllsp` 发出的无版本诊断在生成文件与保存内容一致时显示。

```sh
./lit/build tangle   # 生成 lit/out/
./lit/build weave    # 更新 lit/index.html
python3 lit/check.py # 检查两代自举、验证网页并编译生成树
```

卡片存放在 `lit/notes/`。每篇文件用一个带标签的标题声明卡片，例如 `= 项目结构 <ospero.ml>`。用 `@ospero.ml` 或 `@ospero.ml[]` 链接它，两种写法都显示卡片标题。引用紧贴中文时，可以写 `@ospero.ml[]中` 来划定 ID 的边界。用 `#include-note[@ospero.ml]` 把卡片嵌入当前正文。含 `/` 的旧 Org ID 使用 `:` 表示层级，例如 `syntax:lang_typst.ml`，对应的输出文件仍可写成 `"syntax/lang_typst.ml"`。

````typst
#import "/reader/book.typ": chunk

= 消息生成 <hello>

先解释构成消息的片段。

#chunk(id: <hello-message>)[
  ```ocaml
  let hello = "你好"
  ```
]

输出文件按依赖顺序引用片段。

#chunk(id: <hello-file>, target: "hello.ml")[
  ```ocaml
  module Greeting = struct
    <<hello-message>>
    let () = print_endline hello
  end
  ```
]
````

普通围栏代码块只用于展示。`#chunk` 的开闭围栏用空格对齐，围栏所在列就是代码的第零列。独占一行的 `<<id>>` 把该行相对于围栏的缩进加到被引用片段的每个非空行上。上例中，`let hello` 在独立片段里从第零列开始，拼接后缩进两格，与 `let ()` 对齐。设置 `noweb: false` 可以按字面保留整行标记。

[导览](index.typ) 沿一个真实的拼接引用解释整个实现。[共享模型](notes/lit/engine/lit_model.ml.typ) 用 `Syntax.Lang.Typst` 识别卡片和动作，再用 `Observation` 记录定义、引用和按顺序出现的代码片段。命令行、阅读器和 LSP 都使用这份模型。工具在 `lit/notes/lit/` 也有源码卡片。改动工具时同步更新对应卡片与生成的 OCaml 文件。检查脚本用首代生成的工具执行第二轮构建，并逐字节核对两代输出和网页里的代码。
