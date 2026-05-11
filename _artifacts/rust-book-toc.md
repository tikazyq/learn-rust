# 《Rust by Migration》

> 从 Go / C# / TypeScript 到 Rust 的系统工程师转型
>
> A book for the 14-year veteran who wants to *actually* master Rust — including the unsafe parts.

---

## 关于这本书

市面上的 Rust 教材分两类:

1. **新手向**(*The Rust Book*、*Rust by Example*):假设你刚学编程,从变量、循环讲起。对老手来说慢且啰嗦。
2. **C++ 老兵向**(*Programming Rust*、*Rust for Rustaceans*):假设你熟悉手动内存管理、模板元编程、RAII。对 GC 语言出身的工程师来说有断层。

**这本书的位置**:写给已经有 10+ 年工程经验、用 GC 语言到生产级、懂 async/concurrency/generic 概念,但**没系统学过手动内存管理**的工程师。每个 Rust 概念都从你已知的世界出发,然后讲清楚 Rust 为什么不这么做。

**读完之后你能**:
- 给 Tokio / Axum / Hyper 这一级别的项目提交有质量的 PR
- 写 `unsafe` 代码而不引入 undefined behavior
- 给团队解释 Rust 的设计权衡,而不是只会照抄
- 看懂 Rust 编译器报错背后的真正原因,而不是猜

**读完之后你不会**:
- 成为 Rust 编译器(rustc)贡献者——那是另一本书
- 精通嵌入式 Rust(`no_std`、bare metal)——本书 2 章简介,不展开

---

## 全书结构

```
Part I    心智模型重置        (Ch 1-3)
Part II   类型系统             (Ch 4-7)
Part III  内存与资源           (Ch 8-10)
Part IV   并发与异步           (Ch 11-13)
Part V    工程实践             (Ch 14-16)
Part VI   深水区               (Ch 17-20)
```

总字数预计:**18-22 万字**,约 600-700 页 A5。
配套代码仓库:每章一个 cargo workspace 子目录,含可运行示例与练习骨架。

---

## Part I · 心智模型重置(Ch 1-3)

> 这部分不教语法,教**思维方式**。如果你跳过这三章直奔 trait 和 async,后面会全程别扭。

### Ch 1 · 为什么 Rust 不一样

**核心问题**:Rust 到底解决了什么别的语言解决不了的问题?

**主要内容**:
- 这本书是写给谁的(也写给谁不是)
- 用一个并发抓取的例子对比 Go / C# / Rust
- Rust 的三个核心承诺:memory safety / fearless concurrency / zero-cost abstractions
- **概念翻译表**:你已经懂的概念在 Rust 里叫什么(GC → Ownership,defer → Drop,interface → trait,channel → mpsc,async/await → Future,etc.)
- Rust 难学的真相:不是语法,是**显式所有权**这个新维度
- 学习陷阱:用 `.clone()` 绕过借用检查 = 永远没学会
- 环境配置:rustup / rust-analyzer / clippy / cargo

**与你已有知识的连接**:Go 的 GC、C# 的 IDisposable、TS 的 strict mode

**练习**:配通 toolchain,写一个反转字符串的命令行程序

**字数预计**:10000

---

### Ch 2 · Ownership 是工程纪律

**核心问题**:为什么编译器要管你的内存?

**主要内容**:
- Stack vs Heap:为什么 Rust 让你显式区分
- Ownership 的三条规则,每条规则的工程动机
- Move semantics vs Copy semantics:`Copy` trait 是什么、为什么 `String` 不实现它
- `Drop` trait:RAII 在 Rust 里是默认行为,不是手动 `using`/`defer`
- Function call 边界处的 ownership 流动
- 反例对比:同样的逻辑在 Go 里 GC 帮你做了什么、在 C 里你需要做什么、在 Rust 里编译器要求你做什么
- `clone()` 什么时候是对的、什么时候是逃避——**判断标准**

**与你已有知识的连接**:Go 的 escape analysis、C# 的 IDisposable / using、ref vs value semantics

**练习**:不用 `.clone()` 实现一个把 `Vec<String>` 按长度分组的函数

**字数预计**:12000

---

### Ch 3 · Borrowing 与 Lifetime — 编译器是结对程序员

**核心问题**:借用规则到底为什么是这样?

