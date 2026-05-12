# Ch 13 · Tokio 生产实战

> 从能跑到能上生产

**核心问题**:Tokio 的 scheduler 和 driver 是怎么工作的?生产中的常见陷阱有哪些?

Tokio 是 Rust 异步生态的事实标准。axum、tower、reqwest、sqlx、tonic 全跑在它上面。这一章不教你"hello tokio"——那只是 `tokio::main` + `await`——而是教你**生产里会踩的坑**。

读完你应该能:

1. 画出 Tokio runtime 的组件图(scheduler / IO driver / timer / blocking pool)
2. 区分 `spawn` 和 `spawn_blocking`,知道把 CPU-bound 任务扔进 `spawn` 会怎样
3. 用 `select!` 写 cancellation,知道什么叫 cancel safety
4. 解释 async 上下文里 `std::thread::sleep` 是灾难
5. 用 tokio-console 调一个 hang 住的服务

---

## 13.1 Tokio runtime 架构

Tokio runtime 由三块组成:

```
┌────────────────────────────────────────┐
│       Tokio Runtime                    │
│ ┌────────────┐  ┌──────────────────┐   │
│ │ Scheduler  │  │ IO / Timer Driver│   │
│ │ (N workers)│  │  (mio/epoll/kq)  │   │
│ └────────────┘  └──────────────────┘   │
│        │             │                 │
│        ▼             ▼                 │
│ ┌──────────────────────────────────┐   │
│ │      Task Queue(work-stealing)  │   │
│ └──────────────────────────────────┘   │
│                                        │
│ ┌────────────────────────────────────┐ │
│ │   Blocking Thread Pool (max 512)   │ │
│ └────────────────────────────────────┘ │
└────────────────────────────────────────┘
```

- **Scheduler**:N 个 worker thread(默认 CPU 核数),work-stealing 调度
- **IO driver**:基于 mio(对 Linux epoll、macOS kqueue、Windows IOCP 的抽象),处理 socket / pipe 等异步事件
- **Timer driver**:hierarchical timer wheel,处理 `sleep` / `timeout`
- **Blocking pool**:专门给 `spawn_blocking` 用的线程池(默认上限 512)

### 单线程 vs 多线程 runtime

```rust,ignore
#[tokio::main]                                    // 多线程,N=CPU 核数
#[tokio::main(flavor = "current_thread")]         // 单线程
#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
```

- 单线程:吞吐低但**所有 await 之间状态不需要 Send**,适合本地工具 / CLI
- 多线程:吞吐高,async fn 状态必须 Send

---

## 13.2 `tokio::spawn` vs `spawn_blocking`

### 灾难性反例

```rust,ignore
#[tokio::main]
async fn main() {
    tokio::spawn(async {
        // CPU 密集任务,不 await 任何东西
        for _ in 0..1_000_000_000 { /* busy compute */ }
    });
    // 多线程 runtime:占住一个 worker
    // 单线程 runtime:整个 runtime 卡死
}
```

`tokio::spawn` 假设你写的是"短期跑、频繁 await"的任务。CPU 密集会**饿死**别的任务。

### 正确做法

```rust,ignore
let result = tokio::task::spawn_blocking(|| {
    // 这里跑在 blocking pool,不影响 worker
    expensive_computation()
}).await?;
```

经验法则:**任何 await 之间会跑超过 ~100 µs 的 CPU 工作都该用 `spawn_blocking`**(或同步等价的 rayon 并发)。

### 实战中的坑

调用看似纯 CPU 但其实有 IO 的 sync 库(比如某些 ORM、加密库)——一律 `spawn_blocking`。

---

## 13.3 `tokio::sync` 全家桶

