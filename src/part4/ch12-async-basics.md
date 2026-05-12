# Ch 12 · async/await 基础:Future、Pin、Waker

> Rust 异步模型的内部机制

**核心问题**:Rust 的 Future 跟 C# 的 Task 哪里不一样?为什么需要 Pin?

C# 工程师写 `async/await` 写了十年,几乎从不考虑 `Task` 内部如何调度。这套抽象在 C# 工作得好,**代价是有一个 .NET runtime**。Rust 的设计哲学是"零成本 + 无强制 runtime",所以它的 async 比 C# 复杂得多——但理解之后,你能解释 Tokio、能写自定义 executor、能调试看似魔法的 async bug。

读完你应该能:

1. 写出 `Future` trait 的签名,解释 `Poll::Ready` 和 `Poll::Pending` 各自含义
2. 描述编译器把 `async fn` 翻译成什么(状态机)
3. 解释 Rust Future 为什么是 lazy 的,以及它跟 C# Task 的核心差异
4. 看到 Pin 不再发慌,知道它解决的是什么真问题
5. 写一个 50 行的 `block_on` 跑通自己的 Future

---

## 12.1 Future trait 定义

```rust,ignore
pub trait Future {
    type Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}

pub enum Poll<T> { Ready(T), Pending }
```

### 契约

`poll` 是 Future 唯一的方法。它的含义是:**"试着推进一下,看看完成了没"**。

- 返回 `Ready(value)`:计算完成,这是结果
- 返回 `Pending`:还没完,但**Future 已经记录了 Waker**,等它能继续推进时会通知 executor

**executor 不会忙等地反复 poll** —— 它只在 Future 自己说"现在可以了"(通过 Waker.wake())时才再次 poll。这是整个 async 模型的核心。

### 跟 C# Task 对比

| 维度 | C# Task | Rust Future |
|---|---|---|
| 是否立即开始 | 是(hot:创建即调度) | 否(lazy:await 才推进) |
| 谁推进 | TaskScheduler(默认全局 ThreadPool) | 用户选择的 executor |
| 谁分配 | runtime(堆上 Task object) | 编译器(栈上 / 调用方分配状态机) |
| 取消 | CancellationToken,协作式 | Drop Future 即取消(更彻底) |
| 引用语义 | reference type,可多次 await | value type,move-only |

最大差别:Rust Future 是 **lazy value**,不创建运行时副作用。

---

## 12.2 async fn 是编译器生成的状态机

你写:

```rust,ignore
async fn fetch_two(url1: &str, url2: &str) -> (String, String) {
    let a = fetch(url1).await;
    let b = fetch(url2).await;
    (a, b)
}
```

编译器翻译成等价(简化)的状态机:

```rust,ignore
enum FetchTwo<'a> {
    Start { url1: &'a str, url2: &'a str },
    AwaitingA { f: FetchFuture, url2: &'a str },
    AwaitingB { a: String, f: FetchFuture },
    Done,
}

impl Future for FetchTwo<'_> {
    type Output = (String, String);
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        loop {
            match *self {
                Self::Start { url1, url2 } => {
                    let f = fetch(url1);
                    *self = Self::AwaitingA { f, url2 };
                }
                Self::AwaitingA { ref mut f, url2 } => match Pin::new(f).poll(cx) {
                    Poll::Pending => return Poll::Pending,
                    Poll::Ready(a) => {
                        let f2 = fetch(url2);
                        *self = Self::AwaitingB { a, f: f2 };
                    }
                },
                Self::AwaitingB { ref a, ref mut f } => match Pin::new(f).poll(cx) {
                    Poll::Pending => return Poll::Pending,
                    Poll::Ready(b) => {
                        let out = (std::mem::take(a), b);
                        *self = Self::Done;
                        return Poll::Ready(out);
                    }
                },
                Self::Done => panic!("polled after completion"),
            }
        }
    }
}
```

每个 `.await` 是状态机的一个状态。`poll` 时:

1. 看自己在哪个状态
2. 推进:调对应子 Future 的 `poll`
3. 子 Future Pending → 自己也 Pending,记 Waker
4. 子 Future Ready → 转下一个状态,继续 loop

### 用 `cargo expand` 真看一眼

```bash
cargo install cargo-expand
cargo expand --bin myapp | less
```

