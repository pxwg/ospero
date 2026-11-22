#import "/reader/book.typ": card-source, chunk
#show: card-source

= 编辑期错误处理 <error-handler-editor>

在实时编辑 (例如通过 @lsp[LSP] 驱动编辑器) 的场景下，文档几乎始终处于未写完或局部损坏的状态。举例而言，我们的预期应该是：

- 一张卡片里某个引用写坏了，旁边的合法引用仍然应该可以跳转
- 一份元数据还没补全，这张卡片的标题与身份仍然应该可查

否则，连续编辑体验几乎不存在。

借助@local-data-observation[就地容错]与@core:src:frontend.mli-diagnostic[结构化诊断]，损坏的构造会留在原处并携带精确的 @core:src:provenance.mli[源码位置]，不会破坏同卡其余内容与无关卡片的索引。编辑器因此可以直接复用同一份定位信息在具体参数或标题处画线报错、针对缺少 ID 等问题提供就地补全，同时在图的完好部分继续提供跳转、悬停与补全能力。
