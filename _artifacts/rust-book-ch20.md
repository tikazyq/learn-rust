# 第 20 章 · Capstone —— 从零实现 Mini-Tokio

> "I cannot create, therefore I do not understand."
> — Richard Feynman

毕业作品。我们从零写一个能跑的 async runtime——executor、spawner、timer、channel——大致就是 Tokio 的简化版。代码 500 行左右,涵盖这本书的几乎所有概念。

读完这章你应该能:

1. 写出能跑 async/await 代码的最小 runtime
2. 理解 Tokio 内部的 scheduler、reactor、timer 各模块如何拼起来
3. 用 unsafe + Pin + Waker 构造 self-referential 状态机
4. 评估生产 runtime 比你实现的多了哪些细节

整个项目分四步:
1. 单线程 executor + 基本 task
2. 加上 Sleep future + timer 线程
3. 加上 channel
4. 多 worker + work stealing

每一步代码都能跑,逐步增加复杂度。

---

## 20.1 项目结构

```
mini-tokio/
├── Cargo.toml
└── src/
    ├── lib.rs
    ├── executor.rs       # 单线程 executor
    ├── task.rs           # Task 类型与 Waker
    ├── sleep.rs          # Sleep future + timer
    ├── channel.rs        # mpsc channel
    └── multi.rs          # 多 worker scheduler
```

`Cargo.toml`:

```toml
[package]
name = "mini-tokio"
version = "0.1.0"
edition = "2021"

[dependencies]
crossbeam-channel = "0.5"
```

---

## 20.2 Step 1:单线程 Executor

最简单的 executor:一个 queue 装"待 poll 的 task",循环 pop 出来 poll。

```rust
// src/task.rs
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Wake, Waker};
use crossbeam_channel::Sender;

pub struct Task {
    pub future: Mutex<Option<Pin<Box<dyn Future<Output = ()> + Send>>>>,
    pub executor: Sender<Arc<Task>>,
}

impl Wake for Task {
    fn wake(self: Arc<Self>) {
        // 被唤醒时,把自己 push 回 executor queue
        let _ = self.executor.send(self.clone());
    }

    fn wake_by_ref(self: &Arc<Self>) {
        let _ = self.executor.send(self.clone());
    }
}

impl Task {
    pub fn poll(self: &Arc<Self>) {
        let waker = Waker::from(self.clone());
        let mut cx = Context::from_waker(&waker);

        let mut fut_slot = self.future.lock().unwrap();
        if let Some(mut fut) = fut_slot.take() {
            if fut.as_mut().poll(&mut cx).is_pending() {
                // 没完成,放回去等下次 wake
                *fut_slot = Some(fut);
            }
            // Ready 时 future 直接 drop
        }
    }
}
```

```rust
// src/executor.rs
use crate::task::Task;
use std::future::Future;
use std::sync::Mutex;
use std::pin::Pin;
use std::sync::Arc;
use crossbeam_channel::{Receiver, Sender, unbounded};

pub struct Executor {
    ready_queue: Receiver<Arc<Task>>,
    spawner: Sender<Arc<Task>>,
}

impl Executor {
    pub fn new() -> Self {
        let (tx, rx) = unbounded();
        Executor { ready_queue: rx, spawner: tx }
    }

    pub fn spawn<F: Future<Output = ()> + Send + 'static>(&self, fut: F) {
        let task = Arc::new(Task {
            future: Mutex::new(Some(Box::pin(fut))),
            executor: self.spawner.clone(),
        });
        let _ = self.spawner.send(task);
    }

    pub fn run(&self) {
        while let Ok(task) = self.ready_queue.recv() {
            task.poll();
        }
        // 所有 sender drop 后 recv 返回 Err,循环退出
    }
}
```

```rust
// src/lib.rs
pub mod task;
pub mod executor;
pub mod sleep;
pub mod channel;

pub use executor::Executor;
```

### 用它

```rust
use mini_tokio::Executor;

fn main() {
    let exec = Executor::new();

    exec.spawn(async {
        println!("hello from task 1");
    });

    exec.spawn(async {
        println!("hello from task 2");
    });

    drop(exec.spawner);     // 实际代码里通过 drop spawner 让 run 退出
    exec.run();
}
```

这个 60 行的 executor 已经能跑 async/await。但还没有 sleep,任何需要等待的 future 它驱动不了——因为只有 ready 时 task 才会被 push 进 queue。

---