会看到编译器生成的状态机原貌。第一次看会被吓到,但你**只需要看一次**就能理解 "async fn 不是魔法,是 syntactic sugar"。

---

## 12.3 为什么 Rust Future 是 lazy 的

```rust,ignore
async fn do_work() {
    println!("starting");
    // ...
}

fn main() {
    let f = do_work();   // ← 这里什么都没发生!不会打印 "starting"
    // f 是 Future 值,放在那
}
```

Rust 选择 lazy 是因为:

1. **零运行时**:不需要"创建即调度",所以不需要全局调度器。你完全可以写没有 async runtime 的 Rust async 代码(虽然没法 await,但可以 build)
2. **取消即 drop**:不需要 cancellation token,你直接把 Future 丢掉就停了
3. **组合性**:lazy Future 可以被 `select!` / `join!` / `timeout` 等组合,而不会"已经开始执行"

代价是初学者的迷思:"我的 async fn 没运行!" —— 因为你没 `await`,也没 `spawn`。

### C# 风格的 hot Task

如果你想要 C# 那种"创建即开始",写:

```rust,ignore
let handle = tokio::spawn(do_work());   // ← spawn 之后立刻开始
// handle 是 JoinHandle,可以 await 等结果
```

`spawn` 把 Future 交给 runtime,runtime 立刻开始 poll。`JoinHandle` 自己也是 Future,await 它等任务完成。

---

## 12.4 `.await` 的解糖

```rust,ignore
let x = some_future.await;
```

约等于(伪代码):

```rust,ignore
let mut f = some_future;
loop {
    match Future::poll(Pin::new(&mut f), &mut cx) {
        Poll::Ready(v) => break v,
        Poll::Pending => yield,   // 把控制权让回 executor,等被唤醒再继续
    }
}
```

`yield` 不是真关键字——编译器把这个 loop 编入它生成的状态机,实际上是 `return Poll::Pending`。

### Waker 在哪儿注册

`poll(cx)` 的 `cx: &mut Context<'_>` 里携带 `&Waker`。Future 内部需要"等某件事发生"时,**把 Waker 存起来**,事件发生时调 `waker.wake()`。

例如 `tokio::time::sleep`:

1. 第一次 poll:计算 deadline,把 (deadline, waker.clone()) 注册到 timer wheel,返回 Pending
2. timer 到点:timer 线程取出 waker,`wake()`
3. executor 重新 poll 该 Future:`Ready(())`

---

## 12.5 Pin 解决的真问题

### self-referential struct

考虑编译器生成的状态机:

```rust,ignore
enum Stateful {
    Start,
    Reading { buf: [u8; 1024], ref_into_buf: *const u8 },   // 内部自引用!
    Done,
}
```

`ref_into_buf` 指向同一个结构体内的 `buf`。如果你 `move` 这个 struct,`buf` 在新地址,`ref_into_buf` 还指向旧地址 → dangling pointer。

这种 self-referential struct 在 `async fn` 里**普遍出现**——你 `await` 一个借用栈上 buffer 的子 Future,编译器生成的状态机就会自引用。

### Pin 的设计

`Pin<P>`(P 是某种指针)的契约:**被 Pin 起来后,值的内存地址不再变**。

- `Pin<&mut T>` 给你 `&mut T`,但你不能用它来 `mem::swap` / `mem::replace`(会移动)
- 一旦 Pin,直到 drop,值都待在原地

只有"地址不变"才让 self-referential struct 内部的指针保持有效。`Future::poll` 的签名是 `self: Pin<&mut Self>` 而不是 `&mut self`,就是因为状态机可能自引用。

### Unpin:大部分类型不需要被 Pin

`Unpin` 是 auto trait:大部分类型实现它,意思是"我没有 self-reference,move 我没事"。`u32` / `String` / 普通 struct 都是 `Unpin`。

只有"编译器生成的 async 状态机"以及一些手写 unsafe 类型(`PhantomPinned` 标记)不是 `Unpin`,需要小心处理。

### 业务代码里你看到的 Pin

```rust,ignore
fn do_thing<F: Future + Unpin>(mut f: F) {
    let pin = Pin::new(&mut f);   // 因为 F: Unpin,可以这样
}

// 大部分时候你这样
async fn outer() {
    let f = inner();
    f.await;   // 编译器自动给你 pin,你完全不用想
}
```

