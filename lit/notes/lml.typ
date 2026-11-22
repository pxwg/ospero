#import "/reader/book.typ": card-source, chunk
#show: card-source

= 轻量标记语言 <lml>

轻量标记语言是以纯文本形式记录文档结构与排版的标记语言 (例如 @syntax:lang_org.mli[Org]、@syntax:lang_markdown.mli[Markdown]，以及按受限子集使用的 @syntax:lang_typst.mli[Typst])，天然适合版本控制、长期保存以及机器处理。

在 Ospero 中，宿主语言的正文与排版片段会带着语言标签@core:src:text.mli[原样保留]，内核只提取其中约定的@embedded-dsl[]语义。因此同一个笔记库可以并行混用多种轻量标记语言，并得到统一的全局语义计算结果。