**主要内容**:
- 共享借用 `&T` vs 独占借用 `&mut T`:为什么二者互斥
- 借用规则背后的并发安全定理(Aliasing XOR Mutability)
- Lifetime 标注 `'a` 不是手动管理生命周期,是给编译器看的注解
- Lifetime elision 规则:绝大多数情况你不用写
- `'static` lifetime 的真实含义(不是"永远活着",是"可以活很久")
- NLL(Non-Lexical Lifetime)与"借用提前结束"的实际效果
- 常见借用错误模式:迭代时修改、自引用结构、try-then-modify、双重可变借用
- **借用检查器报错读法**:每个错误背后是什么模式

**与你已有知识的连接**:Go 的 channel-as-ownership-transfer 哲学、C# ref struct、TS 的 readonly

**练习**:实现一个不 `clone` 的字符串切分迭代器

**字数预计**:14000

---

## Part II · 类型系统(Ch 4-7)

> Rust 的类型系统比 Go 表达力高一个量级,比 C# 多了所有权维度,比 TypeScript 多了运行时保证。

### Ch 4 · Struct、Enum、Pattern Matching

**核心问题**:如何用 Rust 的 sum types 重新设计你的领域模型?

**主要内容**:
- Struct 的三种形式(named / tuple / unit)各自的工程用途
- Enum:不是 C 那种 enum,是 Haskell 的 sum type
- Pattern matching 的穷尽性检查——编译器替你写测试用例
- `if let` / `while let` / `let-else` 的使用时机
- Newtype pattern:为什么生产代码里到处都是 `pub struct UserId(u64)`
- Builder pattern 在 Rust 里的标准写法
- **领域建模实战**:把一个 Go 里用 `interface{}` + type switch 的场景重写成 Rust enum

**与你已有知识的连接**:TS discriminated union、C# pattern matching、Go 的"贫血 struct + 一堆 helper"

**练习**:重新设计 Stiglab 的 Session 状态机用 enum 表达

**字数预计**:11000

---

### Ch 5 · 错误处理:Result 与 ? 操作符

**核心问题**:为什么 Rust 没有 exception?

**主要内容**:
- `Option<T>` 与 `Result<T, E>`:都是 enum,都没有特殊性
- `?` 操作符的解糖与 `From` trait 的关联
- panic vs Result:边界在哪里
- `thiserror` vs `anyhow`:库 vs 应用 的标准分工
- 错误层次设计:transport error / domain error / validation error 各自的边界
- backtrace 与 `Error::source()` 链
- 反模式:`unwrap()` 满天飞、`Box<dyn Error>` 一把梭、过度细分错误类型

**与你已有知识的连接**:Go 的 `if err != nil` 仪式、C# 的 try/catch/finally、TS 的 never type

**练习**:把 Stiglab 一个模块的错误层次重新设计

**字数预计**:9000

---

### Ch 6 · Trait — 比 interface 多了什么

**核心问题**:trait 不是 interface 的复刻,它是别的东西。

**主要内容**:
- 基本 trait 与 method:看起来像 interface
- Associated types:为什么 `Iterator::Item` 不是泛型参数
- Default methods 与 supertraits
- Blanket impl:`impl<T: Display> ToString for T` 的威力
- Marker traits:`Send` / `Sync` / `Copy` / `Sized` 不带方法的 trait 在做什么
- Object safety 规则:为什么 `Iterator` 可以 `dyn`,`Clone` 不能
- `dyn Trait` vs `impl Trait`:静态派发 vs 动态派发的成本
- Trait 设计原则:小而组合,而不是 fat interface

**与你已有知识的连接**:Go interface(structural,小而散)、C# interface(nominal,带继承)、TS interface(structural,纯类型)、Haskell typeclass(trait 的真正前身)

**练习**:为 Onsager 的 Artifact 模型设计一组 trait

**字数预计**:13000

---

### Ch 7 · Generics、Lifetime、Variance

**核心问题**:Rust 的泛型为什么有时候让你写 `where 'a: 'b`?

**主要内容**:
- Monomorphization:Rust 泛型不是 Go interface 的运行时多态,是编译期代码生成
- Generic bound:`T: Foo + Bar`、`where` 子句的工程使用
- Generic 的 lifetime 参数:`fn longest<'a>(x: &'a str, y: &'a str) -> &'a str`
- Variance(变型):为什么 `&'static T` 可以传给要 `&'a T` 的函数,反过来不行
- HRTB(Higher-Ranked Trait Bounds):`for<'a> Fn(&'a T)` 在解决什么实际问题
- GATs(Generic Associated Types):为什么有它之后 lending iterator 才成为可能
- **泛型设计权衡**:什么时候泛型,什么时候 trait object,什么时候直接复制粘贴

