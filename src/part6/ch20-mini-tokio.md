# Ch 20 · Capstone:从零实现 Mini-Tokio

> 把全书概念串起来,写一个能跑的异步 runtime

**核心问题**:看完这本书,你能不能给 Tokio 提 PR?可以,从 issue tracker 找 good first issue 开始。但在那之前,你应该亲手写一遍 mini-tokio——所有概念在自己实现里活一遍后,印象深 10 倍。

读完你应该能:

1. 写一个支持 `block_on` 的最简 executor
2. 支持 `spawn` 多个并发任务
3. 实现 `Sleep` Future + 简化的 timer wheel
4. 实现 `mpsc` channel
5. 升级到多线程 work-stealing scheduler
6. 解释你的 mini-tokio 跟真 Tokio 的差距在哪

---

## 20.1 设计目标

我们要做的 mini-tokio:

- ✅ `block_on(future)`:阻塞当前线程直到 Future 完成
- ✅ `spawn(future)`:把 Future 加入调度,返回 `JoinHandle`
- ✅ `Sleep::new(duration)`:返回一个 Future,睡 duration 后 ready
- ✅ `channel::<T>()`:async mpsc
- ✅ 多线程 work-stealing

不做:

- ❌ 真正的 IO(epoll / kqueue / IOCP)——简化课程范围
- ❌ Pin 投影宏 / 自适应缓冲
- ❌ 性能调优

代码总量 ~500 行,3 个文件搞定。

---

## 20.2 核心数据结构

```rust,ignore
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Wake, Waker};

struct Task {
    future: Mutex<Option<Pin<Box<dyn Future<Output = ()> + Send>>>>,
    queue: Arc<TaskQueue>,
}

struct TaskQueue {
    ready: Mutex<VecDeque<Arc<Task>>>,
    /* 唤醒主线程的机制(condvar 或 parking_lot::Park) */
}
```

每个 task 是一个 trait object Future(`dyn Future<Output = ()>`),装在 `Mutex<Option<...>>` 里:

- `Mutex` 因为 task 可能在多线程被 poll
- `Option` 因为 poll 完(`Poll::Ready`)后我们把 future drop 掉

---

## 20.3 Step 1:单线程 executor + block_on

```rust,ignore
use std::sync::Condvar;

struct Inner {
    ready: Mutex<VecDeque<Arc<Task>>>,
    cvar: Condvar,
}

struct Mini { inner: Arc<Inner> }

impl Mini {
    pub fn new() -> Self {
        Mini { inner: Arc::new(Inner {
            ready: Mutex::new(VecDeque::new()),
            cvar: Condvar::new(),
        }) }
    }

    pub fn block_on<F: Future>(&self, future: F) -> F::Output {
        // 单 future 简化版:不走 task queue,直接 park 自己
        let (sender, receiver) = std::sync::mpsc::channel();
        let main = MainTask { sender: Mutex::new(Some(sender)) };
        let waker = Waker::from(Arc::new(main));
        let mut cx = Context::from_waker(&waker);
        let mut future = std::pin::pin!(future);
        loop {
            match future.as_mut().poll(&mut cx) {
                Poll::Ready(v) => return v,
                Poll::Pending => { let _ = receiver.recv(); }
            }
        }
    }
}

struct MainTask { sender: Mutex<Option<std::sync::mpsc::Sender<()>>> }
impl Wake for MainTask {
    fn wake(self: Arc<Self>) { self.wake_by_ref(); }
    fn wake_by_ref(self: &Arc<Self>) {
        if let Some(s) = &*self.sender.lock().unwrap() { let _ = s.send(()); }
    }
}
```

试一下:

```rust,ignore
fn main() {
    let mini = Mini::new();
    let result = mini.block_on(async { 1 + 1 });
    println!("{}", result);   // 2
}
```

✅ 检查点:能跑通最简 async block。

---

## 20.4 Step 2:支持 spawn 与并发 task

加入任务队列:

