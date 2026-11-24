#import "/reader/book.typ": card-source, chunk
#show: card-source

= Ospero 的模型 <model>

@zettelkasten-intro[]将知识网络抽象成以笔记为节点、链接为边的有向图。@home 的意义，是提供一组可操作的原语，来帮助用户完成

- 从纯文本中@local-data[提取]并@global-data-observation[构建]这一图结构。
- 在这一图结构上做@global-data[语义计算]以验证整体自洽性。
- 通过对图结构的消费来构建 @lsp、前端网页等服务。

虽然几乎所有的信息都能通过进一步在卡片系统中做遍历来得到，但我希望通过这样一张卡片的叙事，来串联 @home 抽象的构建@motivation-instead-of-abstraction[动机]。

// 需要进一步来展开设计，结合已有卡片
在 @home 中，卡片的引用、嵌入与嵌套定义被统一抽象为 @action；它们与卡片身份、元数据一起通过@embedded-dsl[]从任意@lml[]中提取，再经由@local-data[]与@global-data[]组装为可计算的知识图谱。

