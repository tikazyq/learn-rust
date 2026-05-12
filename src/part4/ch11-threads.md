# Ch 11 · 线程与 Send/Sync

> Fearless concurrency 的真实含义

**核心问题**:Send 和 Sync 这两个 marker trait 是如何在编译期阻止 data race 的?

"Fearless concurrency" 是 Rust 最响亮的口号之一。它不是说"Rust 没有并发 bug"——你照样可能死锁、活锁、忘记 join。它说的是**一类**特定 bug:**data race(数据竞争)**——在编译期就被堵死,根本写不出来。

读完你应该能:

1. 用 `std::thread::spawn` 写出能编过的多线程代码,并解释为什么必须 `move`
2. 看到 `Send` / `Sync` 报错时能瞬间想到原因
3. 在"共享内存"和"message passing"之间做工程选择
4. 用 `Arc<Mutex>`、`mpsc`、`crossbeam::scope` 三种风格分别解决同一问题
5. 知道死锁/活锁还在,Rust 没免疫它们

---

## 11.1 `std::thread::spawn` 与 `JoinHandle`

```rust
use std::thread;

fn main() {
    let handle = thread::spawn(|| {
        println!("hello from spawned");
    });
    handle.join().unwrap();   // 等待结束
}
```

`spawn` 接受 `F: FnOnce() + Send + 'static`,返回 `JoinHandle<T>`。

### 为什么必须 `move`

```rust,ignore
let v = vec![1, 2, 3];
thread::spawn(|| println!("{:?}", v));   // ❌
```

报错:`closure may outlive the current function, but it borrows v`。

`v` 在 main 的栈帧里,子线程可能比 main 活得更久(虽然这里不会,但编译器假定最坏)。解法:

```rust
let v = vec![1, 2, 3];
std::thread::spawn(move || println!("{:?}", v));   // ✅
```

`move` 把 v 的所有权转给子线程,生命周期问题消失。

### 跟 Go goroutine 对比

```go
v := []int{1, 2, 3}
go func() { fmt.Println(v) }()   // 隐式 capture,编译能过
```

Go 让你"看起来很方便",代价是:你共享了一个 slice header,主程 / goroutine 都可能修改,这是 data race 的温床。Rust 强制你显式 `move`,本质是让"所有权转移"显示出来。

### 多个线程读同一份不可变数据

```rust
use std::sync::Arc;
use std::thread;

let data = Arc::new(vec![1, 2, 3]);
let mut handles = vec![];
for _ in 0..4 {
    let d = Arc::clone(&data);
    handles.push(thread::spawn(move || {
        println!("{:?}", d);
    }));
}
for h in handles { h.join().unwrap(); }
```

`Arc` 是"多个所有者"的标准方案(见 Ch 8)。

---

## 11.2 Send:类型可以被转移到另一个线程

`Send` 是 marker trait(没有方法,只是标签),表示"这个类型的值能跨线程移动"。

**绝大多数 Rust 类型自动实现 Send**:`i32`、`String`、`Vec<T>`(只要 T: Send)等。

### 几种不是 Send 的类型

| 类型 | 为什么不是 Send |
|---|---|
| `Rc<T>` | 引用计数不是原子的,跨线程修改是 data race |
| `*const T` / `*mut T` | 裸指针,Rust 不知道你怎么用 |
| `RefCell<T>` | 借用计数不是原子的(单线程才安全) |
| `Cell<T>` | 同上 |
| `MutexGuard<'_, T>` | 锁的 unlock 必须在 lock 的线程,跨线程释放是 UB |

### 报错示例

```rust,ignore
use std::rc::Rc;
use std::thread;

let a = Rc::new(1);
thread::spawn(move || println!("{}", a));
// error: `Rc<i32>` cannot be sent between threads safely
```

编译器直接堵在编译期。这是 Rust 跟 Go / C++ 的根本差别:那种 bug 在 Go 是 runtime data race,在 C++ 是 UB,在 Rust 是 type error。

---

## 11.3 Sync:类型的 &T 可以被多个线程共享

`Sync` 表示"`&T` 可以跨线程"。形式定义:**`T: Sync` 当且仅当 `&T: Send`**。

- `T: Sync` → 多个线程可以同时拿到 `&T`
- `T: Send` → 一个线程可以把 `T` 整体送给另一个线程

### Send 与 Sync 的组合

| 类型 | Send | Sync | 说明 |
|---|---|---|---|
| `i32` | ✅ | ✅ | 平凡 |
| `&T` (T: Sync) | ✅ | ✅ | 引用类型 |
| `Rc<T>` | ❌ | ❌ | 单线程共享 |
| `Arc<T>` | ✅ | ✅ | 多线程共享 |
| `RefCell<T>` | ✅ | ❌ | 单线程能 send,但不能多线程同时借 |
| `Mutex<T>` (T: Send) | ✅ | ✅ | 多线程共享可变 |
| `MutexGuard<'_, T>` | ❌ | ✅(T: Sync) | guard 必须在原线程 drop |
| `*mut T` | ❌ | ❌ | 裸指针默认 |

### auto trait

`Send` / `Sync` 是 **auto trait**:编译器自动为"所有字段都 Send 的 struct" 推 Send,自动为"所有字段都 Sync 的 struct" 推 Sync。你**几乎不用手写** `impl Send for ...`(手写要 unsafe,见 18 章)。

### 一个常见困惑

```rust,ignore
// 这能跨线程吗?
let s: String = "hi".into();
thread::spawn(move || println!("{}", s));   // ✅ String: Send
```

`String` 是 Send。Send 不要求"内部没有堆指针",只要求"整体所有权转移是安全的"。`String` 的堆指针随 String 一起 move 给新线程,旧线程没法访问,没有 race。

---

