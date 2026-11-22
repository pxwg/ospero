#import "/reader/book.typ": card-source, chunk
#show: card-source

= Zettelkasten 笔记系统 <zettelkasten-intro>

Zettelkasten 将知识拆分为带有稳定身份的原子卡片，通过显式的前向引用把卡片连接成一张有向的@core:src:graph.mli[知识图]，同时允许卡片嵌套与片段复用。

在 @home 中，卡片的引用、嵌入与嵌套定义被统一抽象为 @action；它们与卡片身份、元数据一起通过@embedded-dsl[]从任意@lml[]中提取，再经由@local-data[]与@global-data[]组装为可计算的知识图谱。
