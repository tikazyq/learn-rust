# 附录 E · 推荐阅读路线图

> 进阶资源、社区资源、值得 follow 的人

**核心问题**:走完这本书之后,下一步读什么?

这本书提供了"从 GC 语言到 Rust 内部"的全程框架。但 Rust 生态变化快、深水区永远学不完——这附录给你一份持续学习清单。

---

## E.1 进阶书

### 必读

- **The Rust Programming Language**(俗称 "the book")—— Steve Klabnik & Carol Nichols。官方入门书,本书的对照参考。如果某一章你觉得讲得不够全,去查"the book"。
- **Rust for Rustaceans** —— Jon Gjengset。**最推荐的第二本书**。讲"用 Rust 写库"的工程实践,涵盖 API 设计、unsafe、async、FFI、性能。读完你能写出 idiomatic crate。
- **Programming Rust** (2nd ed.) —— Jim Blandy & Jason Orendorff。比 the book 厚,系统性强。机械工业出版社有中译。

### 深度

- **Rust Atomics and Locks** —— Mara Bos(rustc 主席之一)。**写并发库的必读**。从原子操作 → Mutex / RwLock / Condvar 内部 → memory ordering 一步步搭。
- **The Rustonomicon** —— 官方写的"unsafe rust 黑魔法"。在线免费:<https://doc.rust-lang.org/nomicon/>。
- **Zero To Production In Rust** —— Luca Palmieri。手把手用 axum / sqlx / sqlx / 测试驱动写一个真实的邮件订阅服务。生产级实践教材。

### 领域专用

- **Async Rust** —— Maxwell Flitton, Caroline Morton。Tokio 等异步生态系统讲解。
- **Hands-On Rust** —— Herbert Wolverson。用 Rust 写游戏(roguelike)。看怎么把 ECS 跟 Rust 类型系统融合。

---

## E.2 官方深度文档

```
The Rustonomicon         https://doc.rust-lang.org/nomicon/
The Reference            https://doc.rust-lang.org/reference/
Async Book               https://rust-lang.github.io/async-book/
Edition Guide            https://doc.rust-lang.org/edition-guide/
The Cargo Book           https://doc.rust-lang.org/cargo/
The rustc dev guide      https://rustc-dev-guide.rust-lang.org/   ← 编译器自身
The Unstable Book        https://doc.rust-lang.org/unstable-book/  ← nightly 特性
The API Guidelines       https://rust-lang.github.io/api-guidelines/
Rust by Example          https://doc.rust-lang.org/rust-by-example/
```

凡是涉及"具体语法 / 模型语义"的疑问,**先翻 Reference**。最权威。

---

## E.3 博客与文章

### 必订

- **fasterthanli.me**(Amos)—— 长文教学,深入到字节级别,写得非常清楚。系列 "Declarative macros" / "Pin and suffering" 是经典。
- **Aleksey Kladov(matklad)**(rust-analyzer 作者)—— 简洁、深刻、工程导向。
- **without.boats**(原 Rust async 主要设计者之一)—— 关于 Pin / async / Future 的设计原因。
- **fasterthanlime.dev** / **Yoshua Wuyts**(`tide` 作者,async 思考者)
- **Niko Matsakis** —— rustc 主席之一,语言设计文章。
- **Smallcultfollowing**(Niko 个人博客的别名)

### 中文社区

- **rust-cn.com** —— 官方中文站
- **rust-lang.github.io/this-week-in-rust**(英文,但每周一发,内容跟英文社区同步)

---

## E.4 视频

- **Crust of Rust** —— Jon Gjengset 的 YouTube 系列。**Rust 视频教学天花板**。每集 1-2 小时,实时写一个 crate,讲他的思路。Iterator / Lifetime / Channels / Sorting / etc 系列必看。
- **Decrusting** —— Jon Gjengset 另一系列,解构 tokio / axum / serde 等核心 crate。
- **Building a Custom Allocator** / **Tokio internals** 等 RustConf talks
- **Phil Opp 的 Blog OS** —— 用 Rust 写操作系统的系列(博客 + 视频)。即使你不写 OS,看里面 no_std / unsafe / 内存管理也长见识。
- **fasterthanli.me 也发 video**(高质量)

