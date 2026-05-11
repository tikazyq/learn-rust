# 第 13 章 · Tokio 生产实战

> "Tokio is the runtime. Everything else is built on top."

Ch 12 我们看了 async/await 底层。Ch 13 我们看你每天会用的 Tokio。

读完这章你应该能:

1. 配置 Tokio runtime,知道 worker 数量、blocking pool 等参数的意义
2. 用 tokio::sync 系列原语写正确的并发代码
3. 用 select! 和 cancellation tokens 实现可取消的工作流
4. 知道 async 代码常见的几个性能陷阱
5. 给 Stiglab Control Plane 加 graceful shutdown 和 health check

---

## 13.1 Tokio Runtime 架构

```
┌───────────────────────────────────────────────┐
│ Tokio Runtime                                 │
│  ┌──────────────┐  ┌──────────────┐          │
│  │ Worker #1    │  │ Worker #2    │  ...     │
│  │ task queue   │  │ task queue   │          │
│  └──────┬───────┘  └──────┬───────┘          │
│         │ work stealing   │                  │
│  ┌──────▼──────────────────▼──────┐         │
│  │ I/O driver (epoll/kqueue/iocp) │         │
│  └────────────────────────────────┘         │
│  ┌──────────────────────────────────┐       │
│  │ Time driver (timer wheel)        │       │
│  └──────────────────────────────────┘       │
│  ┌──────────────────────────────────┐       │
│  │ Blocking pool (for spawn_blocking)│      │
│  └──────────────────────────────────┘       │
└───────────────────────────────────────────────┘
```

- **Worker 线程**:执行 async task 的主力,数量默认等于 CPU 核数。每个 worker 有自己的 task queue。
- **Work stealing**:空闲 worker 从忙 worker 的 queue 偷活。
- **I/O driver**:用操作系统的异步 IO API(Linux epoll、macOS kqueue、Windows IOCP)等 IO 事件。
- **Time driver**:管理所有 timer(sleep / interval)。
- **Blocking pool**:专门跑阻塞代码(`spawn_blocking`),跟 worker 隔离。

### 启动 runtime

最常见:用 `#[tokio::main]` 属性宏:

```rust
#[tokio::main]
async fn main() {
    // 整个 main 函数体在 Tokio runtime 里跑
}
```

底层等同于:

```rust
fn main() {
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        // ...
    });
}
```

### 自定义 runtime

```rust
let runtime = tokio::runtime::Builder::new_multi_thread()
    .worker_threads(8)
    .max_blocking_threads(512)
    .enable_all()
    .thread_name("my-worker")
    .build()
    .unwrap();
```

工程经验:

- `worker_threads` 默认 CPU 核数,IO bound 可适当增加,CPU bound 别超过核数
- `max_blocking_threads` 默认 512,如果你大量用 spawn_blocking 可调高
- 同一进程里可以有多个 runtime(罕见但合法)

### `current_thread` runtime

```rust
let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();
```

单线程 runtime——所有 task 在当前线程跑。适合测试、CLI 工具、不需要并行的场景。

---

## 13.2 spawn 与 spawn_blocking

### `tokio::spawn`

```rust
let handle = tokio::spawn(async {
    println!("in task");
    42
});

let result = handle.await.unwrap();  // 等待 task 完成
```

`spawn` 把 future 提交给 worker 线程池,立即返回 `JoinHandle<T>`。

**关键约束**:future 必须 `Send + 'static`。意味着 future 内部不能借用外部 stack 数据。

```rust
async fn main() {
    let data = vec![1, 2, 3];
    let r = &data;
    tokio::spawn(async move {
        println!("{:?}", r);    // ❌ r 是借用,不是 'static
    });
}

// 修复:move 接管所有权
async fn main() {
    let data = vec![1, 2, 3];
    tokio::spawn(async move {
        println!("{:?}", data);  // ✅ data 被 move 进 task
    });
}
```

### `tokio::spawn_blocking`

如果你要跑同步的、可能阻塞的代码(文件 IO、CPU 密集计算、调用 sync 库):

```rust
let result = tokio::task::spawn_blocking(|| {
    // 这里跑同步代码,不阻塞 worker
    expensive_compute()
}).await.unwrap();
```

`spawn_blocking` 把闭包派给 blocking pool 跑,worker 不受影响。

### 关键陷阱:别在 async 里直接 block

