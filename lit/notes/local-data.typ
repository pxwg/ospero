#import "/reader/book.typ": card-source, chunk
#show: card-source

= 局部信息提取 <local-data>

笔记系统之中的局部语义信息将通过@embedded-dsl 来编码。所谓局部，是指单凭当前文档的源码与项目规则就能完成的信息提取与翻译；需要联合多张卡片才能判断的关系解析、身份冲突与图级计算，则留给@global-data[]。

在设计局部信息提取时，作为一款旨在最大化支持可自定义的软件，我们希望 @home 不绑定任何具体的@lml[]，同一个笔记库可以并行使用 Typst, Org, Markdown 或自定义语法——即使是相同的标记@lml，也支持不同的@embedded-dsl。同时，我们又不能只留一个完全自由的解析入口——否则无论是人还是 Agent，每接入一种新语言或扩展一套新语义，都要重新管理大量细节和局部抽象，最后写出一堆难以维护的胶水代码。因此，这一层的核心工作，是在不绑定具体语言的前提下，抽离出一套足够稳定、可组合的配置与注册结构。

顺着这个要求，局部信息提取被组织为两个步骤，并共用同一套中间骨架：

- 首先，由 @core:src:syntax.mli[Syntax] 负责将各个@lml[]的@embedded-dsl 扫描并读取为初始对象。展示文本只标注所属语言@core:src:text.mli[文本]，不做公共富文本 AST 的拆解；源码位置通过 @core:src:provenance.mli[Provenance] 独立附着。因为同一段 markup 在不同语境下可以有不同含义，同一语义也可以有多种写法，读取过程通过 @syntax:rules.mli[Rules] 中的三张规则表 (@syntax:rules.mli-identity[身份]、@syntax:rules.mli-payload[值]、@syntax:rules.mli-action[行动]) 按语境分派，再由 @syntax:card.mli[Card] 统一处理@syntax:card.mli-context[卡片嵌套]、@syntax:card.mli-language[元数据挂载]与@syntax:card.mli-adapter[身份预登记]。
- 然后，由 @core:src:frontend.mli[Frontend] 负责将这些初始对象解码为符合项目规范的类型化数据，并通过@core:src:frontend.mli-pipeline[独立的解释器]把单条行动翻译为局部贡献。为了避免语法读取与前端解码各自维护一份字段定义，@core:src:syntax.mli-args[参数]与元数据的结构只在 @core:src:syntax.mli-input[Syntax] 与 @core:src:schema.mli[Schema] 中声明一次，两边共用；@core:src:frontend.mli-stages[原始输入与类型化输入]也直接复用 @core:src:observation.mli[Observation] 的卡片与项目骨架，只替换其中的元数据和行动类型。

== 正误信息应当一并纳入局部观察 <local-data-observation>

在推进这套设计的过程中，我们对“局部观察”本身的理解也发生了一次转变。

最初，我们容易把局部提取看作只产出“正确信息”的过程，一旦某处语法或解码出错就中断返回。但在实际编辑和增量更新中 (例如，在组织 @lsp[LSP] 的过程中)，一张卡片里写坏一个引用，不应影响旁边合法引用的跳转；一份写坏的元数据，也不应让整张卡片失去身份和正文。否则，@error-handler-editor[]所需要的连续编辑体验会失效。

换言之，从源码中读出一个合法值，和发现某处参数或元数据写坏了，本质上都是局部观察得到的信息。把“观察到的信息”从“仅包含正确信息”扩展为“正确信息与错误信息的组合提交”之后，错误处理就不再需要作为外挂补丁单独维护：

- @syntax:rules.mli-matched[规则匹配]区分“未匹配”与“已认领但写坏”，前者继续尝试后续规则，后者直接保留带位置的诊断。
- @syntax:card.mli-adapter[卡片]、元数据和@syntax:rules.mli-action[正文组装]按各自的槽位保留结果，坏掉的元数据或调用带着源码位置留在原处，其余部分继续往下传递。
- 经过前端解码后，局部层交出的同一份结构同时承载了可继续计算的值和@core:src:frontend.mli-diagnostic[精确的诊断定位]，@error-handler-compiler[]与@error-handler-editor[]都可以直接消费它。