---

## E.5 开源项目(读源码)

### 第一梯队(必读)

- **Tokio** —— 学异步 runtime。从 `tokio::time::sleep` 入手,顺藤到 driver、scheduler。
- **Hyper** —— HTTP 库。看 Service trait 是怎么搭建一个网络框架的。
- **Axum** —— Web 框架。看 trait magic 如何让 handler 是普通 async fn。
- **sqlx** —— 数据库。看 macro 怎么编译期检查 SQL。
- **ripgrep** —— CLI 范本。性能、并发、跨平台路径处理的活教材。

### 想看 unsafe / 性能

- **bytes** —— 高性能 buffer。SBO + 引用计数 + zero-copy slicing。
- **dashmap** —— 并发 HashMap。bucket-level locking。
- **smallvec / arrayvec** —— stack-based 容器。
- **crossbeam** —— lock-free 数据结构。
- **rayon** —— 并行计算。从 par_iter() 入手,看怎么搭 work-stealing。

### 想看 macro / DSL

- **serde** —— 序列化。derive macro 经典。
- **clap** —— CLI 解析。derive + builder。
- **diesel** —— 编译期 SQL DSL,极致用 trait 系统。

### 想看 FFI / 平台

- **wasmtime** —— WASM runtime。
- **rusqlite** —— SQLite 包装,bindgen + 安全 API 经典。

---

## E.6 社区

- **This Week in Rust** —— 每周邮件列表,RFC / blog / crate / job。**订**。
- **r/rust**(Reddit)—— 讨论 / 提问 / 新工具发布。
- **Rust 用户论坛** —— <https://users.rust-lang.org/>
- **Rust 内部论坛** —— <https://internals.rust-lang.org/>(讨论语言设计)
- **Discord / Zulip** —— Rust 项目主要协作平台
- **RustChinaConf** / **RustConf** / **EuroRust** —— 年会,YouTube 有录像

---

## E.7 值得 follow 的人

(2026 年视角,排名不分先后)

| 人 | 身份 / 输出 |
|---|---|
| Niko Matsakis | rustc 主席,语言设计博客 |
| Jon Gjengset | 教学视频 (Crust of Rust) + 书 |
| Mara Bos | 库团队主席,《Atomics and Locks》作者 |
| Tyler Mandry | async 工作组 |
| Yoshua Wuyts | async / executor 思考者 |
| boats | Future / Pin 原始设计者 |
| matklad / Alex Kladov | rust-analyzer / IDE / 工程实践 |
| Amos / fasterthanli.me | 长文博主 |
| Steve Klabnik | The Book 作者 |
| dtolnay | serde / syn / quote / anyhow / thiserror 作者(生态半边天) |
| BurntSushi | ripgrep / regex / serde-json 等基础库 |
| sgrif | diesel 作者,trait magic 鬼才 |
| 张汉东 (rust-zh) | 中文社区组织者,翻译者 |

---

## 学完这本书后的"持续学习清单"

按"投入产出"排序:

1. **每周 30 min 看 This Week in Rust** —— 保持生态感
2. **每个月读一篇 fasterthanli.me 长文** —— 深度
3. **每月写一段非平凡 Rust 代码** —— 任何小工具 / 副业 / 重写
4. **每年看 2 本 Rust 书** —— Rust for Rustaceans / Atomics and Locks 先
5. **每年贡献一次开源 PR** —— 哪怕 typo 修复,走流程的价值大

---

## 一句送别

> "C 让你直面机器,Java 让你直面对象,Haskell 让你直面类型。Rust 让你直面**所有权**——一个你十年来下意识在思考但从未系统化的概念。从 GC 语言来,你不是学一个新语言,你是把脑子里一直存在的'谁负责这块内存 / 谁负责这条连接'的直觉,搬到类型系统里,变成可以编译期验证的事。"

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