| 类型 | 用途 | 容量 |
|---|---|---|
| `mpsc` | 多生产单消费 | 有界(背压) / 无界(危险) |
| `oneshot` | 一次性 reply | 1 |
| `broadcast` | 广播,所有订阅者收到 | 有界 |
| `watch` | 最新值,迟到者只看到最新 | 1(覆盖) |
| `Notify` | 信号量,无数据 | - |
| `Mutex` | async-aware 互斥锁 | - |
| `RwLock` | async-aware 读写锁 | - |
| `Semaphore` | 限流 / 并发上限 | N |

### 关键差异:tokio::sync::Mutex vs std::sync::Mutex

**短临界区永远用 `std::sync::Mutex`**:

```rust,ignore
// 推荐:短锁,std 即可
let v = state.lock().unwrap();
do_something_quick(&v);
drop(v);
```

```rust,ignore
// 必须用 tokio::sync::Mutex 的场景:锁要 await 时还在持有
let mut guard = state.lock().await;
guard.fetch_remote().await;   // ← 持锁 await
```

`std::sync::Mutex` 是**操作系统级互斥锁**,持有时 await 等于 OS 线程被 park,**worker 浪费**。`tokio::sync::Mutex` 的 guard 是 async-aware 的,跨 await 不阻塞 worker。

经验:**默认 `std`,跨 await 时换 `tokio`**。

### oneshot 用法

```rust,ignore
let (tx, rx) = tokio::sync::oneshot::channel();
tokio::spawn(async move {
    let result = compute().await;
    let _ = tx.send(result);
});
match rx.await {
    Ok(v) => println!("{}", v),
    Err(_) => println!("sender dropped"),
}
```

---

## 13.4 `select!` 宏与 cancellation

```rust,ignore
use tokio::time::{sleep, Duration};

tokio::select! {
    res = fetch_data() => println!("got {:?}", res),
    _ = sleep(Duration::from_secs(3)) => println!("timeout"),
}
```

- `select!` 同时 poll 多个 Future,**第一个 ready 的胜出**
- 其他 Future 被 **drop**(取消)

### Cancel safety

```rust,ignore
let mut chunks = Vec::new();
loop {
    tokio::select! {
        c = stream.next() => chunks.push(c?),
        _ = signal::ctrl_c() => break,
    }
}
```

`stream.next()` 在没拿到东西时被取消会怎样?如果 stream 实现里"已经从 buffer 拿了字节但还没返回",这个数据**丢失**——这就是 **cancel-unsafe**。

社区做法:在文档里标注每个 async API 是否 cancel-safe。**调用前看文档**。

| API | cancel safe |
|---|---|
| `mpsc::Receiver::recv` | ✅ |
| `TcpStream::read` | ❌(可能丢数据) |
| `Mutex::lock` | ✅ |
| `oneshot::Receiver::await` | ✅ |
| `time::sleep` | ✅ |

不确定时,**用 `select!` 包裹"原子查询" + biased 模式 + 显式 buffer**。

---

## 13.5 Drop 在 async 里的陷阱

```rust,ignore
struct DbConn { /* ... */ }

impl Drop for DbConn {
    fn drop(&mut self) {
        // 想在这里发起 async cleanup —— 做不到!Drop 是 sync 函数
        // self.send_close_message().await;   // ❌
    }
}
```

**Drop 是 sync 函数,不能 await**。这意味着:

- 异步连接关闭、异步资源释放,**只能用显式 `close()` 方法**
- 或者:在 Drop 里 `tokio::spawn` 一个 task(代价:可能在 runtime shutdown 时 spawn 失败)

业内事实标准:**显式 cleanup API + tracing 警告 "did you forget to close?"**。

---

## 13.6 `tokio::time::sleep` vs `std::thread::sleep`

```rust,ignore
async fn bad() {
    std::thread::sleep(Duration::from_secs(1));   // ❌ 灾难
}
```

`std::thread::sleep` 阻塞**当前 OS 线程**——也就是阻塞一个 worker。10 个并发任务 + 8 worker 多线程 runtime → 整个 runtime 几乎卡死 1 秒。

```rust,ignore
async fn good() {
    tokio::time::sleep(Duration::from_secs(1)).await;   // ✅
}
```