**与你已有知识的连接**:C# generic constraint、TS conditional types、Go 1.18+ 泛型的局限

**练习**:写一个泛型 cache,对 key/value 各自施加合适的 trait bound

**字数预计**:13000

---

## Part III · 内存与资源(Ch 8-10)

### Ch 8 · 智能指针:Box / Rc / Arc

**核心问题**:什么时候需要 heap 分配,什么时候需要共享所有权?

**主要内容**:
- `Box<T>`:堆上的独占所有权,递归类型的标配
- `Rc<T>`:单线程引用计数,何时使用
- `Arc<T>`:线程安全引用计数,代价是原子操作
- `Weak<T>`:打破循环引用
- `Cow<T>`(Clone on Write):零拷贝优化的常用工具
- `Pin<P>`:延迟到 Ch 12,这里只埋伏笔
- **错误模式**:`Arc<Mutex<T>>` 滥用 vs channel-based 设计

**与你已有知识的连接**:C++ shared_ptr / unique_ptr、Swift ARC、JVM 引用类型

**练习**:用 `Rc<RefCell<Node>>` 实现一个双向链表,然后讨论为什么这样设计在 Rust 里被认为是 anti-pattern

**字数预计**:10000

---

### Ch 9 · 内部可变性:Cell / RefCell / Mutex

**核心问题**:为什么 `&self` 也能修改内部状态?

**主要内容**:
- 借用规则在编译期 vs 运行期 vs 跨线程
- `Cell<T>`:不带借用,直接 swap,适合 `Copy` 类型
- `RefCell<T>`:运行时借用检查,违反时 panic
- `Mutex<T>` / `RwLock<T>`:跨线程的内部可变性
- `UnsafeCell<T>`:所有内部可变性的最底层原语
- **设计选择树**:遇到"我需要修改 `&self` 内的字段"时,如何选择正确的工具

**与你已有知识的连接**:C# 的 lock、Go 的 sync.Mutex、Java synchronized

**练习**:把一个 `Mutex<HashMap>` 改造成更高效的 `DashMap` 或 sharded map

**字数预计**:9000

---

### Ch 10 · 闭包与 Iterator

**核心问题**:Rust 的闭包为什么有三种 trait?

**主要内容**:
- `Fn` / `FnMut` / `FnOnce` 三个 trait 的语义差异
- 闭包捕获 by reference / by mutable reference / by move
- `move ||` 的真正含义
- Iterator trait 与 lazy evaluation
- Iterator adapter 全家桶:`map` / `filter` / `flat_map` / `fold` / `scan` / `take_while` / `chain` / `zip`
- `collect::<T>()` 的 turbofish 与类型推导
- 自定义 Iterator:实现 `next()`,免费获得所有 adapter
- **零成本抽象的实证**:看汇编对比,for 循环 vs iterator chain

**与你已有知识的连接**:C# LINQ、TS Array methods、Go 的"没有 map/filter,自己写 for 循环"

**练习**:用 iterator chain 重写一段你 Crawlab 里的处理代码

**字数预计**:11000

---

## Part IV · 并发与异步(Ch 11-13)

### Ch 11 · 线程、Send、Sync

**核心问题**:Rust 凭什么号称 fearless concurrency?

**主要内容**:
- `std::thread::spawn` 与 `JoinHandle`
- `Send`:类型可以被转移到另一个线程
- `Sync`:类型的 `&T` 可以被多个线程共享
- 这两个 marker trait 是怎么做到编译期阻止 data race 的
- `move closure` 与线程间数据传递
- `std::sync::mpsc` channel
- `crossbeam` 的 scoped threads:借用栈数据的并发
- **共享内存 vs message passing**:Rust 哲学倾向哪边,以及为什么

**与你已有知识的连接**:Go 的"don't communicate by sharing, share by communicating"、C# Task、Java thread

**练习**:写一个并发的目录扫描器,使用 work-stealing 模式

**字数预计**:11000

---

### Ch 12 · async/await 基础:Future、Pin、Waker

**核心问题**:Rust 的 Future 跟 C# 的 Task 哪里不一样?

**主要内容**:
- Future trait 定义:`fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output>`
- async fn 是编译器生成的状态机:逐步展示编译产物
- 为什么 Rust Future 是 lazy 的,跟 C# Task 的 hot 模式对比
- `.await` 的解糖:让出控制权 + 注册 waker
- Pin 解决的真问题:self-referential struct 的内存安全
- Waker 与 Context:谁来通知 Future 可以再次 poll
- **手撸最简 executor**(50 行 Rust)
- 为什么 Rust 选择"无运行时 by default"的 async 设计

