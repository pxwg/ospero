#import "/reader/book.typ": card-source, chunk
#show: card-source

= 文学编程 <lp>

Literate Programming 是这样一种代码组织方式，它旨在通过将以文档编辑为代表的纯文本编辑工作纳入代码撰写的生产周期中，实现面向程序员 (读者) 而非机器的代码库，并同时保持机器可运行性。本概念由 Donald Knuth 提出并命名，他曾提出，“let us change our traditional attitude to the construction of programs: Instead of imagining that our main task is to instruct a computer what to do, let us concentrate rather on explaining to human beings what we want a computer to do”。在他的 #link("https://books.google.ca/books?id=BhdUAAAAMAAJ")[_TeX: The Program_] 之中，这一代码组织方式被发扬光大，我们耳熟能详的 TeX 排版语言就是这样写出来的。

文学编程通常是使用一种 metalanguage 撰写的，这种语言需要混合一种文档格式语言，例如 LaTeX 或者 Typst，用于实现人类可读文档的组织，以及一种或多种编程语言，用于编辑供程序编译进而机器消费的代码逻辑。两个独立的系统处理该程序以获得@lp-weave[人类可处理]与@lp-tangle[机器可处理]的导出对象。

== Weave <lp-weave>

将@lp[]项目转换为人类可读的文档的过程。

///
== Tangle <lp-tangle>

将@lp[]项目转换为转换为机器可编译 (进而可消费) 的代码的过程。
/// end

历史上有诸多知名的文学编程框架，也有部分语言支持文学编程撰写。我们的目标是，让 @home 最终被重组织成一个文学编程项目，在构建 @zettelkasten-intro[]的同时实现相应的代码逻辑。