**90% 的应用代码不需要直接接触 Pin**。只有写库、写 executor、写自定义 stream 时才需要。

---

## 12.6 Waker 与 Context

```rust,ignore
pub struct Context<'a> { /* ... */ }
impl<'a> Context<'a> { pub fn waker(&self) -> &'a Waker { /* ... */ } }

pub struct Waker { /* ... */ }
impl Waker {
    pub fn wake(self);              // 消耗 self
    pub fn wake_by_ref(&self);
    pub fn clone(&self) -> Waker;   // 实现 Clone
}
```

### Waker 是什么

Waker 内部是 `RawWaker` —— 一个 vtable + data 的组合,把"通知 executor 重新 poll" 的实现交给 executor。Tokio 的 Waker 会把当前任务标记 ready,放回任务队列。

### 谁负责调 wake

**等异步事件的那一方**——比如:

- timer:到点后唤醒
- IO source:fd ready 时唤醒
- channel:有消息时唤醒发送侧 Waker

如果你写自己的 Future,要在收到事件时主动调 `waker.wake()`。**忘记 wake = Future 永远 pending = 任务僵死**。这是写底层 async 库最常见的 bug。

---

## 12.7 手撸最简 executor

50 行跑通 `block_on`(单 Future,无 spawn):

```rust,ignore
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Wake, Waker};
use std::thread;

struct Park(Mutex<bool>, std::sync::Condvar);
impl Wake for Park {
    fn wake(self: Arc<Self>) {
        *self.0.lock().unwrap() = true;
        self.1.notify_one();
    }
}

fn block_on<F: Future>(future: F) -> F::Output {
    let park = Arc::new(Park(Mutex::new(false), std::sync::Condvar::new()));
    let waker = Waker::from(park.clone());
    let mut cx = Context::from_waker(&waker);

    // 用 Box::pin 在堆上 pin Future
    let mut future = Box::pin(future);
    loop {
        match future.as_mut().poll(&mut cx) {
            Poll::Ready(v) => return v,
            Poll::Pending => {
                let mut woken = park.0.lock().unwrap();
                while !*woken {
                    woken = park.1.wait(woken).unwrap();
                }
                *woken = false;
            }
        }
    }
}
```

```rust,ignore
fn main() {
    let result = block_on(async {
        // 任何不依赖 IO 的 async 代码都能跑
        1 + 1
    });
    println!("{}", result);
}
```

支持 spawn / timer / IO 的 executor 还要几百行,Ch 20 一步步搭。

---

## 12.8 为什么 Rust 选择"无运行时 by default"

C# / Go / Node.js 都内置 async runtime——你写 async 代码就有一个调度器在跑。Rust 没有,你必须**显式选** Tokio / async-std / smol。

设计动机:

1. **嵌入式**:无 std、无 alloc 的环境也要能写 async(WASM 部分场景)
2. **多种 runtime 共存**:Tokio 适合服务器,smol 适合 CLI,自定义 executor 适合特殊场景
3. **零成本一致性**:运行时是"你需要时才付费"

代价是**生态分裂**:不同 runtime 的 IO 类型不兼容(`tokio::TcpStream` ≠ `async_std::TcpStream`)。社区在用 `async-io` / Trait 抽象慢慢解决,但目前最实用的选择就是 **all-in Tokio**。

---

## 习题

1. 用 `cargo expand` 看 `async fn ten() -> i32 { 10 }` 编译后是什么。
2. 实现一个 `Yield` Future:第一次 poll 返回 Pending 并唤醒自己,第二次返回 `Ready(())`。理解为什么这样做相当于"主动让出一次 CPU"。
3. 改造 12.7 的 `block_on` 加一个简单的 `spawn`:把任务推到一个 `Vec<Pin<Box<dyn Future>>>`,主循环 poll 所有任务。
4. 写一个 `Sleep` Future:用 `std::thread` 起一个 timer 线程,到点 wake。在 12.7 的 executor 上验证。
5. 给一个写错的 Future 例子(漏调 `waker.wake_by_ref`),解释为什么任务僵死。

---

> **本章一句话总结**
>
> Rust async 不是 magic——它是编译器把 async fn 翻译成状态机,加上一组接口契约(Future / Waker / Context / Pin)。理解这个,Tokio 内部就不再神秘。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