**与你已有知识的连接**:C# Task / async state machine、Go goroutine(对比 stackful vs stackless)、JS event loop

**练习**:实现一个 `Sleep` Future 与配套的 timer wheel(简化版)

**字数预计**:15000

---

### Ch 13 · Tokio 生产实战

**核心问题**:从能跑到能上生产,中间的那些细节。

**主要内容**:
- Tokio runtime 架构:scheduler / driver / blocking pool
- `tokio::spawn` vs `tokio::task::spawn_blocking`
- `tokio::sync` 全家桶:`mpsc` / `oneshot` / `broadcast` / `watch` / `Notify` / `Mutex` / `RwLock` / `Semaphore`
- `select!` 宏与 cancellation
- 任务取消与资源清理:Drop 在 async 里的陷阱
- `tokio::time::sleep` vs `std::thread::sleep` 在 async 上下文的灾难性差异
- Structured concurrency 的当前实践:`JoinSet` / `tokio_util::task::TaskTracker`
- 性能调优:worker thread 数量、task 粒度、CPU-bound vs IO-bound
- 调试:`tokio-console` 的实战使用

**与你已有知识的连接**:C# TaskScheduler、Go runtime、Node.js event loop

**练习**:给 Stiglab Control Plane 加一个带 cancellation 的健康检查 task

**字数预计**:14000

---

## Part V · 工程实践(Ch 14-16)

### Ch 14 · Cargo、Workspace、依赖管理

**核心问题**:大型 Rust 项目怎么组织?

**主要内容**:
- Cargo.toml 全字段解读
- `[workspace]` 与 monorepo:你 Onsager 监督下的实际场景
- Feature flags 的设计:additive 原则、避免 mutually-exclusive features
- `[dev-dependencies]` / `[build-dependencies]` 的边界
- `cargo check` / `cargo clippy` / `cargo fmt` / `cargo test` / `cargo bench` 全套
- 依赖审计:`cargo audit` / `cargo deny`
- 编译时间优化:`cargo-chef` / sccache / lld linker / split debuginfo
- 发布到 crates.io 的流程

**与你已有知识的连接**:pnpm workspace、Go module、NuGet、Maven

**练习**:把你某个个人项目重构成 workspace 结构

**字数预计**:9000

---

### Ch 15 · Web 服务:Axum + sqlx + tracing

**核心问题**:写一个生产级 HTTP 服务的现代 Rust 栈。

**主要内容**:
- Axum 的设计哲学:基于 `tower::Service` 的中间件
- Handler / Extractor / IntoResponse 的契约
- 中间件:`tower::Layer` / `tower::Service` 详解
- 状态共享:`State<Arc<AppState>>` 的标准模式
- sqlx 编译期检查:`query!` 宏与数据库 schema 的对接
- 连接池配置与 `AnyPool`(你已经在用)
- tracing 结构化日志:span / event / subscriber 模型
- OpenTelemetry 集成
- 错误处理:从 `Result` 到 HTTP response 的优雅链路
- 优雅关闭:graceful shutdown 的正确实现

**与你已有知识的连接**:ASP.NET Core middleware、Express middleware、Go gin/echo

**练习**:写一个带 JWT 鉴权 + 数据库 + 结构化日志的 REST 服务

**字数预计**:15000

---

### Ch 16 · 测试、基准、可观测性

**核心问题**:生产级 Rust 项目的质量保证。

**主要内容**:
- 单元测试 / 集成测试 / doc-test 三种测试形态
- `proptest` / `quickcheck`:property-based testing
- `insta`:snapshot testing
- `mockall`:mock 框架
- `criterion`:微基准的正确做法,黑盒避免编译器优化掉测试代码
- `cargo flamegraph`:生成火焰图
- `tokio-console`:async runtime 调试
- `pprof-rs`:CPU profiling
- 内存分析:`heaptrack` / `dhat`
- 测试隔离:文件系统、数据库、外部服务

**与你已有知识的连接**:Go test、xUnit、Jest、性能分析工具链

**练习**:给一个项目加完整的测试矩阵 + 一个 criterion benchmark

**字数预计**:11000

---

## Part VI · 深水区(Ch 17-20)

### Ch 17 · 宏:声明宏与过程宏

**核心问题**:Rust 元编程的两套机制。

