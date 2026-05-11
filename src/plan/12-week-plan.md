# Rust 12 周精通计划

> 节奏:1.5h/天 × 6 天/周 × 12 周 ≈ 108h
> 目标:全面掌握 Rust,含 unsafe / 异步内部 / 宏 / FFI
> 起点:Go/TS/C# 多年经验,Rust 零基础

---

## 总体设计原则

1. **代码量 > 阅读量**:每天至少敲 50 行 Rust,不能只看书。
2. **借用检查器是老师不是敌人**:卡住时不要 `.clone()` 绕过,先理解为什么编译器拒绝。
3. **每周一篇笔记**:用自己的话总结一周关键概念,公开发布更好(GitHub repo 或博客)。
4. **错题本**:记录被借用检查器卡住的每个具体场景,周末复盘 mental model。
5. **真实项目是练兵场**:Week 7 起拿生产代码库当试炼场,Week 12 提一个有质量的 PR 作毕业作品。
6. **不囤教程**:选定 The Rust Book + Rustlings + Programming Rust + Rust for Rustaceans 这四本,不看其他十几个教程。
7. **不立刻问 AI**:遇到不会的先自己读编译器报错,5 分钟后再求助。借用检查器的 mental model 必须内化,绕过去等于没学。

---

## 阶段一 · 基础与所有权(Week 1-2)

**目标**:通过编译器的所有权检查不再是主要障碍。

### Week 1 · 语法与心智模型迁移

| 日 | 内容 | 时长 |
|---|---|---|
| 1 | 装 toolchain(rustup / rust-analyzer / clippy / rustfmt),配编辑器,Hello World;读 The Rust Book Ch 1-3 | 1.5h |
| 2 | The Rust Book Ch 4(Ownership)——分水岭,慢读;同步 Rustlings `move_semantics` 系列 | 1.5h |
| 3 | The Rust Book Ch 5-6(Struct/Enum/Pattern Matching);Rustlings `structs` `enums` | 1.5h |
| 4 | The Rust Book Ch 7-8(Modules/Collections);Rustlings `modules` `vecs` `hashmaps` | 1.5h |
| 5 | The Rust Book Ch 9(Error Handling);重点理解 `?` 与 `From` trait 的关系 | 1.5h |
| 6 | 复盘 + 小项目:CLI 工具读 CSV 输出统计 | 2h |
| 7 | 休息 | — |

### Week 2 · 类型系统基石

| 日 | 内容 | 时长 |
|---|---|---|
| 8 | The Rust Book Ch 10(Generics/Traits/Lifetimes)——这章读 2 遍 | 1.5h |
| 9 | Ch 10 第二遍 + Rustlings `generics` `traits` `lifetimes` | 1.5h |
| 10 | Ch 11(Testing);给 Week 1 的 CLI 加单元测试 + 集成测试 | 1.5h |
| 11 | Ch 12(CLI Project);跟着写 minigrep | 1.5h |
| 12 | Rust by Example 中所有权 + trait 的全部例子精读 | 1.5h |
| 13 | minigrep 扩展:支持正则 + 并行 | 2h |
| 14 | 休息 | — |

---

## 阶段二 · 类型系统深入(Week 3-4)

**目标**:能用 trait 抽象设计出符合 Rust 习惯的 API。

### Week 3 · Trait 与函数式

| 日 | 内容 | 时长 |
|---|---|---|
| 15 | Ch 13(Closures/Iterators);三种 Fn trait(`Fn` / `FnMut` / `FnOnce`)的语义差异 | 1.5h |
| 16 | Iterator adapter 全家桶熟练:`map` / `filter` / `fold` / `collect` / `zip` / `chain` / `flat_map` / `scan`;写 100 行链式代码 | 1.5h |
| 17 | Trait 进阶:associated types、default methods、supertraits | 1.5h |
| 18 | `dyn Trait` vs `impl Trait`,object safety 规则 | 1.5h |
| 19 | 错误处理工程化:`thiserror`(库) + `anyhow`(应用)的分工;重写 Week 1 项目 | 1.5h |
| 20 | 复盘 + 写一篇笔记 | 1.5h |
| 21 | 休息 | — |

### Week 4 · 智能指针与内部可变性

> ⚠️ **第一个分水岭**。这周卡过去,后面 Tokio 内部才能真正读懂。

