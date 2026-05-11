# 第 9 章 · 内部可变性 —— Cell / RefCell / Mutex

> "Sometimes you need to mutate through a shared reference. Rust gives you the tools, but at a cost."

Ch 3 我们立下了借用规则:`&T` 共享、`&mut T` 独占,二者互斥。但 stdlib 里有一类类型违反这条规则——通过 `&T` 也能修改内部状态。这叫**内部可变性(interior mutability)**。

这一章我们看 Cell、RefCell、Mutex/RwLock 这三组工具,以及它们各自的代价和适用场景。

读完这章你应该能:

1. 解释为什么"借用规则被打破"了但 Rust 仍然安全
2. 在 Cell / RefCell / Mutex 之间做正确选择
3. 看到 `Arc<Mutex<T>>` 时识别正确和反模式
4. 知道 `UnsafeCell` 在底层做什么(但还不用直接用它)

---

## 9.1 为什么需要内部可变性?

借用规则严格要求"要么多个共享借用要么一个独占借用"。但有些设计天然需要"共享 + 可修改":

### 场景 1:缓存

```rust
struct Memo {
    cache: HashMap<String, String>,
}

impl Memo {
    fn get(&self, key: &str) -> String {
        if let Some(v) = self.cache.get(key) {
            return v.clone();
        }
        let v = expensive_compute(key);
        self.cache.insert(key.into(), v.clone());  // ❌ &self 不能修改 cache
        v
    }
}
```

`get` 概念上是"读"操作,但需要更新缓存。如果签名改成 `&mut self`,调用方就必须独占整个 Memo,违反"读操作不该独占"的直觉。

### 场景 2:跨多个 reader 共享 + 偶尔写

```rust
struct Config { ... }

let config = Config::load();
// 4 个 reader 同时持有 &config
// 偶尔一个写操作要更新 config
```

`&config` 让多个 reader 共享。但更新时怎么办?

### 解决方案

内部可变性。Rust 提供几个 wrapper 类型,把"借用规则的检查"从编译期移到运行期(或者跨线程同步):

| 类型 | 何时检查 | 跨线程 | 用法 |
|---|---|---|---|
| `Cell<T>` | 不检查(只能 get/set) | ❌ | T 是 Copy 时的轻量内部可变 |
| `RefCell<T>` | 运行期 panic | ❌ | 单线程,复杂类型的内部可变 |
| `Mutex<T>` | 运行期阻塞 | ✅ | 跨线程同步 |
| `RwLock<T>` | 运行期阻塞,多 reader | ✅ | 读多写少场景 |
| `Atomic*` | 硬件原子操作 | ✅ | 简单数值的并发更新 |

---

## 9.2 Cell<T>:Copy 类型的轻量内部可变

`Cell<T>` 只能装 Copy 类型(`Cell::set` 要求 T: Copy)。它的接口很简单:

```rust
use std::cell::Cell;

let c = Cell::new(5);
let v = c.get();  // 5
c.set(10);
let v = c.get();  // 10
```

`Cell` 没有运行时借用检查——它不让你拿到内部值的引用,只能 get(copy 一份出来)或 set(整个替换)。所以借用规则被绕过了:同一时刻不会有 `&inner` 和 `&mut inner` 同时存在,因为你根本拿不到 `&inner`。

### 用途:简单的计数器、标志位

```rust
struct EventCounter {
    count: Cell<u64>,
}

impl EventCounter {
    fn record(&self) {           // 注意是 &self
        let n = self.count.get();
        self.count.set(n + 1);
    }
}
```

`record` 接收 `&self`,但能修改 count。这是 GC 语言里平凡的"通过对象引用修改其字段",在 Rust 里需要 Cell 表达。

### Cell 的成本

几乎为零——get/set 就是普通的内存读写,没有任何 lock 或运行时检查。比 Mutex 快几个数量级。

---

## 9.3 RefCell<T>:运行期借用检查

`RefCell<T>` 是"动态版本的借用规则"——它内部记录当前借用状态,违反规则时 panic。

```rust
use std::cell::RefCell;

let rc = RefCell::new(vec![1, 2, 3]);

{
    let r1 = rc.borrow();      // 共享借用
    let r2 = rc.borrow();      // 又一个共享借用,OK
    println!("{:?} {:?}", r1, r2);
}  // r1, r2 drop

{
    let mut r3 = rc.borrow_mut();  // 独占借用
    r3.push(4);
}  // r3 drop
```