**所有 std 阻塞 API 在 async 上下文都是禁区**:`std::thread::sleep` / `std::sync::Mutex::lock`(长时间)/ `std::net::TcpStream::read` / `std::fs::read`(大文件)/ `std::io::stdin().read_line` 等等。

经验:**async 函数里只用 `tokio::*` 或 `async_*` 系列 API**。要用同步库,套 `spawn_blocking`。

---

## 13.7 Structured concurrency

`tokio::spawn` 起来的任务在你不 `await` JoinHandle 时**孤儿运行**——你失去对它们的把控。

### JoinSet:批量管理

```rust,ignore
let mut set = tokio::task::JoinSet::new();
for url in urls {
    set.spawn(fetch(url));
}
while let Some(res) = set.join_next().await {
    println!("{:?}", res);
}
// set drop 时未完成的任务自动被 abort
```

### TaskTracker:跨模块管控

`tokio_util::task::TaskTracker` 提供"spawn 时登记,shutdown 时等齐"的模式。优雅关闭(graceful shutdown)的标准做法。

### 经验

**避免 `tokio::spawn` 出去之后不管**——除非你真的不在乎它什么时候完成。常态是用 `JoinHandle::await` 或 `JoinSet` 收尾。

---

## 13.8 性能调优

### worker thread 数量

- 默认 = CPU 核数
- IO 密集且阻塞操作多:可适当增加(`worker_threads(N*2)`)
- CPU 密集为主:别多开,会增加 context switch

### task 粒度

- 太细:调度开销 > 工作量(每个 task 也得做状态机切换)
- 太粗:个别 task 卡住,其他无法插入
- 经验:**每个 task 大约对应一个"独立可取消的工作单元"**(一个连接 / 一个请求 / 一个 job)

### 主动让出

长循环里 await 一下,给 scheduler 机会:

```rust,ignore
for chunk in big_data.chunks(1024) {
    process(chunk);
    tokio::task::yield_now().await;
}
```

### CPU pinning / NUMA

生产高吞吐场景考虑 `tokio::runtime::Builder` 的 `on_thread_start` 做 CPU affinity。多 socket NUMA 机器尤其重要。

---

## 13.9 tokio-console 实战调试

```toml
[dependencies]
tokio = { version = "1", features = ["full", "tracing"] }
console-subscriber = "0.4"
```

```rust,ignore
#[tokio::main]
async fn main() {
    console_subscriber::init();
    // ...
}
```

然后跑:

```bash
RUSTFLAGS="--cfg tokio_unstable" cargo run
# 另起终端
tokio-console
```

看到的内容:

- 每个 task 的状态(running / idle / waiting on...)
- 持续 idle 太久的 task(可能僵死)
- 长期 busy 的 task(可能 CPU 密集没 yield)
- 锁 / channel 的等待时间分布

调"服务突然 hang 住" / "某个请求慢" 时一秒钟定位。生产先验把它接入。

---

## 习题

1. 写一个 HTTP 服务,在 handler 里 `std::thread::sleep(2s)`,wrk 压测。再换成 `tokio::time::sleep`,对比 QPS。
2. 用 `select!` + `signal::ctrl_c()` 实现优雅关闭:收到 Ctrl-C 后停止接收新连接,等已有连接处理完。
3. 给一个 cancel-unsafe 的 demo:用 `select!` 包 `TcpStream::read`,观察被取消时数据丢失。改成 cancel-safe 版本。
4. 跑通 tokio-console,人为制造一个"忘了 yield"的 CPU 密集 task,看 console 里它的状态。
5. 用 `Semaphore` 给一个并发 HTTP 客户端加 "最多同时 100 个 in-flight" 的限流。

---

> **本章一句话总结**
>
> Tokio 是 Rust 生产 async 的事实标准。掌握它的内部不是炫技,是上生产之前的必修课——大部分 async 事故都来自"不知道 Tokio 内部怎么工作"。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