```rust
async fn bad() {
    std::thread::sleep(Duration::from_secs(1));  // ❌ 阻塞整个 worker
    std::fs::read_to_string("file").unwrap();    // ❌ 同上
}

async fn good() {
    tokio::time::sleep(Duration::from_secs(1)).await;       // ✅ async sleep
    tokio::fs::read_to_string("file").await.unwrap();       // ✅ async file
}

async fn ok() {
    let content = tokio::task::spawn_blocking(|| {
        std::fs::read_to_string("file").unwrap()
    }).await.unwrap();                                       // ✅ 同步代码隔离
}
```

如果你在 worker 上 block,那个 worker 就不能跑其他 task,严重时整个 runtime 卡住。

---

## 13.3 tokio::sync 全家桶

Tokio 提供 async 版本的同步原语,跟 std::sync 平行但不阻塞 worker。

### `tokio::sync::Mutex`

```rust
use tokio::sync::Mutex;
use std::sync::Arc;

let counter = Arc::new(Mutex::new(0));

let c = Arc::clone(&counter);
tokio::spawn(async move {
    let mut n = c.lock().await;        // 注意是 .await,不是 .unwrap()
    *n += 1;
});
```

tokio Mutex 跟 std Mutex 的关键差异:**lock().await 在拿不到锁时不阻塞 worker,把 task 让出让别的 task 跑**。

Ch 9 的提醒重申:**锁不跨 await,用 std::sync::Mutex 更快**。tokio Mutex 只在"持锁期间需要 await 别的东西"时才有意义。

### `tokio::sync::RwLock`

跟 Mutex 同理,但读多写少场景:

```rust
let lock = Arc::new(tokio::sync::RwLock::new(HashMap::new()));

let r = Arc::clone(&lock);
tokio::spawn(async move {
    let map = r.read().await;
    println!("{:?}", map.get(&1));
});
```

### `tokio::sync::mpsc`(channel)

```rust
let (tx, mut rx) = tokio::sync::mpsc::channel::<i32>(32);  // 32 是 buffer 大小

let tx_clone = tx.clone();
tokio::spawn(async move {
    tx_clone.send(42).await.unwrap();
});

while let Some(value) = rx.recv().await {
    println!("got {}", value);
}
```

特性:
- buffer 满时 send 异步等待
- 所有 sender drop 后 recv 返回 None
- `tx.send().await` 跟 `rx.recv().await` 都是 async

### `tokio::sync::oneshot`

单次发送的 channel,适合"request-response"模式:

```rust
let (tx, rx) = tokio::sync::oneshot::channel::<i32>();

tokio::spawn(async move {
    let result = compute().await;
    tx.send(result).unwrap();    // 只能 send 一次
});

let result = rx.await.unwrap();
```

常见用法:发起一个异步任务,等它完成。

### `tokio::sync::broadcast`

一发多收(广播):

```rust
let (tx, mut rx1) = tokio::sync::broadcast::channel::<String>(16);
let mut rx2 = tx.subscribe();

tokio::spawn(async move {
    tx.send("hello".into()).unwrap();
});

// rx1 和 rx2 都能收到 "hello"
```

适合"事件总线"场景。注意:如果某个 receiver 跟不上,会丢消息(返回 `RecvError::Lagged`)。

### `tokio::sync::watch`

最新值订阅——多个 receiver 看同一个值,每次值变了 receiver 被唤醒:

```rust
let (tx, mut rx) = tokio::sync::watch::channel("initial");

tokio::spawn(async move {
    while rx.changed().await.is_ok() {
        let value = rx.borrow().clone();
        println!("value changed: {}", value);
    }
});

tx.send("updated").unwrap();
```

适合配置热更新——主线程更新配置,各 task 监听变化。

### `tokio::sync::Notify`

最轻量的"通知机制":

```rust
let notify = Arc::new(tokio::sync::Notify::new());

let n = Arc::clone(&notify);
tokio::spawn(async move {
    n.notified().await;
    println!("got notified");
});

notify.notify_one();
```

适合"我没有消息要传,只想说一声"。比 channel 轻很多。

### `tokio::sync::Semaphore`

限流/限制并发数:

```rust
let sem = Arc::new(tokio::sync::Semaphore::new(10));

for _ in 0..100 {
    let permit = sem.clone().acquire_owned().await.unwrap();
    tokio::spawn(async move {
        do_work().await;
        drop(permit);  // 释放 permit
    });
}
```