`borrow()` 返回 `Ref<T>`(类似 `&T`),`borrow_mut()` 返回 `RefMut<T>`(类似 `&mut T`)。两者都实现了 Deref,用起来像普通引用。

### 违反规则时 panic

```rust
let rc = RefCell::new(5);
let r1 = rc.borrow();
let r2 = rc.borrow_mut();  // ❌ 运行时 panic:already borrowed
```

不是编译错误,是运行时 panic。这是 RefCell 的"代价"——把编译期保证降为运行期保证。

### 配合 Rc 实现"共享可变"

`RefCell<T>` 本身仍是 `Send`、`Sync` 等的影响。常见模式:`Rc<RefCell<T>>`——多个地方共享 + 通过运行时检查保证修改安全。

```rust
use std::rc::Rc;
use std::cell::RefCell;

let shared = Rc::new(RefCell::new(vec![1, 2, 3]));
let a = Rc::clone(&shared);
let b = Rc::clone(&shared);

a.borrow_mut().push(4);
println!("{:?}", b.borrow());  // [1, 2, 3, 4]
```

a 和 b 共享同一个 Vec,通过 RefCell 协调修改。但**单线程**——Rc 是 !Send,这个组合不能跨线程。

### 工程提醒

RefCell 是"安全的逃生舱口"——它让你写出借用检查器拒绝但实际安全的代码。但 panic 是真实风险。最佳实践:

- 借用作用域**尽量短**:`{ let mut x = rc.borrow_mut(); x.push(1); }`,不要让 RefMut 跨多个调用
- 不要把 RefMut 传给可能再次借用 RefCell 的函数(会 panic)
- 如果你的数据结构经常需要 `Rc<RefCell<...>>`,考虑是不是设计有问题——可能更好的方案是 owned 树 + channel 协调

---

## 9.4 Mutex<T>:跨线程同步

`Mutex<T>` 的 Rust 设计跟你在其他语言见的 mutex 不太一样——它**把数据包在锁里**,只能通过 lock 访问。

```rust
use std::sync::Mutex;

let m = Mutex::new(5);
{
    let mut n = m.lock().unwrap();
    *n += 1;
}  // 自动 unlock
```

`m.lock()` 返回 `MutexGuard<T>`——它实现 `Deref<Target = T>` 和 `DerefMut`,所以可以当 `&mut T` 用。Guard 离开作用域时自动释放锁(RAII)。

### 跟其他语言的 mutex 对比

| 维度 | Java/Go/C++ mutex | Rust Mutex |
|---|---|---|
| 锁和数据的关系 | 分离(你 lock,你访问数据,程序员保证一致) | 绑定(数据被锁包裹,只能 lock 后访问) |
| 忘记 lock 的风险 | 有 | 没有(类型系统强制) |
| 忘记 unlock 的风险 | 有 | 没有(Guard 自动 unlock) |
| 锁错对象的风险 | 有 | 没有(锁就是数据本身) |

Rust 把"锁要保护某个数据"这个工程意图编码进类型——锁包数据,不可分离。这消除了 GC 语言里"哪个锁保护哪个变量"这种纯靠程序员纪律的事。

### 标准模式:`Arc<Mutex<T>>` 跨线程共享可变

```rust
use std::sync::{Arc, Mutex};

let counter = Arc::new(Mutex::new(0));

let mut handles = vec![];
for _ in 0..10 {
    let counter = Arc::clone(&counter);
    let handle = std::thread::spawn(move || {
        let mut n = counter.lock().unwrap();
        *n += 1;
    });
    handles.push(handle);
}
for h in handles { h.join().unwrap(); }

println!("{}", *counter.lock().unwrap());  // 10
```

- Arc 给"多个地方持有"
- Mutex 给"运行时同步访问"

这是 Rust 跨线程可变状态的最常用模式。

### `.lock().unwrap()` 为什么 unwrap?

`lock()` 返回 `Result<MutexGuard<T>, PoisonError<...>>`。"Poisoned" 是指"上次拿锁的线程 panic 了,锁状态不确定"。

大部分代码直接 `unwrap()`——如果锁被毒化,继续也没意义。生产代码可以根据需要决定是 panic 还是恢复。

### Mutex 的代价

