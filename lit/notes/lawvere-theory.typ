#import "/reader/book.typ": card-source, chunk
#show: card-source

= Policy 组合的 Lawvere 理论模型 <lawvere-theory>

本卡给出 @global-data[] 中策略组合与错误传播的代数表述，对应 @core:src:clone.mli[Clone]、@core:src:policy.mli[Policy] 与 @core:src:policy_wiring.mli[Policy_wiring] 的数学模型。如果你对代数背景不感兴趣，这一节完全可以直接跳过，不影响阅读后续的 OCaml 接口卡。

== 扩张结果空间与策略提升 <lawvere-theory-space>

在固定有限知识图 $Gamma = (V, E, s, t)$ 上，满足约束的节点与边赋值构成状态空间
$
  cal(S)_Gamma = { (Gamma, sigma_V, sigma_E) | "赋值满足 contract" }.
$
在调用身份 $v$ 上定义的单条纯函数策略由一对函数给出：
$
  op("run")_v : cal(S)_Gamma^(n) --> cal(S)_Gamma, quad op("check")_v : cal(S)_Gamma^(n) --> cal(I),
$
其中 $cal(I)$ 是问题的有限集合。只有当 $op("check")_v$ 返回空集时，$op("run")_v$ 才对这组输入给出语义。

为了使失败的调用不污染无关计算，同时不必在每次接线时手写错误分支，我们将完整图状态与错误结果作不交并，得到扩张的结果空间
$
  hat(cal(S))_Gamma = cal(S)_Gamma union.sq cal(E),
$
其中 $cal(E)$ 包含两类错误：输入齐全但检查未通过的 $op("failure")(v, I)$，以及存在不可用输入而直接阻断的 $op("blocked")(v, D)$。每个错误都携带产出它的调用身份 $iota : cal(E) --> V$，满足 $iota(op("failure")(v, I)) = iota(op("blocked")(v, D)) = v$。固定调用身份 $v$ 后，策略统一提升为
$
  hat(f)_v : hat(cal(S))_Gamma^(n) --> hat(cal(S))_Gamma,
$
定义为
$
  hat(f)_v (r_1, dots, r_n) = cases(
    op("blocked")(v, {iota(r_j) | r_j in cal(E)})\, & exists j\, r_j in cal(E),
    op("failure")(v, op("check")_v (bold(s)))\, & bold(s) in cal(S)_Gamma^n\, op("check")_v (bold(s)) != nothing,
    op("run")_v (bold(s))\, & bold(s) in cal(S)_Gamma^n\, op("check")_v (bold(s)) = nothing,
  )
$
其中当所有输入都成功时记 $bold(s) = (r_1, dots, r_n)$。这一提升只依赖调用身份 $v$ 与输入结果本身，无需知道端口接到了哪些上游。

== Abstract Clone 与代入规律 <lawvere-theory-clone>

固定结果空间 $hat(cal(S))_Gamma$ 后，对于 $f : hat(cal(S))_Gamma^m arrow hat(cal(S))_Gamma$ 和共享同一组 $n$ 个输入的 $g(j) : hat(cal(S))_Gamma^n arrow hat(cal(S))_Gamma$，定义代入运算 `bind` 为
$
  (f triangle.r j.g(j))(bold(r)) := f(g(1)(bold(r)), dots, g(m)(bold(r))),
$
其中 $bold(r) in hat(cal(S))_Gamma^n$，投影为 $eta_n (i)(r_1, dots, r_n) = r_i$。这种代入自动满足 abstract clone 的三条规律：

- 左单位律：$eta_m (i) triangle.r j.u(j) = u(i)$
- 右单位律：$t triangle.r i.eta_m (i) = t$
- 结合律：$(t triangle.r i.u(i)) triangle.r j.v(j) = t triangle.r i.(u(i) triangle.r j.v(j))$

将所有提升后的策略 $hat(f)_v$ 与投影对 `bind` 取闭包，即得到 $hat(cal(S))_Gamma$ 上的一个具体 abstract clone $hat(T)$，其中 $hat(T)(n) subset.eq op("Hom")_(bold("Set")) (hat(cal(S))_Gamma^n, hat(cal(S))_Gamma)$。这一闭包结构直接对应 @core:src:clone.mli[Clone] 中的 `operation`、`projection` 与 `bind`。

== Lawvere 理论与 DAG 接线 <lawvere-theory-dag>

一个 Lawvere 理论是一个具有有限积的范畴 $cal(L)$，其中存在一个生成对象 $x$，使得每个对象都同构于 $x$ 的有限笛卡尔幂
$
  x^n = underbrace(x times x times dots.c times x, n)
$
(特别地，$x^0$ 为终对象)；它的模型则是从 $cal(L)$ 出发的保积函子。

每条策略消费多个输入而产出一个结果，但它的结果可以供多个下游复用。为此，将单输出运算组织为输出列表，构造以自然数为对象的范畴 $cal(L)_(hat(T))$，其态射为
$
  op("Hom")_(cal(L)_(hat(T))) (m, n) = hat(T)(m)^n.
$
恒等态射是投影列表，复合是逐分量 `bind`。输出列表的拆分与拼接使加法成为范畴积，空列表使 $0$ 成为终对象，每个对象 $n$ 都是生成对象 $1$ 的 $n$ 次笛卡尔幂，因此 $cal(L)_(hat(T))$ 是一个 Lawvere 理论。在 $bold("Set")$ 中，对象 $n$ 对应 $hat(cal(S))_Gamma^n$，态射对应多输出函数 $(f_1, dots, f_n) |-> (bold(r) |-> (f_1 (bold(r)), dots, f_n (bold(r))))$。

若某顶点 $v$ 的输出被 $m$ 个下游端口复用，连同出向接线即表示态射
$
  Delta_m compose hat(f)_v = chevron.l hat(f)_v, dots, hat(f)_v chevron.r in hat(T)(n)^m.
$
设整张策略 DAG 有 $p$ 个有序外部输入，第 $i$ 个输入顶点对应投影，内部顶点按端口顺序将上游运算代入自身策略：
$
  hat(F)_("input", i) = eta_p (i), quad hat(F)_v = hat(f)_v triangle.r j.hat(F)_(a(v, j)),
$
其中 $a(v, j)$ 是顶点 $v$ 第 $j$ 个输入端口的上游顶点。按依赖顺序复合后，全部顶点的结果合起来构成单个 Lawvere 态射
$
  chevron.l hat(F)_v chevron.r_(v in V) in op("Hom")_(cal(L)_(hat(T))) (p, abs(V)),
$
指定输出顶点 $o$ 即得到整体运算 $hat(F)_o : hat(cal(S))_Gamma^p arrow hat(cal(S))_Gamma$。错误传播完全由生成元 $hat(f)_v$ 定义，接线只负责代入与复用，因此用户只需声明上游依赖与纯函数规则，组合语义与错误隔离便自动成立。