## 20.3 Step 2:Sleep + Timer

加 `Sleep` future,需要一个 timer 线程:

```rust
// src/sleep.rs
use std::collections::BinaryHeap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, Condvar};
use std::task::{Context, Poll, Waker};
use std::thread;
use std::time::{Duration, Instant};

struct TimerEntry {
    deadline: Instant,
    waker: Waker,
}

impl PartialEq for TimerEntry { fn eq(&self, o: &Self) -> bool { self.deadline == o.deadline } }
impl Eq for TimerEntry {}
impl PartialOrd for TimerEntry {
    fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> { Some(self.cmp(o)) }
}
impl Ord for TimerEntry {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        o.deadline.cmp(&self.deadline)  // 反转,做小顶堆
    }
}

pub struct Timer {
    state: Arc<Mutex<BinaryHeap<TimerEntry>>>,
    cond: Arc<Condvar>,
}

impl Timer {
    pub fn new() -> Self {
        let state = Arc::new(Mutex::new(BinaryHeap::new()));
        let cond = Arc::new(Condvar::new());

        let state_clone = Arc::clone(&state);
        let cond_clone = Arc::clone(&cond);
        thread::spawn(move || {
            loop {
                let mut heap = state_clone.lock().unwrap();
                let now = Instant::now();
                // 触发所有 deadline 到了的 timer
                while let Some(top) = heap.peek() {
                    if top.deadline <= now {
                        let entry = heap.pop().unwrap();
                        entry.waker.wake();
                    } else {
                        break;
                    }
                }
                // 计算下次等多久
                let wait = match heap.peek() {
                    Some(top) => top.deadline.saturating_duration_since(Instant::now()),
                    None => Duration::from_secs(60),  // 没 timer 就睡 60 秒
                };
                let _ = cond_clone.wait_timeout(heap, wait).unwrap();
            }
        });

        Timer { state, cond }
    }

    pub fn register(&self, deadline: Instant, waker: Waker) {
        let mut heap = self.state.lock().unwrap();
        heap.push(TimerEntry { deadline, waker });
        self.cond.notify_one();  // 唤醒 timer 线程重新计算
    }
}

// 全局 timer
use std::sync::OnceLock;
static GLOBAL_TIMER: OnceLock<Timer> = OnceLock::new();

fn timer() -> &'static Timer {
    GLOBAL_TIMER.get_or_init(Timer::new)
}

pub struct Sleep {
    deadline: Instant,
    registered: bool,
}

impl Sleep {
    pub fn new(dur: Duration) -> Self {
        Sleep {
            deadline: Instant::now() + dur,
            registered: false,
        }
    }
}

impl Future for Sleep {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if Instant::now() >= self.deadline {
            return Poll::Ready(());
        }
        if !self.registered {
            timer().register(self.deadline, cx.waker().clone());
            self.registered = true;
        }
        Poll::Pending
    }
}

pub fn sleep(dur: Duration) -> Sleep {
    Sleep::new(dur)
}
```

### 用它

```rust
exec.spawn(async {
    println!("task starting");
    mini_tokio::sleep::sleep(Duration::from_secs(1)).await;
    println!("task done after 1s");
});

exec.run();
```

现在有 sleep 了。timer 线程维护一个 BinaryHeap(小顶堆),按 deadline 排序。最近的 timer 到期就 wake 对应 waker。

### 真实 Tokio 怎么做

真实 Tokio 用 "timer wheel"——分级 bucket 数组,操作 O(1)。BinaryHeap 是 O(log n),足够本章用。

---

## 20.4 Step 3:Channel

mpsc channel:

```rust
// src/channel.rs
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

struct Inner<T> {
    queue: VecDeque<T>,
    waiting_receiver: Option<Waker>,
    senders: usize,
}

pub struct Sender<T> {
    inner: Arc<Mutex<Inner<T>>>,
}

pub struct Receiver<T> {
    inner: Arc<Mutex<Inner<T>>>,
}

pub fn channel<T>() -> (Sender<T>, Receiver<T>) {
    let inner = Arc::new(Mutex::new(Inner {
        queue: VecDeque::new(),
        waiting_receiver: None,
        senders: 1,
    }));
    (
        Sender { inner: Arc::clone(&inner) },
        Receiver { inner },
    )
}

impl<T> Sender<T> {
    pub fn send(&self, value: T) -> Result<(), T> {
        let mut inner = self.inner.lock().unwrap();
        inner.queue.push_back(value);
        if let Some(w) = inner.waiting_receiver.take() {
            w.wake();
        }
        Ok(())
    }
}

impl<T> Clone for Sender<T> {
    fn clone(&self) -> Self {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.senders += 1;
        }
        Sender { inner: Arc::clone(&self.inner) }
    }
}

impl<T> Drop for Sender<T> {
    fn drop(&mut self) {
        let mut inner = self.inner.lock().unwrap();
        inner.senders -= 1;
        if inner.senders == 0 {
            // 最后一个 sender drop,唤醒等待的 receiver
            if let Some(w) = inner.waiting_receiver.take() {
                w.wake();
            }
        }
    }
}

pub struct Recv<'a, T> {
    receiver: &'a Receiver<T>,
}

impl<'a, T> Future for Recv<'a, T> {
    type Output = Option<T>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<T>> {
        let mut inner = self.receiver.inner.lock().unwrap();
        if let Some(value) = inner.queue.pop_front() {
            return Poll::Ready(Some(value));
        }
        if inner.senders == 0 {
            return Poll::Ready(None);     // 没 sender 了,channel 关
        }
        inner.waiting_receiver = Some(cx.waker().clone());
        Poll::Pending
    }
}

impl<T> Receiver<T> {
    pub fn recv(&self) -> Recv<'_, T> {
        Recv { receiver: self }
    }
}
```

### 用它

```rust
use mini_tokio::channel;

let (tx, rx) = channel::channel::<i32>();

exec.spawn(async move {
    for i in 0..5 {
        tx.send(i).unwrap();
    }
    drop(tx);  // 关 channel
});

exec.spawn(async move {
    while let Some(v) = rx.recv().await {
        println!("got {}", v);
    }
    println!("channel closed");
});

exec.run();
```

---

## 20.5 Step 4:多 worker + work stealing

单线程 executor 只用一核。生产 runtime 多线程。

```rust
// src/multi.rs
use crate::task::Task;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::pin::Pin;
use std::thread;
use crossbeam_channel::{Receiver, Sender, unbounded};

pub struct MultiExecutor {
    spawners: Vec<Sender<Arc<Task>>>,
    next_worker: Arc<Mutex<usize>>,
    handles: Vec<thread::JoinHandle<()>>,
}

impl MultiExecutor {
    pub fn new(n_workers: usize) -> Self {
        let mut spawners = vec![];
        let mut handles = vec![];
        let mut all_receivers = vec![];

        // 先创建所有 channel
        let mut workers = vec![];
        for _ in 0..n_workers {
            let (tx, rx) = unbounded();
            spawners.push(tx);
            workers.push(rx);
        }

        // 每个 worker 拿自己的 rx,还能看到其他 worker 的 rx(work stealing)
        for (i, my_rx) in workers.iter().enumerate() {
            let my_rx = my_rx.clone();
            let other_rxs: Vec<_> = workers.iter()
                .enumerate()
                .filter(|(j, _)| *j != i)
                .map(|(_, rx)| rx.clone())
                .collect();
            let handle = thread::spawn(move || {
                worker_loop(my_rx, other_rxs);
            });
            handles.push(handle);
        }

        MultiExecutor {
            spawners,
            next_worker: Arc::new(Mutex::new(0)),
            handles,
        }
    }

    pub fn spawn<F: Future<Output = ()> + Send + 'static>(&self, fut: F) {
        // 简单 round-robin
        let mut idx = self.next_worker.lock().unwrap();
        let worker = *idx;
        *idx = (*idx + 1) % self.spawners.len();

        let task = Arc::new(Task {
            future: Mutex::new(Some(Box::pin(fut))),
            executor: self.spawners[worker].clone(),
        });
        let _ = self.spawners[worker].send(task);
    }

    pub fn shutdown(self) {
        drop(self.spawners);  // 关掉所有 channel,worker 退出
        for h in self.handles {
            let _ = h.join();
        }
    }
}

fn worker_loop(my_rx: Receiver<Arc<Task>>, other_rxs: Vec<Receiver<Arc<Task>>>) {
    loop {
        // 优先从自己 queue 拿
        if let Ok(task) = my_rx.try_recv() {
            task.poll();
            continue;
        }
        // 自己空了,尝试从别人那偷
        let mut stolen = false;
        for rx in &other_rxs {
            if let Ok(task) = rx.try_recv() {
                task.poll();
                stolen = true;
                break;
            }
        }
        if stolen { continue; }
        // 大家都没活,阻塞等自己 queue
        match my_rx.recv() {
            Ok(task) => task.poll(),
            Err(_) => return,  // channel 关了,退出
        }
    }
}
```

