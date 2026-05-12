# Ch 9 · 内部可变性

> Cell / RefCell / Mutex —— 在不可变接口下偷偷修改

**核心问题**:Rust 借用规则说"要么多个 `&T`,要么一个 `&mut T`",但有时候我们就是需要在 `&T` 下修改内部。怎么办?

借用规则是 Rust 的核心安全保证,但它**有时太严格**。observer pattern、cache、共享 mutex —— 这些场景需要"在外部看是不可变,内部能修改"。Rust 的答案是**内部可变性**:一组把借用检查从编译期推到运行时的类型。

读完你应该能:

1. 解释为什么需要内部可变性(给出两个真实场景)
2. 区分 `Cell` / `RefCell` / `Mutex` 各自的使用场景
3. 用 `RefCell` 实现一个简单 cache,知道 panic 风险点在哪
4. 理解 `UnsafeCell` 是所有内部可变性的根
5. 看懂 `Rc<RefCell<T>>` 这种"祖传组合"出现时是什么意思

---

## 9.1 为什么需要内部可变性

### 场景一:逻辑上不可变的对象需要内部缓存

```rust,ignore
struct Repo {
    data: Vec<u8>,
    // 想要:第一次访问 line_count 时计算并缓存,后续直接返回
    line_count_cache: Option<usize>,
}

impl Repo {
    fn line_count(&self) -> usize {  // 接口是 &self
        if let Some(n) = self.line_count_cache { return n; }
        let n = self.data.iter().filter(|&&b| b == b'\n').count();
        self.line_count_cache = Some(n);  // ❌ 不能在 &self 下修改
        n
    }
}
```

从语义讲,`Repo` 的状态(行数)没变,只是 cache 有变。强迫接口变 `&mut self` 会污染整个调用链。

### 场景二:trait 实现要求 `&self` 但你需要可变状态

```rust,ignore
trait Logger {
    fn log(&self, msg: &str);   // trait 定义 &self
}

struct CountingLogger {
    count: usize,
}

impl Logger for CountingLogger {
    fn log(&self, msg: &str) {
        self.count += 1;   // ❌ 不能改
        println!("[{}] {}", self.count, msg);
    }
}
```

不能改 trait,也不能让 `log` 变 `&mut self` —— 内部可变性是唯一解。

### 场景三:共享 mutable state(并发)

经典 `Arc<Mutex<T>>` 组合 —— 多个线程都有 `Arc<Mutex<T>>` 的 `&` 引用,要修改时通过 `lock()` 拿到 `&mut T`。如果没有内部可变性,这事根本做不到。

---

## 9.2 `Cell<T>`:Copy 类型的简单内部可变性

`Cell<T>` 是最简单的内部可变性:只能 get / set **整体**,没有借用检查开销。

```rust
use std::cell::Cell;

struct Counter { value: Cell<u32> }

impl Counter {
    fn new() -> Self { Counter { value: Cell::new(0) } }
    fn incr(&self) { self.value.set(self.value.get() + 1); }
    fn get(&self) -> u32 { self.value.get() }
}

fn main() {
    let c = Counter::new();
    c.incr();   // 通过 &self 修改内部
    c.incr();
    println!("{}", c.get());   // 2
}
```

### 特点

- `get(&self) -> T` —— 复制出来一份(要求 `T: Copy`)
- `set(&self, value: T)` —— 整体替换
- **没有运行时检查开销**(因为它根本不暴露 `&T` 给你,所以不会有"同时多个 borrow"的问题)
- 限制:不能对内部"取引用"修改字段

### 适用类型

- 数字、bool、枚举(任何 Copy 的)
- 不适合大对象(每次 get 复制成本高)
- 不能用于 `String`、`Vec` 等非 Copy 类型

---

## 9.3 `RefCell<T>`:运行时借用检查

`RefCell<T>` 适合**非 Copy 类型** + **需要 borrow / borrow_mut**。

```rust
use std::cell::RefCell;

let cell = RefCell::new(vec![1, 2, 3]);

{
    let r1 = cell.borrow();
    let r2 = cell.borrow();
    println!("{:?} {:?}", r1, r2);   // OK,多个 immutable borrow
}

{
    let mut m = cell.borrow_mut();
    m.push(4);                       // OK,独占 mutable borrow
}

// 错误用法:同时持有 immut 和 mut
let _r = cell.borrow();
let _m = cell.borrow_mut();          // panic at runtime!
```

### 关键点

- `borrow()` 返回 `Ref<T>`,`borrow_mut()` 返回 `RefMut<T>` —— 它们是 RAII 守卫,drop 时归还借用
- 违反借用规则:**运行时 panic**(不是编译错误!)
- 内部用一个计数器:借出 `Ref` +1,借出 `RefMut` 设特殊值

### 跟编译期借用检查的差异

| 维度 | 编译期 (`&` / `&mut`) | 运行时 (`RefCell`) |
|---|---|---|
| 检查时机 | 编译时 | 运行时 |
| 违反后果 | 编译错 | panic |
| 检查粒度 | 整体 | 整体 |
| 性能开销 | 0 | 每次 borrow 一个计数器更新(约 1 ns) |

**用 RefCell 等于自愿放弃了"编译期保证"。** 这是 trade-off,不是"更好用"。

### 工程纪律

1. 优先用 `&mut self`,不行才考虑 RefCell
2. RefCell 的作用域**尽量小**——拿到 `borrow_mut` 后,做完事情立刻 drop,不要拿在手上调用别的方法
3. 避免在 `borrow_mut` 还活着时调用回调 / 触发递归

### 经典反例:RefCell 在回调里炸

```rust,ignore
let observers: RefCell<Vec<Box<dyn Fn()>>> = ...;
observers.borrow().iter().for_each(|cb| cb());
// 如果某个 cb 内部又调了 observers.borrow_mut() —— panic
```

