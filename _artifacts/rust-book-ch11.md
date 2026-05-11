# 第 11 章 · 线程、Send、Sync —— Fearless Concurrency

> "The promise: data races are eliminated at compile time. The cost: you have to think about Send and Sync."

Ch 9 我们看了同步原语(Mutex / RwLock)。这章我们处理上层故事:**Rust 的线程模型,以及让"无畏并发"成立的两个 marker trait**。

读完这章你应该能:

1. 解释 Send 和 Sync 到底意味着什么,各自拦截了什么 bug
2. 知道哪些类型自动是 Send/Sync,哪些不是
3. 用 scoped threads 写共享栈数据的并发代码
4. 选择 message passing(channel)vs shared state(Mutex)

---

## 11.1 std::thread:OS 线程

Rust 的线程是 1:1 OS 线程,不是协程。

```rust
use std::thread;

let handle = thread::spawn(|| {
    println!("hello from thread");
});

handle.join().unwrap();
```

`spawn` 返回 `JoinHandle<T>`,`join()` 等待线程结束并返回它的返回值。

### Closure 的 'static 要求

```rust
fn main() {
    let v = vec![1, 2, 3];
    thread::spawn(|| {
        println!("{:?}", v);  // ❌ closure 借用 v,但 v 可能比线程先 drop
    });
}
```

`thread::spawn` 要求 closure 是 `Send + 'static`。`'static` 意思是 closure 不能借用任何短期数据——线程可能比当前函数活得久,借用会悬垂。

修复:用 `move` 接管所有权:

```rust
fn main() {
    let v = vec![1, 2, 3];
    thread::spawn(move || {           // move 把 v 转移进 closure
        println!("{:?}", v);
    });
    // 这里 v 已经不能用了
}
```

---

## 11.2 Send 和 Sync:两个最重要的 marker trait

```rust
pub unsafe auto trait Send { }
pub unsafe auto trait Sync { }
```

- `T: Send` —— T 的**所有权**可以转移到另一个线程
- `T: Sync` —— `&T` 可以被多个线程同时持有(也就是 `T: Sync` 当且仅当 `&T: Send`)

这两个 trait 没有方法,只是标记。编译器看到跨线程操作时检查这些标记。

### 哪些类型 Send,哪些不是

| 类型 | Send? | 原因 |
|---|---|---|
| 基本类型(i32, bool, char) | ✅ | 完全 owned,无引用 |
| String, Vec, HashMap | ✅ | owned 数据,clear 边界 |
| Box\<T\>(T: Send) | ✅ | Box 持有 owned 数据 |
| Arc\<T\>(T: Send + Sync) | ✅ | Arc 用原子引用计数 |
| Rc\<T\> | ❌ | Rc 用非原子引用计数 |
| `*mut T` / `*const T` | ❌ | 裸指针默认不 Send |
| MutexGuard | ❌ | 锁必须在加锁的线程上释放 |
| Cell, RefCell | ✅(它们 Send) | 但不 Sync |

注意 **Rc 不 Send**——这就是为什么 Ch 8 说"Rc 单线程,Arc 跨线程"。编译期就这样拦下。

### 哪些类型 Sync,哪些不是

| 类型 | Sync? | 原因 |
|---|---|---|
| 基本类型 | ✅ | 多线程共享只读没问题 |
| String, Vec, HashMap | ✅ | 多线程共享 &T 安全 |
| Arc\<T\>(T: Send + Sync) | ✅ | |
| Mutex\<T\>(T: Send) | ✅ | Mutex 提供同步访问 |
| Rc\<T\> | ❌ | 共享 &Rc 等于共享引用计数,非原子有竞争 |
| Cell, RefCell | ❌ | 共享 &Cell 允许并发 set,有竞争 |

注意 **RefCell 不 Sync**——多线程共享 &RefCell 然后调 borrow_mut 会有竞争。这就是为什么 `Arc<RefCell<T>>` 编译不过,跨线程要用 `Arc<Mutex<T>>`。

### Auto trait:编译器自动推导

`Send` 和 `Sync` 是 **auto trait**——编译器根据类型的字段自动推导。

```rust
struct User { name: String, age: u32 }
// User 自动 Send + Sync,因为 String + u32 都 Send + Sync

struct WithRc { ptr: Rc<i32> }
// WithRc 不 Send,因为 Rc 不 Send
```

你的 struct 默认正确——你不用想 Send/Sync。只有当你用 `*mut T` / unsafe 设计才需要手动 impl(Ch 18 详谈)。

### 编译期阻拦的实例

```rust
use std::rc::Rc;

fn main() {
    let r = Rc::new(42);
    std::thread::spawn(move || {
        println!("{}", r);  // ❌
    });
}
```

