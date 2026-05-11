# 引言

> 从 Go / C# / TypeScript 到 Rust 的系统工程师转型
>
> A book for the 14-year veteran who wants to *actually* master Rust — including the unsafe parts.

---

## 关于这本书

市面上的 Rust 教材分两类:

1. **新手向**(*The Rust Book*、*Rust by Example*):假设你刚学编程,从变量、循环讲起。对老手来说慢且啰嗦。
2. **C++ 老兵向**(*Programming Rust*、*Rust for Rustaceans*):假设你熟悉手动内存管理、模板元编程、RAII。对 GC 语言出身的工程师来说有断层。

**这本书的位置**:写给已经有 10+ 年工程经验、用 GC 语言到生产级、懂 async / concurrency / generic 概念,但**没系统学过手动内存管理**的工程师。每个 Rust 概念都从你已知的世界出发,然后讲清楚 Rust 为什么不这么做。

**读完之后你能**:

- 给 Tokio / Axum / Hyper 这一级别的项目提交有质量的 PR
- 写 `unsafe` 代码而不引入 undefined behavior
- 给团队解释 Rust 的设计权衡,而不是只会照抄
- 看懂 Rust 编译器报错背后的真正原因,而不是猜

**读完之后你不会**:

- 成为 Rust 编译器(rustc)贡献者 —— 那是另一本书
- 精通嵌入式 Rust(`no_std`、bare metal) —— 本书 2 章简介,不展开

---

## 全书结构

| Part | 章节 | 主题 |
|---|---|---|
| **I** 心智模型重置 | Ch 1-3 | 为什么 Rust 不一样 / Ownership / Borrowing |
| **II** 类型系统 | Ch 4-7 | Struct & Enum / 错误处理 / Trait / 泛型进阶 |
| **III** 内存与资源 | Ch 8-10 | 智能指针 / 内部可变性 / Iterator & 闭包 |
| **IV** 并发与异步 | Ch 11-13 | 线程 / async/await / Tokio |
| **V** 工程实践 | Ch 14-16 | Cargo / Axum + sqlx / 测试 & bench |
| **VI** 深水区 | Ch 17-20 | 宏 / unsafe / FFI / Mini-Tokio |

总字数预计:**18-22 万字**,约 600-700 页 A5。

---

## 配套学习路线

本书配 **[12 周精通计划](./plan/12-week-plan.md)**,把每章学习节奏拆成 84 天可执行的日任务。一边读书一边做计划里的练习,效果远胜单纯读。

---

## 给读者的承诺

1. **不复读官方文档**。The Rust Book 已经写得很好,这本书做的是它没做的事:从你已知世界翻译。
2. **每章配实战练习**。不是 toy example,是真实工程场景。
3. **不藏复杂度**。Pin、unsafe、async 内部 —— 该讲深的地方讲深,不掩盖权衡。
4. **不假装精通**。我自己卡过的地方会标记 "⚠️ 这里我也曾困惑",并说明怎么走出来。

开始吧。

---

*Drafted 2026-05 · Working title, subject to change.*