- 锁竞争时的等待
- 即使无竞争,获取锁也有内存屏障开销(纳秒级,但热点路径上累积)
- 死锁风险(Rust 不能防你"以不同顺序获取多个锁")

---

## 9.5 RwLock<T>:读多写少的优化

`RwLock<T>` 允许多个 reader 同时持有,但 writer 独占:

```rust
use std::sync::RwLock;

let lock = RwLock::new(5);

{
    let r1 = lock.read().unwrap();
    let r2 = lock.read().unwrap();
    // 多个 read 同时持有 OK
}

{
    let mut w = lock.write().unwrap();
    *w = 10;
    // write 独占
}
```

### 何时用 RwLock 而不是 Mutex

- 读 :: 写的比例很高(比如 100:1)
- 读操作不是极短(否则 RwLock 的额外开销可能超过收益)
- 没有"读完立刻要写"的模式(那种场景 Mutex 更合适)

工程经验:**默认 Mutex,profile 显示读争用是瓶颈再换 RwLock**。RwLock 的实现比 Mutex 复杂,无争用场景下 Mutex 还更快。

---

## 9.6 异步场景:`tokio::sync::Mutex` 不一样

`std::sync::Mutex` 是阻塞的——拿不到锁就 block 线程。**在 async 函数里 await 时持有 std Mutex 是灾难**——会阻塞整个 Tokio worker。

```rust
async fn bad() {
    let lock = mutex.lock().unwrap();   // std Mutex
    some_async_op().await;              // ❌ 在持锁期间 await,worker 卡死
}
```

Tokio 提供 async 版本:

```rust
use tokio::sync::Mutex;

async fn good() {
    let lock = mutex.lock().await;      // tokio Mutex,await 不阻塞 worker
    some_async_op().await;              // ✅ 安全
}
```

但有个反直觉的事实:**如果你的锁持有期完全不跨 await,std Mutex 反而更快**:

```rust
async fn fast() {
    {
        let mut n = std_mutex.lock().unwrap();
        *n += 1;
    }  // 立即释放
    some_async_op().await;
}
```

std Mutex 比 tokio Mutex 快几倍(没有 async overhead)。规则:

- 锁不跨 await:用 std Mutex
- 锁跨 await:用 tokio Mutex
- 不确定:用 tokio Mutex(更安全)

Ch 12-13 详谈。

---

## 9.7 工具选择决策树

```
我需要在 &self 上修改内部状态:

├── 内部数据是 Copy 类型(数值、bool、enum)?
│   ├── 是 → Cell<T>
│   └── 否 → 继续
│
├── 单线程?
│   ├── 是 → RefCell<T>
│   └── 否 → 继续
│
├── 简单数值,需要原子操作?
│   ├── 是 → AtomicI64 / AtomicBool / etc.
│   └── 否 → 继续
│
├── 跨线程,读多写少?
│   ├── 是 → RwLock<T>
│   └── 否 → Mutex<T>
│
└── 跨 async task 持有(跨 await)?
    ├── 是 → tokio::sync::Mutex<T>
    └── 否 → std::sync::Mutex<T>
```

---

## 9.8 实战:实现一个并发计数 LRU 缓存

把本章工具串起来。

### 需求

```rust
let cache: Cache<String, User> = Cache::new(100);
cache.insert("alice".into(), alice);
let user = cache.get("alice");
```

要求:
- 跨线程共享
- 容量上限(LRU 淘汰)
- 命中率统计

### 设计

```rust
use std::sync::{Arc, RwLock};
use std::sync::atomic::{AtomicU64, Ordering};
use std::collections::HashMap;

pub struct Cache<K, V> {
    inner: Arc<RwLock<CacheInner<K, V>>>,
    hits: Arc<AtomicU64>,
    misses: Arc<AtomicU64>,
}

struct CacheInner<K, V> {
    map: HashMap<K, V>,
    capacity: usize,
    // LRU 顺序简化:实际生产用 linked-list,这里省略
}

impl<K: std::hash::Hash + Eq + Clone, V: Clone> Cache<K, V> {
    pub fn new(capacity: usize) -> Self {
        Cache {
            inner: Arc::new(RwLock::new(CacheInner {
                map: HashMap::new(),
                capacity,
            })),
            hits: Arc::new(AtomicU64::new(0)),
            misses: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn get(&self, key: &K) -> Option<V> {
        let inner = self.inner.read().unwrap();
        let result = inner.map.get(key).cloned();
        if result.is_some() {
            self.hits.fetch_add(1, Ordering::Relaxed);
        } else {
            self.misses.fetch_add(1, Ordering::Relaxed);
        }
        result
    }

    pub fn insert(&self, key: K, value: V) {
        let mut inner = self.inner.write().unwrap();
        if inner.map.len() >= inner.capacity {
            // 简化:随便丢一个 key,真实 LRU 需要追踪访问时间
            if let Some(k) = inner.map.keys().next().cloned() {
                inner.map.remove(&k);
            }
        }
        inner.map.insert(key, value);
    }

    pub fn stats(&self) -> (u64, u64) {
        (
            self.hits.load(Ordering::Relaxed),
            self.misses.load(Ordering::Relaxed),
        )
    }
}

impl<K, V> Clone for Cache<K, V> {
    fn clone(&self) -> Self {
        Cache {
            inner: Arc::clone(&self.inner),
            hits: Arc::clone(&self.hits),
            misses: Arc::clone(&self.misses),
        }
    }
}
```

