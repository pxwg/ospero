#import "/reader/book.typ": card-source, chunk
#show: card-source

= Language Server Protocol <lsp>

Language Server Protocol (LSP) 是连接 Ospero 内核与外部编辑器的交互协议层。编辑器中的语言服务器直接消费组装后的 @core:src:observation.mli[Observation]、@core:src:provenance.mli[源码位置]与 @core:src:policy_report.mli[末层报告]，在不重复实现解析与语义规则的前提下，提供跳转定义、反向引用、悬停预览、补全与实时诊断。

由于整条管线贯彻了@local-data-observation[]与@global-data-errors[]，LSP 得以在文档半成品或局部写坏的状态下持续提供@error-handler-editor[]所需的连续编辑体验。

唯一的 caveat 是对源码编辑时的服务：在目前的架构下，源码定位是直接通过对@core:src:syntax.mli[]所定义的代码区域来识别服务，而非通过@global-data[全局语义计算结果]来实现——这主要是因为，在输入的典型应用中，全局语义计算结果几乎一定是没有对当前光标所在位置的有效输出的。
