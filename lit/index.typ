#import "/reader/book.typ": include-note, source-index, card-source
#show: card-source

= 从 Source 到消费者 <home>

同一处引用有三种读法。作者读它的理由，编辑器要知道点哪里能跳到定义，tangler 要知道该把哪段代码插进文件。Ospero 把三者共有的事实留在一次观察里，各个消费者再取自己需要的部分。

沿一行 `<<source-ospero-ml-lang>>` 走一遍。在 @ospero.ml 中，正文先解释核心组件，再解释各语言的适配器，最后按生成文件的顺序组装代码。点正文链接可以打开右侧卡片，展开嵌入可以留在原处读实现。

#include-note[@ospero.ml]

== 从 Typst 标记认出一张卡

`Syntax.Lang.Typst` 扫描标题、标签、函数调用和引用。文学编程环境注册一条身份规则，让带标签的标题声明一张卡片，再把 `#chunk(...)` 绑定到代码块动作。标题、参数和代码都保留@core:src:provenance.mli[原文中的位置]。普通小标题属于当前卡片，代码里的标题符号随代码保存。

#include-note[@syntax:lang_typst.mli]

== 用动作声明表达局部语义

适配器读出代码块的语言、片段 ID 和可选的输出路径。@core:src:syntax.mli[动作的参数规格]把这些字段交给解释器。解释器用 `Define` 生成一张代码卡，再解释它的代码正文。独占一行的 `<<id>>` 产生两个结果。`Relate` 记录指向目标的边，`Emit` 在正文原位置保存待展开的片段。文字链接和卡片嵌入也贡献各自的引用关系。

#include-note[@lit:engine:lit_model.ml]

== 消费者从同一份观察取结果

组装完成后，@core:src:observation.mli[观察结果]既保留成立的顶点和边，也保留悬空引用、被拒绝的定义及其位置。编辑器通过 `references_to` 查找反向引用，用定义区间完成跳转。Tangle 从指定输出路径的代码卡出发，按顺序展开片段。Weave 用 Typst 排版正文，再把代码片段的引用变成可点击的链接。

在更一般的项目里，@core:src:policy_wiring.ml[策略]可以沿同一份@core:src:graph.ml[图]派生检查结果。策略的输入和失败原因可以通过@core:src:policy_report.ml[报告]追到受影响的产物。

#include-note[@lit:lit_reader.ml]

== 源文件目录

#source-index()
