#import "/reader/book.typ": card-source, chunk
#show: card-source

= 嵌入 DSL <embedded-dsl>

在 @zettelkasten-intro[]中，如果直接把语义信息编码在宿主排版语言的完整求值结果里，随着笔记数量增长，每次提取局部信息都要展开大量排版与样式细节，初始化开销会迅速膨胀；反过来，如果另造一套封闭的专用格式，又会失去现有@lml[]的书写与排版生态。

嵌入 DSL 的做法是在宿主@lml[]中约定一个受限的声明式子集，只用来表达卡片边界、元数据、引用、嵌入与嵌套定义等语义，其余正文与排版仍完全留给宿主语言处理：

- 在@local-data[]阶段，扫描器直接识别这个受限子集，跳过完整排版求值，把普通文本按语言标签@core:src:text.mli[原样保留]，只把语义构造抽成@core:src:syntax.mli-action[行动调用]。
- 在写法上，同一套嵌入 DSL 同时支持通用的具名调用与贴近宿主习惯的语法糖，二者经由 @syntax:rules.mli[Rules] 归一为同一种未解码调用。项目内置的 @syntax:lang_typst.mli[Typst]、@syntax:lang_org.mli[Org] 与 @syntax:lang_markdown.mli[Markdown] 适配器，都是这一思路在具体语言上的实现。
