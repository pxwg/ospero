#import "/reader/book.typ": card-source, chunk
#show: card-source

= Action 模型 <action>

在@zettelkasten-intro[]中，引用、正文嵌入 (transclusion) 与嵌套定义在抽象上可以统一为同一件事：在正文的某个出现位置，同时完成两类工作：

- 贡献图结构 (添加一条连接两张卡片的边，或为已登记的身份绑定一张卡片定义)；
- 在当前笔记的正文中产出供下游消费的展示内容 (例如引用时展示目标卡片标题，嵌入时展开目标卡片正文)。

因此，Ospero 将这些笔记语义统一建模为 *Action*，贯穿@local-data[]与@global-data[]：

- 前端以自定义 variant 声明项目自己的行动类型，并通过 @core:src:syntax.mli-action[Action] 把具名调用与各语言的语法糖归一为未解码调用；
- 解析与解码后，卡片正文成为 @core:src:observation.mli-source[Text 与 Action] 交错的有序序列，嵌套定义以尚未展开的 `Contents` 形式附着在行动上；
- 用户提供穷尽各分支的纯函数 @core:src:frontend.mli-pipeline[interpret]，把单条行动翻译为有序的 `Define / Relate / Emit / Fail` 贡献列表；
- @core:src:observation.mli-expand[Observation] 负责上下文切换与递归展开，最终得到不含待执行行动的正文 (`Text / Consume`) 与初始知识图，供后续策略计算与多端渲染消费。