最多 10 个 task 同时跑,后续等待。

---

## 13.4 select! 与 cancellation

异步代码的真正威力之一:**同时等多件事,谁先到就处理谁**。

### select!

```rust
use tokio::time::{sleep, Duration};

tokio::select! {
    _ = sleep(Duration::from_secs(1)) => {
        println!("timeout");
    }
    msg = rx.recv() => {
        println!("got message: {:?}", msg);
    }
}
```

哪个分支先 ready,执行哪个,其他分支被取消。

### Cancellation 的工程语义

Rust async 的 cancellation 是 **drop-based**——drop 一个 Future 就等于取消它。executor 不再 poll,任何 pending 状态被清理。

```rust
let task = tokio::spawn(async {
    long_running_op().await;
});

task.abort();   // 发送取消信号
// 或者直接 drop handle:drop(task)
```

但 cancellation 有个微妙问题:**如果 future 内部持有资源,被 cancel 时怎么清理**?

```rust
async fn process() {
    let conn = pool.get_connection().await?;
    conn.begin_transaction().await?;
    conn.execute("UPDATE ...").await?;
    // ← 假设这里被 cancel,事务没 commit 也没 rollback
    conn.commit().await?;
}
```

如果 process 在 execute 之后、commit 之前被 cancel,连接被 drop,事务会因为连接断开自动 rollback——但这依赖底层库行为。

**最佳实践**:把"必须完整执行"的代码段用 `tokio::spawn` 隔离 + 不 abort,或用 `CancellationToken` 显式控制。

### CancellationToken(tokio-util)

```rust
use tokio_util::sync::CancellationToken;

let token = CancellationToken::new();
let child_token = token.child_token();

tokio::spawn(async move {
    tokio::select! {
        _ = child_token.cancelled() => {
            println!("cancelled gracefully");
        }
        _ = do_work() => {
            println!("done");
        }
    }
});

// 一秒后取消
tokio::time::sleep(Duration::from_secs(1)).await;
token.cancel();
```

CancellationToken 提供更优雅的取消:子任务能检测到取消信号,做清理。

---

## 13.5 Structured Concurrency:JoinSet

直接 spawn 一堆任务,然后挨个 await join handle,代码会很啰嗦。`JoinSet` 是 Tokio 的 structured concurrency 工具:

```rust
use tokio::task::JoinSet;

let mut set = JoinSet::new();

for i in 0..10 {
    set.spawn(async move {
        process(i).await
    });
}

while let Some(result) = set.join_next().await {
    match result {
        Ok(v) => println!("got: {:?}", v),
        Err(e) => println!("task panicked: {:?}", e),
    }
}
```

特性:
- spawn 后 set 持有所有 task
- join_next 取出"任意一个完成的"
- set drop 时所有未完成 task 被 abort

这是"扇出-扇入"模式的标准工具。

---

## 13.6 几个性能陷阱

### 陷阱 1:小 task 太多

```rust
for x in 0..1_000_000 {
    tokio::spawn(async move { x * 2 });
}
```

每个 task 都有 schedule 开销。100 万个小 task 比 100 个大 task 慢得多。**用 buffer_unordered 或 stream**。

### 陷阱 2:同步阻塞

```rust
async fn handler() {
    let data = std::fs::read_to_string("file").unwrap();  // ❌ 阻塞
}
```

如前述,任何同步阻塞都是反模式。用 tokio::fs 或 spawn_blocking。

### 陷阱 3:Mutex 持锁跨 await

```rust
async fn bad(lock: Arc<tokio::sync::Mutex<State>>) {
    let mut state = lock.lock().await;
    state.do_async_work().await;          // 持锁跨 await,其他 task 等
}
```

尽量 lock-do-unlock 不跨 await。如果业务上必须,设计上考虑分锁或 actor 模式。

### 陷阱 4:`Vec<Future>` 顺序 await

```rust
let mut results = vec![];
for fut in futures {
    results.push(fut.await);  // 顺序 await,不并发
}

// 应该用 join_all 或 JoinSet
let results = futures::future::join_all(futures).await;
```

### 陷阱 5:Stream 的 `next` 而不 `next_some`

读 stream 用 while-let,而不是 try block:

```rust
use futures::StreamExt;

while let Some(item) = stream.next().await {
    process(item).await;
}
```

---

