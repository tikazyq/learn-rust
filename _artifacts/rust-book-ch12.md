# 第 12 章 · async/await 基础 —— Future、Pin、Waker

> "C# 的 async 是个 runtime 设计。Rust 的 async 是个语言设计。这导致一切都不一样。"

C# 写 `await` 你就开心地用了——背后有 TaskScheduler、ThreadPool、SynchronizationContext 这些 runtime 设施。

Rust 没有 built-in runtime。你必须显式选一个(Tokio / async-std / smol),并且理解 Future、Pin、Waker 这些底层概念——否则某个时刻你会撞到一个看不懂的 lifetime 错误或者性能 cliff。

这章是这本书技术密度最高的章节之一。读完你应该能:

1. 解释 Rust Future 跟 C# Task 的根本差异(lazy vs eager)
2. 看到 `async fn` 时知道编译器在生成什么(状态机)
3. 知道 Pin 解决的真问题(self-referential struct)
4. 写一个最简 executor,理解 Waker 怎么驱动

---

## 12.1 Rust async 的设计哲学

### C# 的 async

```csharp
async Task<int> Compute() {
    await Task.Delay(1000);
    return 42;
}

var task = Compute();   // ← 这里 task 已经开始运行
var result = await task;
```

C# 的 Task 是 **hot** 的——创建即开始执行。底层是 TaskScheduler 自动调度。

### Rust 的 async

```rust
async fn compute() -> i32 {
    tokio::time::sleep(Duration::from_secs(1)).await;
    42
}

let fut = compute();    // ← 这里 fut 还没有执行任何代码
let result = fut.await; // ← 现在才开始执行
```

Rust 的 Future 是 **lazy** 的——`async fn` 调用返回一个 Future,但不执行。只有它被 `.await` 或被 executor 驱动时才执行。

### 为什么 lazy?

设计决定。lazy 让 Rust 不需要 built-in runtime——Future 就是个数据结构,谁拿到谁决定怎么驱动。这给了生态自由(Tokio、async-std、自定义 runtime),代价是用户要承担"理解 Future 是什么"。

实际工程含义:

```rust
async fn do_something() {
    println!("starting");
    // ...
}

fn main() {
    do_something();         // 编译警告:`Future` must be polled
    // println 不会执行,因为 fut 没被 await/poll
}
```

如果你写 C# 的 async 经验进来,这是第一个陷阱。**`async fn` 返回 Future 后什么都没发生**,直到有人驱动它。

---

## 12.2 Future trait

```rust
pub trait Future {
    type Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}

pub enum Poll<T> {
    Ready(T),
    Pending,
}
```

整个 async 系统底层就这一个 trait。`poll` 被 executor 调用:

- 返回 `Poll::Ready(value)` —— future 完成,产出 value
- 返回 `Poll::Pending` —— 还没好,稍后再来

### `Context` 和 Waker

`Context` 主要装一个 `Waker`。Waker 是 executor 给 future 的"call me back"接口。

工作流程:

1. Executor 调 `future.poll(cx)`
2. Future 检查"我能进度吗?"
3. 不能 → 把 cx.waker() 存起来,返回 Pending
4. 当条件成熟(IO 完成、timer 到期),被存的 waker 调 `wake()`
5. Executor 收到 wake 信号,把 future 重新放进队列,再次 poll

这是 **pull-based**(轮询式)的异步模型。跟 JS 的 Promise(callback-push)、C# 的 Task(scheduler-driven)都不同。

### 一个具体例子

```rust
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

struct Ready { value: Option<i32> }

impl Future for Ready {
    type Output = i32;
    fn poll(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<i32> {
        Poll::Ready(self.value.take().unwrap())
    }
}

// 这个 Future 一调 poll 就完成
let fut = Ready { value: Some(42) };
// let result = fut.await;  // 在 async 上下文里能 await
```

更典型的 Future 会先返回 Pending,稍后被唤醒。

---

## 12.3 async fn 编译成状态机

你写的:

```rust
async fn double_fetch(client: &Client) -> Result<(String, String), Error> {
    let a = client.fetch("a").await?;
    let b = client.fetch("b").await?;
    Ok((a, b))
}
```

编译器生成的(大致):