### 这个例子用到的工具

- `Arc<RwLock<...>>`:跨线程共享 + 读多写少
- `AtomicU64`:无锁的简单计数器(命中/未命中)
- `Clone` 手动实现:让 Cache 可以被多个 task 共享(都拿 Arc clone)

工程权衡:命中统计用 atomic 而不是放在 RwLock 内部,因为统计是高频写操作,不该跟主缓存争锁。这是典型的"分离锁粒度"模式。

---

## 9.9 章末小结与习题

### 本章核心概念回顾

1. **内部可变性**:通过 `&T` 也能修改内部状态——把借用检查从编译期移到运行期或同步原语
2. **Cell**:Copy 类型的轻量内部可变,无运行时检查,几乎零成本
3. **RefCell**:任意类型的运行时借用检查,违反规则 panic
4. **Mutex**:跨线程同步,数据被锁包裹,RAII 自动 unlock
5. **RwLock**:读多写少的优化,默认仍用 Mutex,profile 后再换
6. **tokio::sync::Mutex**:async 场景跨 await 时使用,不跨 await 用 std Mutex
7. **决策树**:Copy → Cell;单线程 → RefCell;跨线程数值 → Atomic;跨线程复杂数据 → Mutex / RwLock;async 跨 await → tokio Mutex

### 习题

#### 习题 9.1(简单)

下面代码不能编译,用合适的内部可变性工具修复:

```rust
struct Counter { value: u32 }

impl Counter {
    fn new() -> Self { Counter { value: 0 } }
    fn increment(&self) {           // 注意是 &self
        self.value += 1;
    }
}
```

#### 习题 9.2(中等)

实现一个 `LazyValue<T>`:第一次调用 `get` 时计算值并缓存,之后返回缓存:

```rust
let lazy = LazyValue::new(|| expensive_compute());
let v1 = lazy.get();  // 计算
let v2 = lazy.get();  // 返回缓存
```

签名:`fn get(&self) -> &T`(注意 &self)。

#### 习题 9.3(中等)

下面 async 代码有 bug,找出来:

```rust
async fn handle(state: Arc<std::sync::Mutex<State>>) {
    let mut s = state.lock().unwrap();
    s.fetch_remote().await;  // 假设这个 method 是 async
    s.update();
}
```

#### 习题 9.4(困难,工程)

回到 Stiglab。设计一个 `MetricsCollector`:

- 跨多个 task 收集 metrics
- 每秒导出一次到外部系统
- 收集是高频(每个请求几次),导出是低频(每秒一次)

要求:用本章工具,锁粒度合理,避免热点路径上有锁争用。

#### 习题 9.5(开放)

回顾你 Stiglab 代码中所有 `Arc<Mutex<T>>` 的使用。问每一处:

- 真的需要 Mutex 吗?能不能改成 channel?
- 真的需要 Mutex 吗?能不能改成 RwLock?
- 锁的粒度对吗?

---

### 下一章预告

Ch 10 我们处理 Rust 函数式编程的核心:**闭包与 iterator**。
你已经见过它们了,但 stdlib 里 iterator chain 的设计深度值得专门一章。

---

> **本章一句话总结**
>
> 内部可变性不是"打破借用规则",是"用另一种方式表达不变量"。Cell 零成本、RefCell 运行时检查、Mutex 跨线程同步——每种工具有它的场景,选错就性能或安全有代价。
