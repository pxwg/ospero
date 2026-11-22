#import "/reader/book.typ": card-source, chunk
#show: card-source

= 全局信息提取 <global-data>

经过@local-data[]后，每张卡片的@syntax:rules.mli-identity[身份]、@core:src:schema.mli[元数据]、@core:src:text.mli[正文]与 @source-core-src-syntax-mli-action[Action] 贡献都已就位。全局信息提取关心的是需要联合多张卡片才能成立的判断：把分散的局部声明组装成一张一致的知识图，在此基础上运行全局语义规则，并追踪任何局部失败在图上的影响范围。

== 从局部贡献到初始知识图 <global-data-observation>

局部层交出的并不是最终的图，而是一批带源码位置的声明与待展开的行动。@core:src:observation.mli[Observation] 负责这一步的全局落盘：先冻结整批已注册的卡片身份，再通过@core:src:observation.mli-expand[行动展开]收集声明，最后经由@core:src:observation.mli-assemble[全局组装]检查重复定义与悬空引用，组装出由 @core:src:graph.mli[Graph] 表达的初始知识图 $Gamma = (V, E, s, t)$。

这一步有两个核心分离：

- 拓扑与赋值分离：图本身只维护固定拓扑 (有哪些顶点、每条边连接哪两个端点) 以及附着在顶点与边上的语义赋值，并通过@core:src:graph.mli-ops[保拓扑变换]供下游演化；每一次引用都有独立的边身份，允许平行边与环路。
- 计算空间与源码溯源分离：卡片正文、标题以及各字段的 @core:src:provenance.mli[源码位置] 留在@core:src:observation.mli-provenance[独立溯源索引]中查询，不混入后续的语义计算。

同时，组装过程延续了@local-data-observation[]的原则：遇到重复定义或悬空引用时，系统不会丢弃整张图，而是同时交付有效图、全部定义候选、被拒绝的引用以及带 @core:src:failure.mli[Failure] 身份的失败记录。下游因此能够区分“某张卡确实没有出边”与“存在未能解析的引用”。

== 纯函数策略与代数接线 <global-data-policy>

初始知识图组装完成后，拓扑 $Gamma$ 保持不变，全局语义计算表现为图上节点与边赋值的演化 (例如沿引用边继承标签、根据依赖关系传播任务状态，或基于元数据判定导出权限)。

我们要求所有策略规则都实现为纯函数，并通过声明上游依赖的方式组织成一张有向无环图 (DAG)。为了保证多输入消费、单输出复用与错误传播的自洽性，整个组合逻辑建立在@lawvere-theory[Lawvere 理论]之上：底层由 @core:src:clone.mli[Clone] 提供抽象克隆的投影、代入与有限积态射，上层由 @core:src:policy_wiring.mli-compile[Policy_wiring] 校验端口与环路，把整张策略 DAG 编译为单个结果空间态射并@core:src:policy_wiring.mli-evaluate[按依赖层求值]。用户只需编写单条纯函数规则并声明依赖，无需手动管理复杂的求值时序。

== 全局错误语义管理 <global-data-errors>

与@local-data-observation[局部错误管理]一样，全局计算也不采用“一处出错即中断整图”的早停模型，而是把失败、阻断与降级直接纳入结果空间，与正常产物一并传递。
在 @core:src:policy.mli[Policy] 中，这一设计分为两个粒度：

- @core:src:policy.mli-outcome[调用级]：当某次策略调用本身检查失败或必需的整图输入不可用时，结果落入 `Failure` 或 `Blocked`，只阻断依赖它的下游调用，无关分支照常求值。
- @core:src:policy.mli-state[产物级]：一次成功交付的调用返回的是带可用性标注的图状态 `State`，拓扑不变，但每个顶点或边上的产物各自记录为可用 (`Ready`)、降级可用 (`Degraded`) 或不可用 (`Unavailable`)。当卡片 B 的元数据解码失败时，依赖它继承标签的卡片 A 可以选择阻塞或使用兜底值继续计算，而无关卡片以及 A 到 B 的定义跳转都不受影响。

求值过程中，策略通过@core:src:policy.mli-product[产物组合子]读取输入时会自动记下实际依赖的异常记录 `Failure.id`。整轮求值结束后，末层的 @core:src:policy_report.mli[Policy_report] 将卡片外的语法诊断、`Observation` 的组装失败以及全部策略调用的记录汇入同一张表，通过@core:src:policy_report.mli-queries[诊断与影响查询]既支持按卡片或调用查诊断，也支持从任意根因沿直接因果边反查受影响的子图，从而把局部与全局的错误语义贯通为一体。