```rust,ignore
struct Task {
    future: Mutex<Option<Pin<Box<dyn Future<Output = ()> + Send>>>>,
    queue: Arc<Inner>,
}

impl Wake for Task {
    fn wake(self: Arc<Self>) { self.wake_by_ref(); }
    fn wake_by_ref(self: &Arc<Self>) {
        let mut q = self.queue.ready.lock().unwrap();
        q.push_back(self.clone());
        self.queue.cvar.notify_one();
    }
}

impl Mini {
    pub fn spawn<F>(&self, future: F)
    where F: Future<Output = ()> + Send + 'static,
    {
        let task = Arc::new(Task {
            future: Mutex::new(Some(Box::pin(future))),
            queue: self.inner.clone(),
        });
        self.inner.ready.lock().unwrap().push_back(task.clone());
        self.inner.cvar.notify_one();
    }

    pub fn run(&self) {
        loop {
            let task = {
                let mut q = self.inner.ready.lock().unwrap();
                while q.is_empty() {
                    q = self.inner.cvar.wait(q).unwrap();
                }
                q.pop_front().unwrap()
            };
            let waker = Waker::from(task.clone());
            let mut cx = Context::from_waker(&waker);
            let mut fut_slot = task.future.lock().unwrap();
            if let Some(mut fut) = fut_slot.take() {
                match fut.as_mut().poll(&mut cx) {
                    Poll::Pending => *fut_slot = Some(fut),
                    Poll::Ready(()) => {}   // task 完成,future 已 drop
                }
            }
        }
    }
}
```

测试:

```rust,ignore
let mini = Mini::new();
for i in 0..5 {
    mini.spawn(async move {
        println!("task {}", i);
    });
}
mini.run();
```

✅ 检查点:能并发跑多个任务。

---

## 20.5 Step 3:实现 Sleep Future + timer wheel

```rust,ignore
use std::time::{Duration, Instant};
use std::collections::BinaryHeap;
use std::cmp::Reverse;

struct TimerEntry { deadline: Instant, waker: Waker }
impl Ord for TimerEntry { fn cmp(&self, o: &Self) -> std::cmp::Ordering { self.deadline.cmp(&o.deadline) } }
impl PartialOrd for TimerEntry { fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> { Some(self.cmp(o)) } }
impl Eq for TimerEntry {}
impl PartialEq for TimerEntry { fn eq(&self, o: &Self) -> bool { self.deadline == o.deadline } }

struct Timers { heap: Mutex<BinaryHeap<Reverse<TimerEntry>>> }

pub struct Sleep {
    deadline: Instant,
    registered: bool,
    timers: Arc<Timers>,
}

impl Sleep {
    pub fn new(timers: Arc<Timers>, dur: Duration) -> Self {
        Sleep { deadline: Instant::now() + dur, registered: false, timers }
    }
}

impl Future for Sleep {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if Instant::now() >= self.deadline { return Poll::Ready(()); }
        if !self.registered {
            self.timers.heap.lock().unwrap().push(Reverse(TimerEntry {
                deadline: self.deadline,
                waker: cx.waker().clone(),
            }));
            self.registered = true;
        }
        Poll::Pending
    }
}
```

executor 加 timer pump 线程:

```rust,ignore
fn timer_thread(timers: Arc<Timers>) {
    loop {
        let mut heap = timers.heap.lock().unwrap();
        let now = Instant::now();
        while let Some(Reverse(top)) = heap.peek() {
            if top.deadline <= now {
                let Reverse(e) = heap.pop().unwrap();
                e.waker.wake();
            } else { break; }
        }
        drop(heap);
        std::thread::sleep(Duration::from_millis(1));
    }
}
```

✅ 检查点:`spawn(async { Sleep::new(_, 1s).await; println!("done") })` 跑 1 秒后打印。

真 Tokio 用 hierarchical timer wheel 优化定时器 O(1) 插入,我们这版 O(log n) 用 BinaryHeap 足够教学。

---

## 20.6 Step 4:实现 channel