**主要内容**:
- `macro_rules!` 声明宏:fragment specifier(`$expr` / `$ty` / `$ident` / etc.)
- 重复模式 `$( ... )*` 与 `$( ... ),+`
- 卫生性(hygiene):为什么宏内的变量不会污染外部
- TT munching 模式:递归宏的标准技巧
- 过程宏三种形态:derive / attribute / function-like
- `syn` + `quote`:解析 + 生成 TokenStream 的工具链
- 写一个简单的 derive macro:自动生成 builder
- 调试宏:`cargo expand` 是你的好朋友
- **宏使用纪律**:什么时候用宏,什么时候用泛型,什么时候用 trait

**与你已有知识的连接**:C# Source Generator、TS decorator、Lisp 宏(精神祖先)

**练习**:为 Onsager 写一个 derive macro,自动生成 spec 文件加载逻辑

**字数预计**:13000

---

### Ch 18 · Unsafe Rust — Rustonomicon 速成

**核心问题**:`unsafe` 不是"关掉安全检查",是"我向编译器承诺以下不变量"。

**主要内容**:
- `unsafe` 能做的五件事:解引用裸指针、调用 unsafe 函数、访问/修改可变 static、实现 unsafe trait、访问 union 字段
- Aliasing 规则:Stacked Borrows / Tree Borrows 模型简介
- Undefined Behavior 清单:你必须避免的事情
- `UnsafeCell` 的真实含义:为什么 `&T` 不一定不可变
- Lifetime variance:协变 / 逆变 / 不变,什么时候你必须显式标注 `PhantomData`
- 写正确的 `unsafe` 代码:封装边界、不变量文档、调用方契约
- `Send` / `Sync` 的手动实现:危险与必要
- Miri:Rust 的 UB 检测器,如何把它纳入 CI
- **案例分析**:`Vec::push` 的源码、`Box::new` 的源码、`Rc::clone` 的源码

**与你已有知识的连接**:C 指针、C# unsafe block、Go unsafe.Pointer

**练习**:实现一个 unsafe 但正确的 ring buffer,用 Miri 验证

**字数预计**:16000

---

### Ch 19 · FFI 与跨语言边界

**核心问题**:Rust 和别的语言怎么互操作?

**主要内容**:
- C ABI:`extern "C"` / `#[repr(C)]` / `#[no_mangle]`
- 调 C 库:`bindgen` 自动生成 binding
- 暴露 Rust 给 C/C++:`cbindgen`
- PyO3:暴露 Rust 给 Python(对你 AI 工程意义重大)
- napi-rs:暴露 Rust 给 Node.js
- WASM:Rust 编译到浏览器
- FFI 安全检查清单:lifetime 穿越边界、panic 不能跨 FFI、错误码 vs 异常
- 真实案例:`ruff`(Python linter,用 Rust 写)、`turbo`(Vercel 的构建工具)

**与你已有知识的连接**:你 14 年里跨语言互操作的所有经验

**练习**:用 PyO3 给 Python 暴露一个 Rust 计算密集函数

**字数预计**:11000

---

### Ch 20 · Capstone:从零实现一个 Mini-Tokio

**核心问题**:把全书所有概念串起来,写一个能跑的异步 runtime。

**主要内容**:
- 设计目标:支持 spawn、await、timer、channel
- 数据结构:Task queue、Reactor、Waker
- 实现 step 1:单线程 executor,支持 `block_on`
- 实现 step 2:支持 `spawn` 与并发 task
- 实现 step 3:实现 `Sleep` Future 与 timer wheel
- 实现 step 4:实现 channel
- 实现 step 5:多线程 work-stealing scheduler
- 与真 Tokio 对比:你做了哪些简化,真 Tokio 多了什么
- **回答一个问题**:看完这本书你能不能给 Tokio 提 PR?可以,从 issue tracker 找 good first issue 开始

**练习**:把这个 mini-tokio 跑通,然后给真 Tokio 提一个文档 PR 作为毕业作

**字数预计**:18000

---

## 附录

- **附录 A**:Rust 编译器报错读法手册(常见 50 种报错的解读模板)
- **附录 B**:从 Go 到 Rust 的概念翻译大全(Ch 1 翻译表的扩展版,200+ 条)
- **附录 C**:从 C# 到 Rust 的概念翻译大全
- **附录 D**:cargo / clippy 常用配置与命令速查
- **附录 E**:推荐阅读路线图:进阶资源、社区资源、要 follow 的人

---

## 写作进度

- [x] 大纲(本文档)
- [ ] Ch 1 · 为什么 Rust 不一样(样章,见 `rust-book-ch01.md`)
- [ ] Ch 2-20 · 待定

---

*Drafted 2026-05 · Working title, subject to change.*
