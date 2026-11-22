#import "/reader/book.typ": card-source, chunk
#show: card-source

= 编译期错误处理 <error-handler-compiler>

在批量构建、导出或校验整个笔记库时，错误处理的目标是在一次运行里把所有问题暴露出来，而不是在第一个语法或解码错误处提前中止。

由于@local-data-observation[]并经由前端@core:src:frontend.mli-stages[组合提交]，每处语法读取或解码失败都保留了@core:src:frontend.mli-diagnostic[字段路径与源码位置]；进入@global-data[]后，跨卡冲突、悬空引用以及策略求值中的失败与阻断也会随各自归属一并保留下来，最终通过 @core:src:policy_report.mli[失败报告] 汇总。编译期消费者因此既能按精确位置报告全部根因，也能清楚知道哪些下游产物受到了影响。