## 11.4 `std::sync::mpsc` 与 `Arc<Mutex>`

两种最常用的线程间通信模式。

### message passing:mpsc

```rust
use std::sync::mpsc;
use std::thread;

let (tx, rx) = mpsc::channel();

for i in 0..3 {
    let tx = tx.clone();
    thread::spawn(move || tx.send(i).unwrap());
}
drop(tx);   // 关闭原始 sender

for msg in rx { println!("{}", msg); }
```

- `mpsc` = multi-producer, single-consumer
- `tx.clone()` 创建额外的 sender,共享同一 channel
- 所有 sender drop 后,for 循环结束(`recv` 返回 Err)

### shared state:Arc<Mutex<T>>

```rust
use std::sync::{Arc, Mutex};
use std::thread;

let counter = Arc::new(Mutex::new(0));
let mut handles = vec![];

for _ in 0..10 {
    let c = Arc::clone(&counter);
    handles.push(thread::spawn(move || {
        let mut n = c.lock().unwrap();
        *n += 1;
    }));
}
for h in handles { h.join().unwrap(); }
println!("{}", *counter.lock().unwrap());   // 10
```

### 选择标准

| 场景 | 偏好 |
|---|---|
| 生产者-消费者 / 工作分发 | mpsc |
| pipeline / dataflow | mpsc |
| 共享配置 / 共享状态 | Arc<RwLock> |
| 共享计数器 | Arc<AtomicXxx> |
| 共享大 map | Arc<Mutex<HashMap>> 或 DashMap |

---

## 11.5 crossbeam 的 scoped threads

`std::thread::spawn` 要求 `'static`,所以你不能借栈数据。crossbeam(以及 1.63 后的 `std::thread::scope`)解决了这个:

```rust
use std::thread;

let data = vec![1, 2, 3, 4, 5];

thread::scope(|s| {
    for chunk in data.chunks(2) {
        s.spawn(move || {
            let sum: i32 = chunk.iter().sum();
            println!("chunk sum = {}", sum);
        });
    }
});   // scope 结束前所有 spawn 出去的都被 join
```

- `scope` 保证所有子线程在 scope 退出前 join
- 因此可以借用栈上数据(编译器知道借用不会逃出 scope)
- 完美适合"切片并行处理"这类 fork-join 模式

---

## 11.6 共享内存 vs message passing

Go 名言:"Don't communicate by sharing memory; share memory by communicating."(用通信共享内存,不要用共享内存通信。)

Rust 哲学:**两种都给你,自己选**。区别是:

| 维度 | shared memory (`Arc<Mutex>`) | message passing (`mpsc`) |
|---|---|---|
| 学习曲线 | 直观,但小心 deadlock | 模型清晰,但需要重排代码 |
| 性能 | 锁的临界区小则快 | 通道有内存分配,适中 |
| 调试 | 跨线程状态难看清 | 消息流可被序列化打印 |
| 适用 | 共享配置、计数器、大缓存 | 流水线、任务分发、actor 风格 |

我的经验:**默认 message passing**,只有"明显是共享 state(配置、计数、缓存)"的时候才上 `Arc<Mutex>`。

---

## 11.7 实战:并发目录扫描器

任务:递归扫描一个目录,统计所有 `.rs` 文件的总行数。

### 朴素串行

```rust,ignore
fn count_lines(path: &Path) -> usize {
    let mut total = 0;
    for entry in std::fs::read_dir(path).unwrap().flatten() {
        let p = entry.path();
        if p.is_dir() { total += count_lines(&p); }
        else if p.extension() == Some("rs".as_ref()) {
            total += std::fs::read_to_string(&p).unwrap().lines().count();
        }
    }
    total
}
```

### rayon 一键并行

```rust,ignore
use rayon::prelude::*;
use walkdir::WalkDir;

fn count_lines(root: &Path) -> usize {
    WalkDir::new(root).into_iter().filter_map(Result::ok)
        .filter(|e| e.path().extension() == Some("rs".as_ref()))
        .par_bridge()   // ← rayon 把串行 iterator 变并行
        .map(|e| std::fs::read_to_string(e.path()).unwrap().lines().count())
        .sum()
}
```

`rayon` 自动 work-stealing,4 核机器上几乎是 4x 加速。**生产里 90% 的"并行计算"任务都该先试 rayon**——把 `.iter()` 换 `.par_iter()` 就完事。

### 自己写 work-stealing

如果你想理解原理,Tokio / rayon 内部用的是:

1. 全局 / per-thread 任务队列(`crossbeam::deque`)
2. 每个 worker 从自己队列 pop,空了就从别人队列 steal
3. tasks 不可分割时就直接执行;可分割就 split + push

这是 Ch 20 mini-tokio 的核心结构。

---

## 习题

1. 不用 rayon,自己用 `thread::scope` + `mpsc` 写一个并行 `map`:`fn par_map<T, U>(items: Vec<T>, f: impl Fn(T) -> U + Sync) -> Vec<U>`。
2. 写一个程序故意构造死锁(两线程 + 两锁,反向加锁顺序)。再用 `parking_lot::deadlock` 检测器报告。
3. 把 `Rc<RefCell<Node>>` 的双向链表改成 `Arc<Mutex<Node>>` 版本,在多线程并发 push 测试。讨论锁粒度。
4. 解释:为什么 `MutexGuard` 不是 Send,但是 Sync?
5. 设计一个 worker pool:N 个 worker 从同一个 task 队列拿任务执行,主线程提交任务并等待全部完成。给出实现。

---

> **本章一句话总结**
>
> Send + Sync 是 Rust 敢叫 'fearless concurrency' 的根本原因——data race 这一整类 bug 在编译期就被堵死了。死锁还在,逻辑还要写对——但你至少不会用错共享。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