报错:

```
error[E0277]: `Rc<i32>` cannot be sent between threads safely
  = help: within `[closure...]`, the trait `Send` is not implemented for `Rc<i32>`
```

编译期直接告诉你"这不行,Rc 不 Send"。换成 Arc 就行:

```rust
let r = Arc::new(42);
std::thread::spawn(move || {
    println!("{}", r);  // ✅
});
```

这就是 fearless concurrency 的字面体现——你"想犯错"都被编译器挡了。

---

## 11.3 Channel:message passing

Rust 的并发哲学倾向 message passing。stdlib 的 `mpsc`(multi-producer single-consumer):

```rust
use std::sync::mpsc;
use std::thread;

let (tx, rx) = mpsc::channel();

for i in 0..5 {
    let tx = tx.clone();
    thread::spawn(move || {
        tx.send(i).unwrap();
    });
}
drop(tx);  // 关闭原始 sender,这样 recv 在所有 sender drop 后能退出

while let Ok(n) = rx.recv() {
    println!("got {}", n);
}
```

特性:
- `tx.clone()` 允许多个 sender,但 receiver 只有一个
- `send` 在 receiver 还活着时成功,否则返回 Err
- `recv` 阻塞等待消息,所有 sender drop 后返回 Err

### Bounded vs Unbounded channel

stdlib `mpsc::channel` 是无界的(发送方永不阻塞)。stdlib 也有 `mpsc::sync_channel(n)` 是有界的(buffer 满时发送阻塞)。

外部库 `crossbeam-channel` 提供更强的 mpmc(multi-producer multi-consumer)channel,功能更全,性能更好。生产代码常用 crossbeam。

Tokio 提供 async 版本 channel(Ch 13 详讲)。

### Channel 的语义

`tx.send(value)` **move** value 进 channel。接收方 `rx.recv()` 拿到 owned 值。这是 ownership 通过 channel 转移,跟"克隆然后发"不同。

工程意义:**send 之后你不再持有 value**,这跟 Go 的 channel 语义一致(实际上 Go 的 channel 是从 CSP 偷的灵感,Rust 跟 Go 这里非常相似)。

---

## 11.4 选择:message passing vs shared state

| 维度 | Channel (message passing) | Mutex (shared state) |
|---|---|---|
| 心智模型 | 数据流向(producer → consumer) | 数据共享(谁持有锁谁能改) |
| 死锁风险 | 较低(单向通信) | 较高(多锁多 acquire 顺序) |
| 性能 | 一次 send/recv 有开销 | 锁开销,争用时慢 |
| 设计复杂度 | actor 风格,任务清晰 | 共享内存,需要锁纪律 |
| 适合场景 | 任务管道、producer/consumer | 缓存、计数器、统计 |

Rust 哲学倾向:**默认 channel,实在不行才共享**。原因是 channel 让所有权流动清晰,共享状态需要小心维护不变量。

但工程上两者经常混用——比如一个 Tokio task 内部用 Mutex,task 之间用 channel。这是常见模式,不用纠结"非此即彼"。

---

## 11.5 Scoped Threads:借栈数据的并发

普通 `thread::spawn` 要求 `'static`,不能借用栈上的数据。但有时你就是想"在一段作用域内并发处理一个 Vec",处理完再继续:

```rust
let v = vec![1, 2, 3];

std::thread::scope(|s| {
    for x in &v {
        s.spawn(|| {
            println!("{}", x);  // ✅ 可以借用 v 的元素
        });
    }
});
// scope 结束时,所有 spawn 的线程已 join
```

`std::thread::scope`(Rust 1.63+)允许 spawn 的线程借用外部数据,**前提是 scope 结束前所有线程都 join**。编译器保证这件事。

`crossbeam::thread::scope` 早就提供类似 API,1.63 之后 stdlib 有了官方版本。

### 工程价值

scoped thread 让"并行处理一段数据"零拷贝:

```rust
let data = vec![/* huge data */];
let results = std::thread::scope(|s| {
    let chunks: Vec<_> = data.chunks(1000).collect();
    let handles: Vec<_> = chunks.iter().map(|chunk| {
        s.spawn(|| process(chunk))           // 借用 chunk,不 clone
    }).collect();
    handles.into_iter().map(|h| h.join().unwrap()).collect::<Vec<_>>()
});
```

不用 Arc,不用 clone。可以借用栈上的 data。这是过去 Rust 的"短板"——现在被填补了。

---

## 11.6 实战:并发目录扫描

任务:统计一个目录(递归)下所有文件的总字节数。

### 单线程基线

```rust
use std::path::Path;

fn total_size(dir: &Path) -> std::io::Result<u64> {
    let mut total = 0;
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            total += total_size(&path)?;
        } else {
            total += entry.metadata()?.len();
        }
    }
    Ok(total)
}
```