## 13.7 实战:给 Stiglab Control Plane 加 graceful shutdown + health check

完整可运行示例。

```rust
use std::sync::Arc;
use tokio::signal;
use tokio_util::sync::CancellationToken;
use tokio::time::{interval, Duration};

#[tokio::main]
async fn main() {
    let shutdown = CancellationToken::new();

    // health check task
    let hc_token = shutdown.child_token();
    let hc_handle = tokio::spawn(async move {
        let mut tick = interval(Duration::from_secs(10));
        loop {
            tokio::select! {
                _ = hc_token.cancelled() => {
                    tracing::info!("health check shutting down");
                    break;
                }
                _ = tick.tick() => {
                    perform_health_check().await;
                }
            }
        }
    });

    // 主服务 task
    let srv_token = shutdown.child_token();
    let srv_handle = tokio::spawn(async move {
        run_http_server(srv_token).await;
    });

    // 等待 ctrl+c 或 SIGTERM
    tokio::select! {
        _ = signal::ctrl_c() => {
            tracing::info!("received ctrl+c");
        }
    }

    tracing::info!("shutting down gracefully");
    shutdown.cancel();

    // 等所有 task 结束(可加超时)
    let _ = tokio::time::timeout(Duration::from_secs(30), async {
        let _ = hc_handle.await;
        let _ = srv_handle.await;
    }).await;

    tracing::info!("bye");
}

async fn perform_health_check() {
    // check db, downstream services, etc.
}

async fn run_http_server(token: CancellationToken) {
    // axum or similar; should pass token to graceful shutdown
}
```

工程要点:
1. 一个根 CancellationToken,所有 task 都用它的 child
2. 主循环等 signal 触发关闭
3. 关闭时 cancel + 限时等子任务结束
4. 子任务定期检查 token

这是 Stiglab Control Plane 应该有的骨架。每个 worker / health check / API server 都遵循这个模式,关闭流程才干净。

---

## 13.8 章末小结与习题

### 本章核心概念回顾

1. **Tokio runtime 架构**:worker + work stealing + IO driver + blocking pool
2. **`tokio::spawn` 要求 Send + 'static**:跟 `std::thread::spawn` 相似
3. **`spawn_blocking`**:同步代码隔离到 blocking pool
4. **不要在 worker 上 block**:用 tokio::fs / tokio::time / spawn_blocking
5. **`tokio::sync` 全家桶**:Mutex / RwLock / mpsc / oneshot / broadcast / watch / Notify / Semaphore
6. **select! + CancellationToken**:可取消的工作流
7. **JoinSet**:structured concurrency 工具
8. **性能陷阱**:小 task 过多、阻塞、持锁跨 await、顺序 await

### 习题

#### 习题 13.1(简单)

下面代码哪里有问题?

```rust
#[tokio::main]
async fn main() {
    let data = std::fs::read_to_string("config.toml").unwrap();
    println!("{}", data);
}
```

#### 习题 13.2(中等)

实现一个 worker pool,接受任务 channel,启动 N 个 worker,每个 worker 从 channel 取任务执行。要支持 graceful shutdown。

#### 习题 13.3(中等)

下面代码用 select! 实现 timeout,改写成更优雅的 `tokio::time::timeout`:

```rust
let result = tokio::select! {
    res = some_future => Some(res),
    _ = tokio::time::sleep(Duration::from_secs(5)) => None,
};
```

#### 习题 13.4(困难)

给一个 axum HTTP 服务加 graceful shutdown:Ctrl+C 后:
1. 立即停止接受新连接
2. 等已有请求处理完(最多 30 秒)
3. 优雅退出

#### 习题 13.5(开放)

回到 Stiglab。看 Control Plane 的代码,找出:
- 哪些地方 spawn 了 task 但没有 cancellation
- 哪些地方持锁跨 await
- 哪些地方有 unbounded channel(可能 OOM 风险)
- 哪些地方应该用 spawn_blocking 但没有

写一个改造计划。

---

### 下一章预告

Ch 14 进入工程实践:Cargo、workspace、依赖管理、feature flag。
你已经在 Onsager 用 workspace,这章把背后的工具链系统讲清楚。

---

> **本章一句话总结**
>
> Tokio 不只是 async runtime,是整个 Rust 生态的并发基础设施。掌握 spawn / sync 原语 / select / cancellation 这四块,你已经能写生产级 async 代码了。