```rust
enum DoubleFetchFuture<'a> {
    Init { client: &'a Client },
    WaitingA { client: &'a Client, fut_a: FetchFuture<'a> },
    WaitingB { client: &'a Client, fut_b: FetchFuture<'a>, a: String },
    Done,
}

impl<'a> Future for DoubleFetchFuture<'a> {
    type Output = Result<(String, String), Error>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context) -> Poll<...> {
        loop {
            match &mut *self {
                State::Init { client } => {
                    let fut_a = client.fetch("a");
                    *self = State::WaitingA { client: *client, fut_a };
                }
                State::WaitingA { client, fut_a } => {
                    match Pin::new(fut_a).poll(cx) {
                        Poll::Pending => return Poll::Pending,
                        Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                        Poll::Ready(Ok(a)) => {
                            let fut_b = client.fetch("b");
                            *self = State::WaitingB { client: *client, fut_b, a };
                        }
                    }
                }
                State::WaitingB { client, fut_b, a } => {
                    match Pin::new(fut_b).poll(cx) {
                        Poll::Pending => return Poll::Pending,
                        Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                        Poll::Ready(Ok(b)) => {
                            let a = std::mem::take(a);
                            *self = State::Done;
                            return Poll::Ready(Ok((a, b)));
                        }
                    }
                }
                State::Done => panic!("polled after completion"),
            }
        }
    }
}
```

每个 `.await` 是状态机的一个停顿点。**没有线程切换,没有协程栈,只是一个 enum + match**。这是 Rust async 零成本的根源——一个 async 函数就是个用 enum 表达的状态机,零堆分配(除非编译器决定 boxing)。

### 重要含义

- async fn 不"启动"任何线程,只是返回一个状态机数据结构
- await 不"yield"给 scheduler,只是 match 到 Pending 并 return
- 整个 future 链可以被 collapsed 进单个堆栈帧

跟 Go goroutine 对比:Go 每个 goroutine 是 stackful(独立栈),Rust future 是 stackless(状态机),内存占用极小(几十字节 vs goroutine 的几 KB)。

---

## 12.4 Pin:Rust async 最难的概念

到现在我们一直忽略 `Pin<&mut Self>`。现在不能再忽略了。

### 问题:self-referential struct

考虑一个 future,它内部持有一个 Vec 和指向 Vec 内部的指针:

```rust
struct SelfRef {
    data: Vec<u8>,
    ptr: *const u8,  // 指向 data 内部
}
```

如果 SelfRef 被 move 到内存的另一个位置,`data` 跟着 move 了(它在 SelfRef 内部),`ptr` 仍然指向**老地址**——悬垂指针。

普通 Rust 类型不会出现这种情况——move 是 bitwise copy + 标记原 location 失效,谁也不会指向 "自身内部"。

但 async fn 编译生成的状态机经常需要这种引用。考虑:

```rust
async fn process() {
    let s = String::from("hello");
    let r = &s;                  // 借用栈上的 s
    other_async_fn(r).await;     // r 跨 await 点持有
}
```

状态机 generator 需要把 `s` 和 `r` 都存进状态——`s` 是 owned String,`r` 是指向 s 内部的引用。这是 self-referential——结构内一个字段指向同结构的另一个字段。

如果这个状态机被 move,引用就失效。

### Pin 的承诺

`Pin<P>` 是对智能指针 P 的 wrapper,承诺**被指向的值不会被 move**。

```rust
pub struct Pin<P> { pointer: P }
```

`Pin<&mut SelfRef>` 表示"这是个 &mut,但 SelfRef 被 pin 住,不会被 move"。Future 的 `poll(self: Pin<&mut Self>, ...)` 签名意思是"调用方保证 Self 不会被 move"。

### Unpin:大多数类型可以被 move

绝大多数类型不需要 self-referential,所以 move 它们是安全的。这些类型实现 `Unpin` marker trait(auto trait,自动推导)。

`Unpin` 类型即使被 Pin 也可以 move——`Pin<&mut T>` 对 `T: Unpin` 没意义。

什么类型不是 Unpin?**编译器生成的 async 状态机**(可能包含 self-reference)。手写代码里很少遇到 !Unpin。

### 工程上 Pin 怎么用?

99% 的 async 代码你不用直接想 Pin——`async`/`await` 处理掉了。只有当你手写 Future,或者用 Stream(下章),或者跟 unsafe 交互,才会显式遇到 Pin。

最常用的辅助函数:

- `Box::pin(future)`:把 Future 装进 Box 并 pin,得到 `Pin<Box<F>>`
- `std::pin::pin!(future)`:在栈上 pin

```rust
let fut = async { 42 };
let pinned = Box::pin(fut);  // Pin<Box<Future>>
```

详细的 Pin 用法和 unsafe 设计 Ch 18 / Ch 20 详谈。

---

## 12.5 写一个最简 executor

理论说清楚不如代码。下面是个能跑的 executor(简化但工作),20 行核心代码:

```rust
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, Wake, Waker};

struct DummyWaker;
impl Wake for DummyWaker {
    fn wake(self: Arc<Self>) {
        // 简化:这个 executor 不复用 waker
    }
}

fn block_on<F: Future>(mut fut: F) -> F::Output {
    let waker = Waker::from(Arc::new(DummyWaker));
    let mut cx = Context::from_waker(&waker);

    // SAFETY: fut 是栈变量,我们不 move 它
    let mut fut = unsafe { Pin::new_unchecked(&mut fut) };

    loop {
        match fut.as_mut().poll(&mut cx) {
            Poll::Ready(v) => return v,
            Poll::Pending => {
                // 真实 executor 这里会等 waker 通知
                // 简化版:busy loop
                std::thread::yield_now();
            }
        }
    }
}

async fn example() -> i32 {
    42
}

fn main() {
    let result = block_on(example());
    println!("{}", result);
}
```

这个 executor 极简(busy loop 是反模式,真实 executor 用 mio/epoll 等待 IO 事件),但它展示了核心机制:

1. 创建 Waker(给 future 一个回调通道)
2. 创建 Context(包装 waker)
3. Pin future(承诺 future 不会 move)
4. 循环 poll(直到 Ready)

真正的 Tokio runtime 复杂得多——多线程 scheduler、work stealing、IO event loop、timer wheel。但底层原理就这个。

---

## 12.6 实战:实现一个 Sleep Future

```rust
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::thread;
use std::time::{Duration, Instant};

struct Sleep {
    deadline: Instant,
    state: Arc<Mutex<SleepState>>,
}

struct SleepState {
    completed: bool,
    waker: Option<Waker>,
}

impl Sleep {
    fn new(dur: Duration) -> Self {
        let state = Arc::new(Mutex::new(SleepState {
            completed: false,
            waker: None,
        }));

        let deadline = Instant::now() + dur;
        let state_clone = Arc::clone(&state);

        // 启动一个线程在 deadline 时叫醒
        thread::spawn(move || {
            thread::sleep(dur);
            let mut s = state_clone.lock().unwrap();
            s.completed = true;
            if let Some(w) = s.waker.take() {
                w.wake();
            }
        });

        Sleep { deadline, state }
    }
}

impl Future for Sleep {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<()> {
        let mut state = self.state.lock().unwrap();
        if state.completed {
            Poll::Ready(())
        } else {
            // 存 waker,等线程到时间叫醒
            state.waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}
```

读法:

1. Sleep::new 创建,启动一个线程定时唤醒
2. poll 时检查 completed 标志
3. 没完成 → 存 waker,返回 Pending
4. 后台线程到时间,设 completed=true,call waker.wake()
5. Executor 收到 wake 信号,把 future 重新 poll
6. 这次检查 completed=true,返回 Ready

真实 Tokio 的 timer 用 timer wheel 实现,一个 OS 线程管理所有 sleep,效率高得多。但语义跟上面这段一致。

---

## 12.7 章末小结与习题

### 本章核心概念回顾

1. **Future 是 lazy 的**:async fn 返回 Future,不被 poll 不执行
2. **Rust async 是状态机**:编译器把 async fn 转成 enum,每个 await 是状态切换点
3. **Pull-based**:executor 调 poll,future 在没准备好时返回 Pending + 存 waker
4. **Pin**:承诺被指向的值不会被 move,允许 self-referential struct
5. **Unpin**:大部分类型自动 Unpin,async 生成的状态机可能 !Unpin
6. **Executor**:执行 Future 的循环,实际工作交给 Tokio 等库
7. **Waker**:future 用它通知 executor "我可以再次推进了"

### 习题

#### 习题 12.1(简单)

下面代码什么都不做,解释为什么:

```rust
async fn say_hello() {
    println!("hello");
}

fn main() {
    say_hello();
}
```

#### 习题 12.2(中等)

修复习题 12.1 的代码。你有两种选项:用 tokio 还是手写 block_on。

#### 习题 12.3(中等)

下面 async 函数返回什么类型?手写一个等价的非 async 函数返回相同的类型:

```rust
async fn compute() -> i32 {
    let a = step1().await;
    let b = step2(a).await;
    b * 2
}
```

#### 习题 12.4(困难)

把 12.6 节的 Sleep Future 扩展成"可取消":

- 多一个 cancel() method
- 取消后下次 poll 返回 Ready(()),即使 deadline 未到
- 取消后后台线程也应该终止

#### 习题 12.5(开放)

读 Tokio 源码的 `runtime/scheduler` 目录。试着定位:

- Worker 线程的主循环在哪
- Task 怎么从 queue 拿出来
- Waker 实现在哪

这种"读 runtime"的练习是 Rust 中高级工程师的必经之路。

---

### 下一章预告

Ch 13 我们离开理论,进入 Tokio 实战——`tokio::spawn`、`tokio::sync`、`select!`、cancellation。这是你 Stiglab 每天用的东西。

---

> **本章一句话总结**
>
> Rust async 不是"语法糖",是"零运行时的状态机模型"。Future / Pin / Waker 是这个模型的三个基石。读 Tokio 源码之前先理解它们。
