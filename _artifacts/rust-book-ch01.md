# 第 1 章 · 为什么 Rust 不一样

> "If you're going to learn Rust, you need to first unlearn some things you know about programming."
> — 一位匿名 Rust 老手

这一章不教语法。这一章只做一件事:**让你对 Rust 这门语言形成正确的预期**。

如果你跳过这一章直奔后面的 ownership、trait、async,你会在某个时刻撞墙。撞墙的原因不是技术,是心智模型——你带着 Go 或 C# 的世界观走进 Rust,会发现编译器一直在拒绝你"明显正确"的代码。这章帮你提前调整世界观。

---

## 1.1 这本书是写给谁的

直接对话——你已经写了 14 年代码。你懂 GC、懂 channel、懂 interface、懂 async/await、懂 generic constraint、懂 monorepo、懂分布式系统的取舍。市面上的 Rust 书要么把你当成 C++ 老兵(假设你天天手写 `new`/`delete`),要么把你当成新手(从 `let x = 1` 讲起),都不合适。

**这本书假设你已经会的事情**:

- 至少一门 GC 语言到生产级(Go / Java / C# / Python / TS 任意一种)
- 并发的基本概念:thread、mutex、race condition、deadlock
- 异步的基本概念:event loop、Promise/Task、callback hell
- 泛型与接口:Go interface、C# generic、TS type parameter
- 工程基础:版本控制、CI/CD、依赖管理、单元测试

**这本书不会教你的事情**:

- 什么是变量
- 什么是函数
- 什么是循环
- 什么是面向对象

**这本书不是**:

- *Rust 语法手册*(那是 *The Rust Reference*)
- *Rust 食谱*(那是 *Rust by Example*)
- 一本万人通用的教科书

**这本书是**:

- 一份从你已知世界出发,到 Rust 的迁移指南
- 一本对你已有的工程直觉做"必要拆除和重建"的书
- 一本写到 unsafe 与 async runtime 内部的全栈视图

---

## 1.2 五分钟内看到 Rust 的差异

理论说再多不如一段代码。下面这个任务用三种语言实现:**并发抓取一组 URL,把响应体收集起来**。

### Go 版本

```go
func fetchAll(urls []string) []string {
    results := make([]string, len(urls))
    var wg sync.WaitGroup
    for i, url := range urls {
        wg.Add(1)
        go func(i int, url string) {
            defer wg.Done()
            resp, err := http.Get(url)
            if err != nil {
                return
            }
            defer resp.Body.Close()
            body, _ := io.ReadAll(resp.Body)
            results[i] = string(body)
        }(i, url)
    }
    wg.Wait()
    return results
}
```

写得很自然。但请回答几个问题:

- `results[i] = string(body)` 是在多个 goroutine 里并发写同一个 slice。这为什么是安全的?
- 答:因为不同 goroutine 写**不同的 index**,所以底层数组的不同 cache line 不会冲突。这是程序员的承诺,**编译器不验证**。
- 如果某天你重构,把 `results[i] = ...` 改成 `results = append(results, ...)`,会发生什么?
- 答:运行时数据竞争,`go test -race` 可能能抓到,生产环境可能不能。线上挂掉。

### C# 版本

```csharp
async Task<List<string>> FetchAll(List<string> urls)
{
    using var client = new HttpClient();
    var tasks = urls.Select(u => client.GetStringAsync(u));
    return (await Task.WhenAll(tasks)).ToList();
}
```

更简洁。但请注意:

- `client` 是被 closure 捕获的。多个 task 并发使用同一个 `HttpClient`——这为什么安全?
- 答:因为 `HttpClient` 的设计者承诺它线程安全。这是**库的承诺**,编译器不验证。
- 如果你换成自己的 stateful object,async 之间的状态污染需要你自己想清楚。
- 如果你忘了 `await`(`var tasks = ...; return tasks.ToList();`),编译器会给你警告但不会报错。Production crash 风险。

### Rust 版本(Tokio)

```rust
use reqwest::Client;
use futures::future::join_all;

async fn fetch_all(urls: Vec<String>) -> Vec<String> {
    let client = Client::new();
    let futures = urls.into_iter().map(|u| {
        let client = client.clone();
        async move {
            let resp = client.get(&u).send().await?;
            let body = resp.text().await?;
            Ok::<_, reqwest::Error>(body)
        }
    });
    join_all(futures)
        .await
        .into_iter()
        .filter_map(|r| r.ok())
        .collect()
}
```

表面看 Rust 版本啰嗦一些,有几个 `clone()` 和 `await`。但请注意以下三件事:

1. **编译器强制了所有并发安全约束**。每一个跨 task 共享的值都被编译器验证满足 `Send + Sync` 约束。运行时不会有 data race——这不是承诺,这是定理。
2. **没有"忘了 await"这种错误**。Rust 的 Future 是 lazy 的,你必须 await 才能让它执行。如果你忘了,编译器会警告"unused future, must be polled"。
3. **`client.clone()` 不是性能问题**。`reqwest::Client` 内部是 `Arc`,clone 只是引用计数 +1。Rust 让你**显式看到**这个 clone,而 C# 把它隐藏在引用类型的语义里。

**这是 Rust 的差异化价值**:

> 它把工程纪律编译期化了。

你在 Go 和 C# 里靠"小心"和"测试"维护的不变量,在 Rust 里被编译器固化下来。代价是学习曲线陡峭。收益是一旦代码编译通过,一大类 bug 就被排除了。

---

## 1.3 Rust 的三个核心承诺

Rust 反复宣传三件事。每一件背后都有具体含义和具体代价。

### 承诺 1:Memory Safety Without GC

| 维度 | C / C++ | Go / Java / C# | Rust |
|---|---|---|---|
| 内存安全 | ❌ 程序员负责 | ✅ GC 负责 | ✅ 编译器负责 |
| 运行时开销 | 无 | 有 GC pause、heap overhead | 无 |
| 学习成本 | 中(但 bug 多) | 低 | 高 |
| 决定时刻 | 运行时(crash) | 运行时(GC) | **编译期** |

Rust 的差异:**把别的语言放在运行时的安全检查搬到编译期**。代价是你要学一套新的概念(ownership、borrowing、lifetime),收益是没有 GC pause、没有 use-after-free、没有 double-free、没有 buffer overflow。

### 承诺 2:Fearless Concurrency

| 维度 | C / C++ | Go | Rust |
|---|---|---|---|
| Data race | ❌ 易发 | ❌ 运行时检测 | ✅ 编译期阻止 |
| Deadlock | ❌ 易发 | ❌ 易发 | ❌ 易发(没解决这个) |
| Send/Sync 检查 | 无 | 无(靠纪律) | ✅ 编译期 marker trait |
| Channel | 库提供 | 语言原生 | 库提供(std + crossbeam + tokio) |

Rust 没解决死锁,但解决了**数据竞争**。这是通过 `Send` 和 `Sync` 两个 marker trait 在编译期完成的——任何不满足这两个约束的代码,在跨线程时编译就过不了。

### 承诺 3:Zero-Cost Abstractions

> "What you don't use, you don't pay for. What you do use, you couldn't hand-code any better."
> — Bjarne Stroustrup

Rust 借了 C++ 这个理念,做得比 C++ 还彻底。具体表现:

- 泛型用 monomorphization(单态化),编译期为每个具体类型生成代码,运行时无 dispatch 开销
- Iterator chain `vec.iter().map(...).filter(...).sum()` 编译后等同于手写 for 循环
- async 函数被编译成状态机,没有线程、没有协程栈分配,内存占用极小
- 不用就不付:你不写 `Box::new` 就没有 heap 分配,你不写 `Mutex` 就没有锁

代价是**编译时间**。Rust 编译比 Go 慢 5-10 倍。这是已经被反复讨论的工程权衡。

---

## 1.4 概念翻译表(本书最重要的一页)

把这页打印出来贴在显示器旁边。下面所有章节都会用这张表。

### 内存与所有权

| 你已经懂的 (Go / C# / TS) | Rust 对应 | 关键差异 |
|---|---|---|
| Go: GC 自动回收 | Ownership + `Drop` | Rust 是编译期决定,无 GC 开销 |
| Go: `defer` 资源清理 | `Drop` trait + RAII | Rust 自动调用,不需要写 `defer` |
| C#: `using` / `IDisposable` | `Drop` trait | 同上,Rust 不需要 `using` 关键字 |
| Go: pointer `*T` | `&T` 借用 / `Box<T>` 拥有 | Rust 区分"借用"和"拥有",Go 不区分 |
| Go: nil pointer | `Option<T> = None` | `Option` 是 enum,必须显式 match |
| C#: `ref` / `out` | `&mut T` | Rust 的 `&mut` 受借用规则约束 |
| C#: nullable reference | `Option<T>` | Rust 没有 null,所有"可能为空"都是 Option |
| TS: `T \| undefined` | `Option<T>` | 同上,但 Rust 编译器强制处理 None 分支 |

### 错误处理

| 你已经懂的 | Rust 对应 | 关键差异 |
|---|---|---|
| Go: `if err != nil` | `Result<T, E>` + `?` | `?` 自动 propagate,不用写 `if` |
| C#: `try / catch` | `Result<T, E>` + `?` | Rust 没有 exception,错误是值 |
| Go: `panic` | `panic!` | 行为相似,但 Rust 不鼓励用 panic 处理业务错误 |
| C#: exception inheritance | `Box<dyn Error>` / 自定义 enum | Rust 没有继承,用 enum 或 trait object |

### 类型系统

| 你已经懂的 | Rust 对应 | 关键差异 |
|---|---|---|
| Go: `interface` | `trait` | Rust trait 多了 associated types、blanket impl、static dispatch |
| C#: `interface` | `trait` | Rust trait 没有继承,用 supertrait 表达约束 |
| TS: `interface` | `trait` | TS 是 structural typing,Rust 是 nominal + 显式 `impl` |
| TS: discriminated union | `enum` | 几乎一样的语义,Rust 更严格 |
| C#: pattern matching | `match` | Rust 强制穷尽性 |
| Go: `switch v.(type)` | `match` on enum | Rust 的更强,因为类型本身就是 enum |
| C#: generic `where T : ...` | `where T: ...` | 语法几乎一样 |
| Go: 泛型(1.18+) | 完整泛型系统 | Rust 远比 Go 强大 |
| TS: conditional types | (没直接对应) | Rust 用 trait + impl block 实现类似效果 |

### 并发与异步

| 你已经懂的 | Rust 对应 | 关键差异 |
|---|---|---|
| Go: goroutine | `tokio::spawn` 或 `std::thread::spawn` | Tokio task 是 stackless,thread 是 OS 线程 |
| Go: channel | `mpsc::channel` 或 `tokio::sync::mpsc` | Rust channel 区分 owned vs cloned sender |
| Go: `sync.Mutex` | `std::sync::Mutex` 或 `tokio::sync::Mutex` | Rust 的 Mutex 把数据**包在里面**,只能通过锁访问 |
| Go: `sync.WaitGroup` | `JoinHandle::join()` 或 `JoinSet` | Rust 用所有权表达"等待这个 task" |
| C#: `Task<T>` | `Future<Output = T>` | Rust Future 是 lazy,Task 是 hot |
| C#: `async/await` | `async/await` | 语法一样,语义不一样(lazy vs eager) |
| C#: `IDisposable async` | Drop in async (有坑) | Rust 在 async 里 drop 资源有微妙问题 |
| JS: Promise | `Future` | 同 Task,Promise 是 hot |

### 工程实践

| 你已经懂的 | Rust 对应 | 关键差异 |
|---|---|---|
| Go: `go.mod` | `Cargo.toml` | Cargo 功能更多(workspace、feature、build script) |
| pnpm workspace | Cargo workspace | 概念几乎一样 |
| Go: `go test` | `cargo test` | Rust 测试可以写在源文件里(`#[cfg(test)] mod tests`) |
| Go: `go vet` | `cargo clippy` | Clippy 更严格,有 600+ lints |
| C#: NuGet | crates.io | 几乎一样的发布模式 |
| C#: source generator | proc macro | 概念相似,Rust 更强大 |

---

## 1.5 Rust 难学的真相

### 误区与真相

**误区 1**:Rust 难是因为语法多。

**真相**:Rust 语法不复杂。它的 keyword 比 C++ 少,比 Java 多一点。语法不是难点。

**误区 2**:Rust 慢是因为代码量大。

**真相**:Rust 代码量和 Go 相当,有时候更短(thanks to iterator chain 和 `?` 操作符)。

**误区 3**:Rust 难是因为有指针。

**真相**:Rust 没有 C 那种"裸指针到处飞"的指针。`&T` / `&mut T` 是引用,有严格规则;`Box<T>` / `Rc<T>` / `Arc<T>` 是智能指针,自动管理。真要用裸指针得进 `unsafe` 块。

**真正的难点**:

> Rust 要求你**显式表达内存所有权**——这是别的 GC 语言帮你隐藏掉的一个维度。

GC 语言里,你脑子里只有一个问题:"这个变量的值是什么?"。Rust 里你必须同时回答两个问题:**"这个变量的值是什么?"** 和 **"这个变量拥有这个值,还是只是借用?"**

多了一个维度。所有难点都从这里派生。

### 学习曲线的三个阶段

```
能力
 ↑
 │                                          ┌──── 流畅期
 │                                       ╱
 │                                    ╱
 │                                 ╱
 │   .clone() 期 ──────────────╱     ← 危险区!
 │                          ╱
 │                       ╱
 │                    ╱
 │                 ╱
 │   挫败期 ────╱
 │           ╱
 │        ╱
 │     ╱
 │  ╱
 └────────────────────────────────────────→ 时间
   Week 1     Week 2-3    Week 4-6    Week 7+
```

**Week 1:挫败期**

你每天被编译器拒绝 30 次。最常见的报错:

- `cannot borrow X as mutable because it is also borrowed as immutable`
- `X does not live long enough`
- `cannot move out of borrowed content`
- `the trait Send is not implemented for ...`

正常反应:气馁、怀疑自己、怀疑 Rust 是不是太极端了。

**Week 2-3:`.clone()` 期(危险!)**

你开始猜出哪些写法会被拒绝。但你的应对方式可能是错的——很多人在这个阶段开始**用 `.clone()` 绕过所有借用检查**。

```rust
// 这就是 .clone() 期的典型代码
fn process(data: &Vec<String>) -> Vec<String> {
    let copy = data.clone();  // 不必要的 clone
    let filtered: Vec<String> = copy.into_iter()
        .filter(|s| s.len() > 0)
        .map(|s| s.clone())  // 又一个不必要的 clone
        .collect();
    filtered
}
```

**这是危险时刻**。如果你停在这里,你就永远没真正学会 Rust。你写的是"看起来像 Rust 的 Go 代码"。性能没优势,工程纪律没提升,只是把 Go 的代码硬翻译过来。

**正确的反应**:每次借用错误是一次"你没想清楚所有权"的提醒。停下来想:这个值真的需要被两个地方同时拥有吗?如果是,是不是该用 `Arc`?如果不是,是不是该用 `&` 借用?如果是,生命周期怎么排?

如果你在 Week 2-3 反复练这个思考过程,Week 4 后你就真的会 Rust 了。

**Week 4-6:开窍期**

某天你会突然发现:

- 你看到一段代码就能猜出借用检查器会不会接受
- 你设计 API 时会考虑"这个参数应该是 owned 还是 borrowed"
- 你看 stdlib 源码不再处处看到 unsafe 就害怕——你能读懂为什么这里需要 unsafe
- 你会主动减少 `.clone()`,用 `&str` / `Cow` / `Arc` 等更精细的工具

**Week 7+:流畅期**

Rust 不再是阻力。你能像写 Go 一样自然地写 Rust。差别在于:你的代码编译过了之后,bug 比 Go 版本少一个数量级。

### 关键建议

1. **不要在 Week 2-3 用 AI 帮你绕过借用错误**。每次借用错误都自己读编译器报错,自己想为什么。AI 帮你解决了表面问题,但你的 mental model 没建立起来。
2. **每次想 `.clone()` 之前,问自己**:这个值我是真的需要复制?还是我没想清楚所有权?
3. **不要怕慢**。Week 1-3 慢是正常的。Week 4 后你的速度会追上来,Week 7 后你会比 Go 写得还快(因为 bug 少)。
4. **找一个真实项目**。toy project 不够。给 Stiglab 提 PR,或者把你的某个 Crawlab 子模块用 Rust 重写。

---

## 1.6 这本书的承诺与不承诺

**承诺**:

- 读完你能给 Tokio / Axum / Hyper 这一级别的项目提交可合并的 PR
- 读完你能写 `unsafe` 代码而不引入 undefined behavior
- 读完你能给同事讲清楚"为什么 Rust 这样设计",而不是只会照抄
- 读完你看 Rust 编译器报错时,能立刻识别错误模式

**不承诺**:

- 不会让你成为 rustc(Rust 编译器)贡献者——那是另一本书
- 不会精讲 Rust 嵌入式开发(`no_std`、bare metal)——只在 Ch 19 简介
- 不会教你具体某个领域的 best practice(Web 后端讲 Axum,但不会教你怎么设计一个支付系统)

**阅读建议**:

- Part I(Ch 1-3)必须按顺序读,不能跳
- Part II 之后可以按需跳读
- 每章末尾的练习不要跳。Rust 是练出来的,不是看出来的
- 配套代码仓库的 cargo workspace 跑起来,每章在对应子目录写代码

---

## 1.7 准备工作

### 安装 toolchain

```bash
# 安装 rustup(Rust 的版本管理器,类似 nvm)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 验证安装
rustc --version    # 应该看到 rustc 1.x.x
cargo --version    # 应该看到 cargo 1.x.x

# 安装常用组件
rustup component add clippy rustfmt rust-analyzer rust-src
```

### 配置编辑器

**强烈推荐 VS Code + rust-analyzer 插件**(就算你平时用 JetBrains)。rust-analyzer 是目前最好的 Rust LSP,JetBrains 的 RustRover 也基于它,但 VS Code 的 setup 更轻。

VS Code 必装插件:
- `rust-lang.rust-analyzer`
- `tamasfe.even-better-toml`(Cargo.toml 高亮)
- `vadimcn.vscode-lldb`(调试)
- `serayuzgur.crates`(依赖版本提示)

### Hello World

```bash
cargo new hello-rust
cd hello-rust
cargo run
```

输出:

```
   Compiling hello-rust v0.1.0 (...)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.42s
     Running `target/debug/hello-rust`
Hello, world!
```

打开 `src/main.rs`:

```rust
fn main() {
    println!("Hello, world!");
}
```

注意 `println!` 后面的 `!`——这是宏调用,不是函数调用。Rust 区分得很严格。Ch 17 详讲。

### 第一个有意义的程序

下面这段代码故意写得啰嗦,演示几个本书后面会讲的核心特性。**先运行起来,不需要全懂**。

```rust
use std::io::{self, BufRead, Write};

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();

    writeln!(out, "Type a string (Ctrl+D to exit):").unwrap();

    for line in stdin.lock().lines() {
        match line {
            Ok(s) => {
                let reversed: String = s.chars().rev().collect();
                writeln!(out, "Reversed: {}", reversed).unwrap();
            }
            Err(e) => {
                eprintln!("Error: {}", e);
                break;
            }
        }
    }
}
```

运行 `cargo run`,输入几行字符串,看到反转后的输出,Ctrl+D 退出。

观察这段代码,你已经看到了本书后面会展开的几个概念:

- `let mut out = stdout.lock()` —— `mut` 是显式可变性,默认不可变
- `match line { Ok(s) => ..., Err(e) => ... }` —— `Result` 用 match 处理
- `s.chars().rev().collect()` —— iterator chain,Ch 10 详讲
- `.unwrap()` —— 出错就 panic,**这是练习代码**,生产里不应该这样
- `&` 和 `mut` 在参数里出现 —— 借用,Ch 3 详讲

### 验收标准

进入下一章前,确认以下事情你都做到了:

- [ ] `cargo --version` 能跑出版本号
- [ ] VS Code 打开 hello-rust 项目,鼠标悬停在 `String` 上能看到类型提示
- [ ] 上面那段反转字符串的程序能编译运行
- [ ] 你能在不查资料的情况下解释 `let` 和 `let mut` 的区别
- [ ] 你能猜出 `String::new()` 和 `let s: String = ...` 的差别(都行,凭直觉答)

---

## 本章习题

### 习题 1.1(简单)

把"反转字符串"程序改成"统计每行单词数"。提示:`split_whitespace()` 和 `count()`。

### 习题 1.2(中等)

写一个程序,从命令行参数读取一个数字 N,打印从 1 到 N 的所有 Fibonacci 数。提示:`std::env::args()`、`parse::<u64>()`、用 `for` 循环或 iterator。

### 习题 1.3(思考题,不用写代码)

回到 1.2 节那个 Go 版本的 `fetchAll`。如果用 Rust 实现等价代码,你预计哪些地方会被借用检查器拒绝?哪些地方需要 `Arc` 或 `clone`?把你的猜测写下来,本书读到 Ch 13 时回头看自己的猜测。

### 习题 1.4(开放题)

回顾你最近 3 个月写的一段代码(任何语言)。如果用 Rust 重写,哪些 bug 会被编译器在编译期拦下?哪些"运行时小心"的约束会变成"编译期保证"?这个练习帮你建立对 Rust 价值的具体感受。

---

## 下一章预告

Ch 2 我们正式进入 ownership。我们会用一个具体的场景反复打磨:把一个 `Vec<String>` 按某个规则分组。你会看到至少 4 种不同的实现方式,每种背后是不同的所有权决策。读完那一章你会理解为什么 Rust 要求你做这些选择,以及怎么做这些选择。

---

> **本章小结**
>
> 1. Rust 的核心差异是**把工程纪律编译期化**。学习曲线陡峭是真的,但不是因为语法,是因为多了"所有权"这个维度。
> 2. 学习的危险时刻是 Week 2-3 的 `.clone()` 期。如果你养成了用 `clone` 绕过借用检查的习惯,你永远学不会 Rust。
> 3. 概念翻译表(1.4 节)是你前几章最常翻的页。Go GC → Drop,Go interface → trait,C# Task → Future,等等。
> 4. 这本书不是从零教编程,而是把你已有的工程直觉迁移到 Rust。每章都假设你能联系到自己的 Go / C# / TS 经验。