```rust,ignore
use std::collections::VecDeque;

struct Inner<T> {
    queue: Mutex<VecDeque<T>>,
    receiver_waker: Mutex<Option<Waker>>,
    closed: Mutex<bool>,
}

pub struct Sender<T>(Arc<Inner<T>>);
pub struct Receiver<T>(Arc<Inner<T>>);

pub fn channel<T>() -> (Sender<T>, Receiver<T>) {
    let inner = Arc::new(Inner {
        queue: Mutex::new(VecDeque::new()),
        receiver_waker: Mutex::new(None),
        closed: Mutex::new(false),
    });
    (Sender(inner.clone()), Receiver(inner))
}

impl<T> Sender<T> {
    pub fn send(&self, v: T) {
        self.0.queue.lock().unwrap().push_back(v);
        if let Some(w) = self.0.receiver_waker.lock().unwrap().take() {
            w.wake();
        }
    }
}

impl<T> Drop for Sender<T> {
    fn drop(&mut self) {
        *self.0.closed.lock().unwrap() = true;
        if let Some(w) = self.0.receiver_waker.lock().unwrap().take() {
            w.wake();
        }
    }
}

impl<T> Receiver<T> {
    pub fn recv(&mut self) -> Recv<'_, T> { Recv { rx: self } }
}

pub struct Recv<'a, T> { rx: &'a Receiver<T> }
impl<'a, T> Future for Recv<'a, T> {
    type Output = Option<T>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<T>> {
        if let Some(v) = self.rx.0.queue.lock().unwrap().pop_front() {
            return Poll::Ready(Some(v));
        }
        if *self.rx.0.closed.lock().unwrap() {
            return Poll::Ready(None);   // sender 都 drop 了,channel 关闭
        }
        *self.rx.0.receiver_waker.lock().unwrap() = Some(cx.waker().clone());
        // 再 check 一次防止 race
        if let Some(v) = self.rx.0.queue.lock().unwrap().pop_front() {
            return Poll::Ready(Some(v));
        }
        Poll::Pending
    }
}
```

✅ 检查点:两个 task 之间发送 / 接收消息。

注意 receiver `poll` 末尾的"二次检查"——经典 race 修复模式:**先存 waker 再检查 queue,防止"发完了再存 waker"的丢失唤醒**。

---

## 20.7 Step 5:多线程 work-stealing scheduler

把单一 task queue 拆成 per-worker 局部队列 + 全局 fallback 队列:

```rust,ignore
struct Worker {
    local: Mutex<VecDeque<Arc<Task>>>,
}

struct Shared {
    workers: Vec<Worker>,
    global: Mutex<VecDeque<Arc<Task>>>,
    cvar: Condvar,
}

fn worker_loop(shared: Arc<Shared>, idx: usize) {
    loop {
        // 1. 从自己的 local queue 拿
        if let Some(t) = shared.workers[idx].local.lock().unwrap().pop_front() {
            poll_task(t);
            continue;
        }
        // 2. 从全局拿
        if let Some(t) = shared.global.lock().unwrap().pop_front() {
            poll_task(t);
            continue;
        }
        // 3. 从别人那 steal(从队尾偷,降低冲突)
        for i in 0..shared.workers.len() {
            if i == idx { continue; }
            if let Some(t) = shared.workers[i].local.lock().unwrap().pop_back() {
                poll_task(t);
                break;
            }
        }
        // 4. 都空了,park 自己
    }
}
```

真 Tokio 用 `crossbeam::deque::Worker` / `Stealer` 实现无锁双端队列,本地 push/pop 不需要锁;我们用 `Mutex<VecDeque>` 简化教学。

✅ 检查点:N 个 worker 并行 poll 多个 task,CPU 利用率上去。

---

## 20.8 与真 Tokio 对比

| 维度 | mini-tokio | 真 Tokio |
|---|---|---|
| IO | 无 | mio 全套(epoll / kqueue / IOCP) |
| 调度 | 朴素 work-stealing | LIFO slot 优化、global injection queue、负载感知 |
| Timer | BinaryHeap O(log n) | hierarchical timer wheel O(1) |
| Task slab | Box | `Slab` + 自定义 allocator |
| Drop / cancellation | 简单 | abort token + 各种 join handle 协议 |
| Pin / 自引用 | 手动 box | `tokio::pin!` / 自适应 pin |
| Yield 公平性 | 无 | 协作式 yield budget(防止 task 永不让出) |
| 监控 | 无 | tokio-console / Tracing 集成 |
| 性能 | 教学 | 单机数百万 task / 数十万 QPS |

差距很大,但**机理是一样的**。读完真 Tokio 源码不再像第一次那么吓人——你知道每一个组件大概干什么。

---

## 习题(毕业作品)

1. **跑通整个 mini-tokio**(单线程 → spawn → sleep → channel → 多线程)。
2. **基准对比**:用 criterion 测 spawn 10000 个空 task 的吞吐,跟 tokio 对比,差距多少?
3. **加 select! 宏**:声明宏实现简化版 `select!`。
4. **加 abort 支持**:`spawn` 返回 `JoinHandle`,可以 `abort()`。
5. **提一个 Tokio 文档 PR**(typo 也行 —— 走完贡献流程是真正的毕业)。

---

> **本章一句话总结**
>
> 走完这章,你就走完了从 GC 语言到 Rust 内部的全程。剩下的是日复一日的工程实践——但你已经站在能看得清整张图的高度了。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