写 observer / event bus 时,**先 clone 出 callback 列表,drop borrow,再触发**。

---

## 9.4 `Mutex<T>` 与 `RwLock<T>`:线程安全的内部可变性

`RefCell` 不是 `Send + Sync`,跨线程要用 `Mutex` / `RwLock`。

### `Mutex<T>`:互斥锁

```rust
use std::sync::{Arc, Mutex};
use std::thread;

let counter = Arc::new(Mutex::new(0));
let mut handles = vec![];

for _ in 0..10 {
    let c = Arc::clone(&counter);
    handles.push(thread::spawn(move || {
        let mut n = c.lock().unwrap();   // 拿锁,得到 &mut 0
        *n += 1;
    }));
}

for h in handles { h.join().unwrap(); }
println!("{}", *counter.lock().unwrap());   // 10
```

- `lock()` 返回 `Result<MutexGuard<T>, PoisonError>` —— Guard drop 时自动 unlock
- **持锁线程 panic 时 mutex 被 poisoned**,下次 lock 返回 Err。可 `into_inner` 强制取出

### `RwLock<T>`:读写锁

```rust,ignore
use std::sync::RwLock;
let cache = RwLock::new(HashMap::new());

// 多个读
{ let r = cache.read().unwrap(); /* ... */ }
// 单个写
{ let mut w = cache.write().unwrap(); w.insert("k", "v"); }
```

读多写少的场景比 `Mutex` 性能好;读写比接近的场景 `Mutex` 反而更快(`RwLock` 协议开销大)。

### 跟 RefCell 的关系

```
单线程  →  跨线程
Cell    →  AtomicXxx
RefCell →  Mutex / RwLock
```

**API 几乎一一对应**,只是检查模型不一样:RefCell 运行时 panic,Mutex / RwLock 阻塞等。

---

## 9.5 `UnsafeCell`:内部可变性的最底层

```rust,ignore
pub struct UnsafeCell<T: ?Sized> { value: T }

impl<T: ?Sized> UnsafeCell<T> {
    pub const fn get(&self) -> *mut T { /* 返回内部数据的裸指针 */ }
}
```

`UnsafeCell` 是 Rust 类型系统里**唯一**能从 `&UnsafeCell<T>` 拿到 `*mut T` 的类型——它绕过的不是借用检查,而是编译器的"`&T` 不可变"假设。

**所有内部可变性都建立在 UnsafeCell 之上**:

- `Cell<T>` = `UnsafeCell<T>` + 受限 API
- `RefCell<T>` = `UnsafeCell<T>` + borrow counter
- `Mutex<T>` = `UnsafeCell<T>` + OS mutex
- `Atomic*` = `UnsafeCell<T>` + 原子指令

业务代码**永远不要直接用** `UnsafeCell`——它要求 unsafe,且没有任何安全保证。它是构建内部可变性抽象时才会用到的"原始材料"。

---

## 9.6 实战:基于 `Rc<RefCell>` 的双向链表

```rust
use std::rc::{Rc, Weak};
use std::cell::RefCell;

type Link<T> = Option<Rc<RefCell<Node<T>>>>;
type Back<T> = Option<Weak<RefCell<Node<T>>>>;

struct Node<T> { value: T, next: Link<T>, prev: Back<T> }

struct DList<T> { head: Link<T>, tail: Back<T> }

impl<T> DList<T> {
    fn new() -> Self { DList { head: None, tail: None } }

    fn push_front(&mut self, value: T) {
        let node = Rc::new(RefCell::new(Node { value, next: self.head.take(), prev: None }));
        if let Some(next) = &node.borrow().next {
            next.borrow_mut().prev = Some(Rc::downgrade(&node));
        } else {
            self.tail = Some(Rc::downgrade(&node));
        }
        self.head = Some(node);
    }
}
```

### 代价分析

- 每个 node 一次堆分配 + 引用计数
- 每次访问都要 `borrow()` / `borrow_mut()`,一次计数器更新
- 比 C++ `std::list` 慢 2-3 倍
- 写 / 调试都比预期复杂(`borrow` 作用域穿插)

### 替代方案:基于索引的链表

```rust,ignore
struct Node<T> { value: T, next: Option<usize>, prev: Option<usize> }
struct DList<T> { nodes: Vec<Node<T>>, head: Option<usize>, tail: Option<usize> }
```

- 没有 `Rc` / `RefCell`,没有引用计数
- "指针"是 `usize` 索引,缓存友好
- 借用检查靠 `&mut self`,自然
- 是 Rust 社区写图 / 树 / 链表的**事实标准**

**经验**:看到 `Rc<RefCell<T>>` 的链表 / 图,先问"能不能用 Vec + index 改写"。十有八九能,而且更快。

---

## 习题

1. 实现一个有 cache 的 `WordCounter`:`fn count(&self, word: &str) -> usize`,内部缓存 word 出现的次数。
2. 把 9.6 的双向链表改成索引版,对比代码量和性能(criterion)。
3. 用 `RefCell` 写一个 observer pattern,故意在回调里再次 borrow,看 panic 现场。改写成"先 clone callback list"的安全版本。
4. 用 `parking_lot::Mutex` 替换 `std::sync::Mutex`,对比性能(短临界区差别明显)。
5. 设计一个并发 LRU cache 的 lock 策略:整体 `Mutex<LRU>` vs 分桶 `Vec<Mutex<Bucket>>`。讨论 trade-off。

---

> **本章一句话总结**
>
> 内部可变性把"借用检查"从编译期推到运行时,代价是部分编译期保证消失。慎用,但必要时不要回避——`Arc<Mutex<T>>` 是 Rust 并发代码的日常,不是"代码味道"。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