### 并发版本(用 channel + worker pool)

```rust
use std::sync::mpsc;
use std::thread;
use std::path::PathBuf;

fn total_size_concurrent(root: PathBuf) -> u64 {
    let (tx, rx) = mpsc::channel::<PathBuf>();
    let (result_tx, result_rx) = mpsc::channel::<u64>();

    tx.send(root).unwrap();

    let workers = 4;
    let mut handles = vec![];

    for _ in 0..workers {
        let tx = tx.clone();
        let rx = rx.clone();   // 注意:mpsc::Receiver 不能 clone,这里需要外层包 Arc<Mutex<>>
        let result_tx = result_tx.clone();
        let handle = thread::spawn(move || {
            // 简化:省略 worker 逻辑
            // 实际要从 rx 取路径,处理,把子目录再 send 进 tx
        });
        handles.push(handle);
    }

    drop(tx);          // 关闭原始 sender
    drop(result_tx);

    let mut total = 0;
    while let Ok(n) = result_rx.recv() {
        total += n;
    }

    for h in handles { h.join().unwrap(); }
    total
}
```

(这个例子简化了。真实并发目录扫描要处理"work stealing"——空闲 worker 抢忙 worker 的活。完整实现见 `walkdir` crate。)

### 用 rayon 简化

`rayon` 是 Rust 数据并行的事实标准库。上面的代码用 rayon:

```rust
use rayon::prelude::*;

fn total_size_rayon(dir: &Path) -> std::io::Result<u64> {
    let entries: Vec<_> = std::fs::read_dir(dir)?.collect::<Result<_,_>>()?;
    let total: u64 = entries.par_iter().map(|entry| {
        let path = entry.path();
        if path.is_dir() {
            total_size_rayon(&path).unwrap_or(0)
        } else {
            entry.metadata().map(|m| m.len()).unwrap_or(0)
        }
    }).sum();
    Ok(total)
}
```

`par_iter()` 把普通迭代变成并行迭代,工作分配、线程池都 rayon 自动管理。

工程经验:**CPU bound 并行任务用 rayon,IO bound 用 Tokio**(Ch 12)。

---

## 11.7 章末小结与习题

### 本章核心概念回顾

1. **std::thread**:OS 线程,不是协程
2. **`spawn` 要求 closure `Send + 'static`**:跨线程边界的硬约束
3. **Send / Sync**:auto trait,编译器自动推导。Send 是所有权可转移,Sync 是 &T 可共享
4. **Rc 不 Send,Arc 是 Send**:这就是为什么 Arc 跨线程,Rc 单线程
5. **RefCell 不 Sync**:跨线程要 Mutex
6. **Channel 是 Rust 哲学的默认选择**:message passing 比 shared state 更清晰
7. **Scoped threads**:借栈数据的并发,过去的短板现在解决
8. **rayon for CPU,tokio for IO**:并行库的选择

### 习题

#### 习题 11.1(简单)

下面代码报错,解释原因并修复:

```rust
use std::rc::Rc;
fn main() {
    let r = Rc::new(42);
    std::thread::spawn(move || println!("{}", r));
}
```

#### 习题 11.2(中等)

用 channel 实现一个生产者-消费者:

- 一个生产者线程,每秒生成 1 个 i32
- 三个消费者线程,从 channel 取数字,打印 "consumer N got X"
- 主线程运行 10 秒后退出,所有线程清理

#### 习题 11.3(中等)

用 `std::thread::scope` 实现并行 `sum`,把一个 `Vec<i32>` 分给 4 个线程各自求和,然后合并:

```rust
fn parallel_sum(v: &[i32]) -> i32 {
    // 不 clone v,不 Arc,用 scope
}
```

#### 习题 11.4(困难)

实现一个简单的 `ThreadPool`:

```rust
let pool = ThreadPool::new(4);
for i in 0..10 {
    pool.execute(move || {
        println!("task {}", i);
    });
}
pool.shutdown();  // 等所有任务完成后退出
```

#### 习题 11.5(开放)

回顾你的 Crawlab 并发设计。如果用 Rust 重写,哪些地方该用 channel(任务管道),哪些该用 Mutex(共享统计),哪些该用 rayon(数据并行)?

---

### 下一章预告

Ch 12 我们进入异步——Future、Pin、async/await。Rust 的 async 跟 C# 的 async 有些表面相似,但底层完全不同。准备好心智重置。

---

> **本章一句话总结**
>
> Fearless concurrency 不是 Rust 没有并发 bug,是把"数据竞争"这一类 bug 编译期消除。Send / Sync 是这个保证的两根支柱。