这个 work stealing 比较粗——真实 Tokio 用 lock-free deque(crossbeam-deque),steal 操作 lock-free。但语义一致。

### 用它

```rust
let exec = MultiExecutor::new(4);
for i in 0..10 {
    exec.spawn(async move {
        println!("task {} on thread {:?}", i, std::thread::current().id());
        mini_tokio::sleep::sleep(Duration::from_millis(100)).await;
    });
}
std::thread::sleep(Duration::from_secs(2));
exec.shutdown();
```

---

## 20.6 评估:跟生产 Tokio 差什么

我们实现的 mini-tokio 大约 500 行,功能跑得了 async / sleep / channel / 多 worker。生产 Tokio 是 50000+ 行,差什么?

### 我们简化掉的

1. **IO 集成**:Tokio 用 mio 监听 OS 事件(epoll / kqueue / IOCP),让 IO future 能被精确唤醒
2. **Timer wheel**:O(1) timer 调度,我们用 BinaryHeap 是 O(log n)
3. **Lock-free deque**:work stealing 用无锁数据结构,我们用 crossbeam-channel 是有锁的
4. **Task budget**:防止单个 task 长期占据 worker
5. **`spawn_blocking`**:专门的 blocking pool
6. **`Send + 'static` 之外的 spawn 形式**:`spawn_local`、`block_in_place` 等
7. **Hot/cold task 优化**:CPU cache friendly 的 task 放置
8. **tracing 集成**:可观察性
9. **Pin projection 工具**:`pin-project` crate
10. **大量边界情况**:cancellation、panic propagation、Drop 顺序、shutdown 时序

### 但你已经学到的

- async fn 编译成状态机
- Future + Pin + Waker 三件套
- Executor 怎么驱动 Future
- Timer 怎么集成进 reactor
- Channel 怎么用 future 实现"async recv"
- Work stealing 的基本思想

读 Tokio 源码现在不是迷雾——你看 `runtime/scheduler/multi_thread/worker.rs`,主循环就是 work_loop 的精修版。

---

## 20.7 章末小结

### 这本书走到这里

20 章下来,你从"为什么 Rust 跟其他语言不一样"一路走到"自己造一个 async runtime"。每个概念都在 capstone 里出现过——ownership(Task 的 owned future)、Pin(future 不能 move)、Waker(task 自唤醒)、unsafe(实际生产 runtime 大量用)、channel(mpsc 实现)、智能指针(Arc 共享 task)。

### 接下来该做什么

1. **给 Tokio 提一个 PR**:挑一个 good-first-issue,实战 Rust 工程
2. **重写一个 Stiglab 模块**:把我们讲的 trait / error / async 模式应用上去
3. **读 Rust 源码**:`std::sync::Mutex`、`std::collections::BTreeMap`、`std::vec::Vec`——这些都是世界级的工程参考
4. **持续 follow Rust 演进**:每年读 Rust roadmap、看 Rust Belt RustConf 演讲

Rust 不是学完就完了的语言。语言每 6 周一个版本,生态在快速演进。但你已经站在能跟得上的起点。

### 习题

#### 习题 20.1(简单)

把 20.2 的 executor 跑起来。spawn 几个 task,看输出顺序。

#### 习题 20.2(中等)

给 20.3 的 Sleep 加单元测试:验证 sleep 后真的过了至少那么久,但不会久太多。

#### 习题 20.3(中等)

给 20.4 的 channel 加 bounded 模式:`channel_bounded(capacity)`,buffer 满时 send 异步等待。

#### 习题 20.4(困难)

给 20.5 的 multi-worker executor 加 `JoinHandle`:`spawn` 返回一个 future,可以 await 拿到 task 的返回值。

#### 习题 20.5(开放,毕业)

把这本书的所有概念,用一段你自己的 Stiglab / Onsager 实战代码总结。
要求:涵盖 ownership、trait、error handling、async、unsafe(至少一处)、testing。

写完不需要给我看——这是给你自己的答卷。

---

> **本章一句话总结**
>
> 你已经能从零写一个能跑的 async runtime。这意味着你不只是 Rust 用户,你理解 Rust。剩下的路就是用这门语言写真实代码,把 Stiglab / Onsager 这些项目做到生产可用。