| 日 | 内容 | 时长 |
|---|---|---|
| 22 | Ch 15(Smart Pointers);`Box` / `Rc` / `RefCell` 各自的使用场景 | 1.5h |
| 23 | 内部可变性:`Cell` vs `RefCell` vs `Mutex`;运行时借用检查的代价 | 1.5h |
| 24 | `Drop` / `Deref` / `DerefMut` trait;RAII 模式 | 1.5h |
| 25 | 实战:实现一个简单的 Arena allocator | 1.5h |
| 26 | 实战:实现一个 LRU cache(`Rc<RefCell<Node>>` 双向链表) | 1.5h |
| 27 | 阅读 std::collections 中 `Vec` 或 `HashMap` 源码片段 | 1.5h |
| 28 | 休息 | — |

---

## 阶段三 · 并发编程(Week 5-6)

**目标**:能写正确且符合 Rust 哲学的并发代码,理解 Tokio 的工作方式。

### Week 5 · 线程并发

| 日 | 内容 | 时长 |
|---|---|---|
| 29 | Ch 16(Threads);`thread::spawn` / `JoinHandle` / move closure | 1.5h |
| 30 | `Send` + `Sync` marker trait——透彻理解,这是 Rust 并发安全的根基 | 1.5h |
| 31 | `std::sync::mpsc`;`Arc<Mutex<T>>` 共享状态模式 | 1.5h |
| 32 | crossbeam 文档通读;理解为什么 std 之外还需要它(scoped threads / channel 性能) | 1.5h |
| 33 | 实战:并发 web crawler(work-stealing 模式) | 2h |
| 34 | 复盘 + 写笔记 | 1.5h |
| 35 | 休息 | — |

### Week 6 · async/await 入门

| 日 | 内容 | 时长 |
|---|---|---|
| 36 | Ch 17(Async);`Future` trait 概念;async fn 编译成状态机 | 1.5h |
| 37 | Tokio 入门:`#[tokio::main]` / `tokio::spawn` / `JoinHandle` | 1.5h |
| 38 | Tokio 异步原语:`tokio::sync::{mpsc, oneshot, broadcast, Mutex, RwLock}` | 1.5h |
| 39 | `select!` 宏 / `timeout` / `abort` / cancellation 模式 | 1.5h |
| 40 | 实战:用 Tokio 重写 Day 33 的爬虫,对比性能 | 2h |
| 41 | 阅读你目标项目的真实代码,试图看懂 50% | 1.5h |
| 42 | 休息 | — |

---

## 阶段四 · 生产级 Rust(Week 7-8)

**目标**:第一次给真实项目提交可合并的代码。

### Week 7 · Web 服务实战

> ⚠️ **第二个分水岭**。开始动真实代码库——被 review 一次值看一周书。

| 日 | 内容 | 时长 |
|---|---|---|
| 43 | Axum 入门:`Router` / handler / extractor / response | 1.5h |
| 44 | Axum 中间件:`tower::Service` / `tower::Layer` 的设计哲学 | 1.5h |
| 45 | `tracing` 与结构化日志;span 与 event 模型 | 1.5h |
| 46 | sqlx 加深:`query!` / `query_as!` 宏的编译期检查 | 1.5h |
| 47 | 选目标项目一个 small issue 开始实现 | 2h |
| 48 | 继续实现 + 自我 review | 2h |
| 49 | 休息 | — |

### Week 8 · 工程化

| 日 | 内容 | 时长 |
|---|---|---|
| 50 | Cargo workspace + monorepo | 1.5h |
| 51 | Feature flags / conditional compilation / `cfg!` | 1.5h |
| 52 | Benchmarking:`criterion` crate;微基准的常见陷阱 | 1.5h |
| 53 | Profiling:`cargo flamegraph` / `perf` / `tokio-console` | 1.5h |
| 54 | 测试进阶:`proptest`(property testing) / `insta`(snapshot testing) | 1.5h |
| 55 | 阅读高质量 crate:`ripgrep` 的 walker 模块 或 `hyper` 的 service 模块 | 1.5h |
| 56 | 休息 | — |

---

## 阶段五 · 高级特性(Week 9-10)

**目标**:能读懂任意 Rust 代码,包括宏和 unsafe。

### Week 9 · Macros

| 日 | 内容 | 时长 |
|---|---|---|
| 57 | 声明宏 `macro_rules!` 基础:`$expr` / `$ident` / `$ty` 等 fragment specifier | 1.5h |
| 58 | 声明宏进阶:tt munching、重复模式、卫生性 | 1.5h |
| 59 | 过程宏三种类型:derive / attribute / function-like;`syn` + `quote` 工具链 | 1.5h |
| 60 | 写一个简单的 derive macro(例如自动生成 `Builder`) | 2h |
| 61 | 阅读 `thiserror` 或 `serde_derive` 源码 | 1.5h |
| 62 | 复盘 + 写笔记 | 1.5h |
| 63 | 休息 | — |

### Week 10 · Unsafe 与 FFI

> ⚠️ **第三个分水岭**。"全面掌握含 unsafe"和"会写 Rust 业务代码"差距很大,这周不要跳。

| 日 | 内容 | 时长 |
|---|---|---|
| 64 | The Rustonomicon 序言 + raw pointer | 1.5h |
| 65 | Rustonomicon:aliasing 规则、lifetime variance(协变/逆变/不变) | 1.5h |
| 66 | `UnsafeCell` 与内部可变性的真相——为什么 `&T` 不一定是不可变 | 1.5h |
| 67 | FFI 入门:调 C 库(`libc` / `bindgen`) | 1.5h |
| 68 | FFI 出口:把 Rust 暴露给其他语言(`cbindgen` / PyO3 简介) | 1.5h |
| 69 | 重读 std 中 `Box` 和 `Vec` 的源码,这次能看懂 unsafe 块为什么这么写 | 2h |
| 70 | 休息 | — |

---

## 阶段六 · 大师级(Week 11-12)

**目标**:能设计抽象、能读 runtime 源码、能写出地道的 idiomatic Rust。

### Week 11 · Async 内部

| 日 | 内容 | 时长 |
|---|---|---|
| 71 | `Pin` 与 self-referential structs 的真正问题(为什么需要 Pin) | 1.5h |
| 72 | 手撸最简 executor(参考 mini-tokio 或 Phil Opp 的 async 教程) | 2h |
| 73 | `Waker` / `Context` / `Poll` 链路打通;唤醒机制的实现 | 1.5h |
| 74 | `Stream` trait;`futures::Stream` 与 `tokio_stream` | 1.5h |
| 75 | 阅读 Tokio runtime 源码:driver 与 scheduler | 2h |
| 76 | 复盘 + 写笔记 | 1.5h |
| 77 | 休息 | — |

### Week 12 · 收官

| 日 | 内容 | 时长 |
|---|---|---|
| 78 | 类型系统魔法:GATs(Generic Associated Types) | 1.5h |
| 79 | HRTB(Higher-Ranked Trait Bounds):`for<'a> Fn(&'a T)` 到底什么意思 | 1.5h |
| 80 | 性能优化:内存布局、`#[repr(C)]` / `#[repr(transparent)]`、零拷贝设计 | 1.5h |
| 81 | 设计一个完整的小型框架(mini-axum 或 mini-tokio,二选一) | 2h |
| 82 | 给目标项目提交一个有质量的 PR——毕业作品 | 2h |
| 83 | 写一篇博客:《我是怎么用 12 周从 Go 转到 Rust 的》 | 2h |
| 84 | 庆祝 🎉 | — |

---

## 关键资源(精选不囤货)

**主线**:

- [The Rust Book](https://doc.rust-lang.org/book/)(官方免费)
- [Rustlings](https://github.com/rust-lang/rustlings)(交互练习)
- [Rust by Example](https://doc.rust-lang.org/rust-by-example/)(字典查阅)

**进阶**:

- *Programming Rust*(Blandy/Orendorff,O'Reilly,系统编程视角)
- *Rust for Rustaceans*(Jon Gjengset,中高级话题,**最适合有经验的工程师**)
- [The Rustonomicon](https://doc.rust-lang.org/nomicon/)(unsafe 圣经)
- [The Async Book](https://rust-lang.github.io/async-book/)(异步官方书)

**视频**:

- Jon Gjengset 的 YouTube(*Crust of Rust* 系列):live coding 实现 channel / Mutex / Pin,看一遍胜过读十篇博客

**社区**:

- [This Week in Rust](https://this-week-in-rust.org/)(周报,周末扫一眼)
- [Rust 中文社区](https://rustcc.cn/)
- r/rust(英文)

---

## 进度追踪表

每周末填一行,公开 commit 到 GitHub 增加正反馈。

| 周 | 完成度 | 卡点(借用检查器卡了几次/具体场景) | 关键收获 | 下周调整 |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |
| 6 | | | | |
| 7 | | | | |
| 8 | | | | |
| 9 | | | | |
| 10 | | | | |
| 11 | | | | |
| 12 | | | | |

---

## 何时偏离计划

- **超前**:跳过 Rustlings 中明显简单的练习,但不要跳 The Rust Book 章节。
- **滞后**:不要积压超过 3 天。如果某一阶段彻底卡住,把当前周延长一周,后面阶段顺延——计划是地图不是法律。
- **生病/项目压力**:跳过一周用周日补,但**不要连续跳两周**——节奏一旦断超过 10 天,你会需要 1.5 倍时间才能回到状态。

---

*Plan crafted 2026-05 · Adjust as you go.*
