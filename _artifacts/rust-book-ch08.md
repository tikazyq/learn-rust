# 第 8 章 · 智能指针 —— Box / Rc / Arc / Cow

> "In Rust, you always know who owns what. The smart pointers tell you how."

Ch 2-3 我们学了 ownership 和 borrowing。但 stack 上的值有大小限制,heap 上的值需要某种方式管理。智能指针就是 Rust 给你的工具箱——每种工具表达一种所有权策略。

读完这章你应该能:

1. 选对智能指针:什么时候用 Box,什么时候用 Rc,什么时候用 Arc,什么时候用 Cow
2. 理解 Rc 和 Arc 的成本差异,知道单线程场景为什么 Rc 更优
3. 用 Weak 打破循环引用,避免内存泄漏
4. 在 Stiglab 这类项目里识别"应该用 Arc 共享"的场景

---

## 8.1 Box<T>:堆上的独占所有权

`Box<T>` 是最简单的智能指针——它的功能就是"把 T 放在 heap 上,在 stack 上留一个指针"。

```rust
let b: Box<i32> = Box::new(5);
println!("{}", *b);  // 解引用,5
```

Box 离开作用域时,内部的 T 会被 drop,heap 内存被释放。完全自动。

### 什么时候用 Box

#### 场景 1:递归数据结构

```rust
// ❌ 不能编译
enum Tree {
    Leaf,
    Node(i32, Tree, Tree),  // 直接嵌套,大小无限递归
}
```

Tree 的大小是 `i32 + 2 * sizeof(Tree)`,无穷大。编译器拒绝。

```rust
// ✅
enum Tree {
    Leaf,
    Node(i32, Box<Tree>, Box<Tree>),  // Box 是固定大小的指针
}
```

`Box<Tree>` 是固定 8 字节(64 位),Tree 总大小有限。

#### 场景 2:大的 struct,避免栈溢出

```rust
struct HugeData {
    buffer: [u8; 1_000_000],  // 1MB 数组
}

fn main() {
    let data = HugeData { buffer: [0; 1_000_000] };  // ⚠️ 占满栈
    // 改成:
    let data = Box::new(HugeData { buffer: [0; 1_000_000] });  // ✅ 在 heap
}
```

栈一般几 MB,放大对象容易溢出。Box 把它移到 heap。

#### 场景 3:trait object

`dyn Trait` 是 unsized 类型,不能直接放在 stack。`Box<dyn Trait>` 给它一个固定大小的容器:

```rust
fn make_greeter(use_dog: bool) -> Box<dyn Greet> {
    if use_dog {
        Box::new(Dog { ... })
    } else {
        Box::new(User { ... })
    }
}
```

### Box 的成本

- 一次 heap 分配(创建时)
- 一次 heap 释放(drop 时)
- 解引用一层指针(运行时)

跟 C++ 的 `unique_ptr` 等价。零额外运行时开销(除了上面这些必要操作)。

---

## 8.2 Rc<T>:单线程引用计数

Box 是独占所有权。但有时你需要"多个地方共享同一个值"。Rc(Reference Counted)让你做到:

```rust
use std::rc::Rc;

let a = Rc::new(String::from("hello"));
let b = Rc::clone(&a);  // 引用计数 +1,不复制内部 String
let c = Rc::clone(&a);  // 引用计数 +1

println!("count = {}", Rc::strong_count(&a));  // 3
```

`Rc::clone` 不深拷贝内部值,只把引用计数 +1。所有 Rc 共享同一份内部数据。最后一个 Rc drop 时,引用计数到 0,内部值被 drop,heap 内存释放。

### Rc 的限制

`Rc<T>` **不能跨线程**——它的引用计数不是原子的。编译器通过 `Rc<T>: !Send` 在编译期阻止你把 Rc 传给另一个线程。

```rust
let a = Rc::new(42);
std::thread::spawn(move || {
    println!("{}", a);  // ❌ Rc<i32> cannot be sent between threads
});
```

要跨线程,用 Arc。

### Rc 的用途

主要用于"图状数据结构"——多个节点引用同一个值:

```rust
struct Graph {
    nodes: Vec<Rc<Node>>,
    edges: Vec<(Rc<Node>, Rc<Node>)>,
}
```

如果 Graph 用 owned `Node`,边里就只能存"index 或 ID 然后查",麻烦。用 Rc 就能直接存引用。

### Rc 的代价

- 引用计数操作(非原子,但仍有内存操作)
- 内部值不可变(Rc 只给共享借用,不给独占借用)

如果你需要"多个地方共享 + 可修改",得用 `Rc<RefCell<T>>` 组合。Ch 9 详讲。

---

## 8.3 Arc<T>:线程安全的引用计数

Arc(Atomic Reference Counted)跟 Rc 用法完全一样,差别只在底层用原子操作维护引用计数:

```rust
use std::sync::Arc;

let a = Arc::new(String::from("hello"));
let b = Arc::clone(&a);

std::thread::spawn(move || {
    println!("{}", b);  // ✅ Arc 可以跨线程
});
```

Arc 的代价:每次 clone/drop 都是原子操作,比 Rc 慢。但这是跨线程共享所有权的标准工具。

### 工程模式:`Arc<T>` 的几种典型用法

#### 模式 1:共享只读配置

```rust
let config = Arc::new(load_config()?);

for i in 0..4 {
    let config = Arc::clone(&config);
    tokio::spawn(async move {
        // 在 task 里读 config
        process(&config).await;
    });
}
```

配置加载一次,4 个 task 共享同一份,各自只读。

#### 模式 2:`Arc<Mutex<T>>`(可变共享状态)

```rust
let counter = Arc::new(Mutex::new(0));

for _ in 0..10 {
    let counter = Arc::clone(&counter);
    tokio::spawn(async move {
        let mut n = counter.lock().await;
        *n += 1;
    });
}
```

Arc 给"多个地方持有",Mutex 给"运行时同步访问"。组合是 Rust 跨线程可变状态的标准模式。

#### 模式 3:`Arc<dyn Trait>`(动态分发的共享)

```rust
let handler: Arc<dyn Handler> = Arc::new(MyHandler::new());

for i in 0..4 {
    let h = Arc::clone(&handler);
    tokio::spawn(async move {
        h.handle().await;
    });
}
```

Handler 实现可能很大,只想存一份。Arc 让你"共享 + 动态分发"两个特性叠加。

### Arc 不是 clone 的便宜替代品

新手有个反模式:每次借用检查报错就 `Arc<T>` 一把。这是误用。

`Arc<T>` 的语义是 **"我真的需要多处长期持有这个值"**。如果你的需求只是"这个函数借用一下",还是该用 `&T`。

判断标准:**这个值有没有跨越某个边界长期持有?**

- 跨线程边界 → Arc
- 跨 task 边界 → Arc
- 跨 struct 边界,且双方都需要持有 → Arc
- 仅是临时函数调用 → `&T`

---

## 8.4 Weak<T>:打破循环引用

Rc/Arc 用引用计数管理生命周期。但引用计数有死穴:**循环引用导致内存泄漏**。

```rust
use std::rc::Rc;
use std::cell::RefCell;

struct Node {
    next: Option<Rc<RefCell<Node>>>,
}

fn main() {
    let a = Rc::new(RefCell::new(Node { next: None }));
    let b = Rc::new(RefCell::new(Node { next: Some(Rc::clone(&a)) }));
    a.borrow_mut().next = Some(Rc::clone(&b));  // 形成循环
}
// main 结束,a 和 b 引用计数都是 1(互相引用),都不会 drop
// 内存泄漏
```

GC 语言(Java、Go)会通过 mark-sweep 检测循环引用并回收。Rc/Arc 是引用计数,做不到。

### Weak 的作用

`Weak<T>` 是 Rc/Arc 的"弱引用"——不增加引用计数,可以被 drop。

```rust
use std::rc::{Rc, Weak};

struct Parent {
    children: Vec<Rc<Child>>,
}

struct Child {
    parent: Weak<Parent>,  // 弱引用回父,不形成循环
}
```

Child 持有 Weak Parent,不阻止 Parent 被 drop。要用的时候 upgrade:

```rust
if let Some(parent) = child.parent.upgrade() {
    // parent 还活着,parent 是 Rc<Parent>
    println!("got parent");
} else {
    // parent 已被 drop
    println!("orphan");
}
```

### 设计原则

**"所有权"用 Rc/Arc,"反向引用"用 Weak**。

- 父→子:Rc(父拥有子)
- 子→父:Weak(子知道父但不拥有)

这跟数据库 schema 的 "one-to-many" 双向关联是一回事——主表用 owned 引用,反向用 weak/nullable 引用。

---

## 8.5 Cow<T>:Clone on Write,零拷贝优化

`Cow<'a, T>` 是个 enum:

```rust
enum Cow<'a, T: ?Sized + ToOwned + 'a> {
    Borrowed(&'a T),
    Owned(<T as ToOwned>::Owned),
}
```

读法:Cow 要么持有借用 `&'a T`,要么持有 owned `T::Owned`。常见的 `Cow<str>` 就是要么 `&str` 要么 `String`。

### 什么时候用 Cow

经典场景:**字符串处理,大多数时候不修改,偶尔需要修改**。

```rust
use std::borrow::Cow;

fn clean(s: &str) -> Cow<str> {
    if s.contains(' ') {
        Cow::Owned(s.replace(' ', "_"))  // 需要修改,返回 owned
    } else {
        Cow::Borrowed(s)                 // 不需要,返回借用
    }
}

fn main() {
    let a = clean("hello");        // Cow::Borrowed,零拷贝
    let b = clean("hello world");  // Cow::Owned,有 String 分配
    println!("{} {}", a, b);
}
```

调用方拿到 `Cow<str>` 可以当 `&str` 用(自动 deref),不需要关心内部是借用还是 owned。但内存效率:不修改时零拷贝,修改时才分配。

### Cow 的工程场景

- **配置解析**:大部分字段直接借用原始字符串,少数字段需要清洗后存
- **路径处理**:`Path::canonicalize` 之前的路径
- **JSON / YAML 处理**:大部分字段直接引用 raw bytes,转义字符出现时才分配新 String
- **HTML/SQL 转义**:大部分输入不需要转义

工程经验:**Cow 经常在 hot path 上是性能差异的关键**。serde、url、html5ever 这些库的内部到处是 Cow。

### Cow 用法注意

`Cow` 没有自动管理修改——你修改时要显式 `to_mut()`:

```rust
let mut cow: Cow<str> = Cow::Borrowed("hello");
let owned: &mut String = cow.to_mut();  // 如果是 Borrowed,clone 一次变成 Owned
owned.push_str(" world");
```

`to_mut` 的语义:**如果是 Borrowed,clone 成 Owned 再返回 &mut;如果已经是 Owned,直接返回 &mut**。这是 "copy on write" 的字面实现。

---

## 8.6 实战:实现一个 Arena Allocator

把本章工具串起来,我们做个练习——一个简单的 arena allocator。

### 什么是 arena

Arena 是一种内存分配模式:**预先分配一大块,逐步切分使用,最后一次性释放**。优势:

- 分配快(只是指针前移)
- 释放快(一次 drop 整个 arena)
- 缓存友好(数据局部性好)

适合"一批一起 alloc、一批一起 drop"的场景,比如 parser 的 AST、游戏每帧的临时对象。

### 简化实现

```rust
use std::cell::RefCell;

pub struct Arena<T> {
    chunks: RefCell<Vec<Box<[Option<T>]>>>,  // 每个 chunk 是固定大小的 Option<T> 数组
    chunk_size: usize,
}

impl<T> Arena<T> {
    pub fn new(chunk_size: usize) -> Self {
        Arena {
            chunks: RefCell::new(vec![]),
            chunk_size,
        }
    }

    pub fn alloc(&self, value: T) -> &T {
        // 简化版:每次都新分配一个 chunk
        // 真实 arena 会复用 chunk 直到满
        let mut chunks = self.chunks.borrow_mut();
        let mut chunk: Box<[Option<T>]> = (0..self.chunk_size)
            .map(|_| None)
            .collect::<Vec<_>>()
            .into_boxed_slice();
        chunk[0] = Some(value);
        chunks.push(chunk);

        // ⚠️ 这里返回 &T 需要 unsafe 处理生命周期
        // 简化展示:实际 arena 库(如 typed-arena)会用 unsafe 保证安全
        let last = chunks.last().unwrap();
        unsafe {
            // 把指针寿命延长到 self 的生命周期
            std::mem::transmute(last[0].as_ref().unwrap())
        }
    }
}
```

(真实 arena 实现要复杂得多,这里只展示概念。生产用 typed-arena 或 bumpalo 这类库。)

### 用 arena 的代码

```rust
let arena: Arena<String> = Arena::new(64);

let s1 = arena.alloc(String::from("hello"));
let s2 = arena.alloc(String::from("world"));

println!("{} {}", s1, s2);
// arena drop 时,所有 String 一次性释放
```

### 这个例子用到了什么

- `Box<[T]>` 表达"固定大小的 heap 分配"
- `RefCell<Vec<...>>` 表达"通过 &self 也能修改内部状态"(Ch 9 详讲 RefCell)
- `unsafe` 处理生命周期(Ch 18 详讲)

Arena 是 Rust 内存管理"工具箱外的工具"——大部分场景默认 Box/Rc/Arc 够用,但性能敏感场景 arena 是关键工具。

---

## 8.7 章末小结与习题

### 本章核心概念回顾

1. **Box<T>**:堆上的独占所有权,固定大小指针,用于递归类型 / 大对象 / trait object
2. **Rc<T>**:单线程引用计数,共享只读,!Send
3. **Arc<T>**:跨线程引用计数,原子操作,Send + Sync
4. **Weak<T>**:不增加引用计数的弱引用,打破循环
5. **Cow<T>**:Borrowed/Owned 二选一,零拷贝优化的关键工具
6. **Arc 不是 clone 的替代品**:它是"真的需要长期多处持有"的明确表达
7. **Arena**:一类一起 alloc 一类一起 drop 的内存模式

### 习题

#### 习题 8.1(简单)

下面 enum 不能编译,修复它:

```rust
enum List {
    Cons(i32, List),
    Nil,
}
```

#### 习题 8.2(中等)

设计一个"图"数据结构,节点之间多对多连接,允许循环。要求:

- 节点能被多个边引用
- 边持有节点
- 不能有内存泄漏

提示:用 Rc + Weak 组合。

#### 习题 8.3(中等)

实现一个函数 `normalize`,接受路径字符串,如果它已经是规范化的(没有 `./`、`../`、连续斜杠),直接返回借用;否则返回 owned 修正后的字符串:

```rust
fn normalize(path: &str) -> Cow<str> { ... }
```

#### 习题 8.4(困难)

回到 Stiglab。Control Plane 需要在多个 task 间共享一个 `SessionRegistry`(map from SessionId to Session)。设计三种实现方案:

- 方案 A:`Arc<Mutex<HashMap<SessionId, Session>>>`
- 方案 B:`Arc<DashMap<SessionId, Session>>`(并发安全 hashmap)
- 方案 C:每个 task 持有 owned copy(消息驱动同步)

各自的工程权衡是什么?Stiglab 该选哪个?

#### 习题 8.5(开放)

回顾你的 Stiglab/Onsager 代码,找一处 `Arc<T>` 或 `Box<T>` 的使用。问自己:

- 这里真的需要这个智能指针吗?换成 `&T` 行不行?
- 如果是 Arc,真的需要 Arc 而不是 Rc 吗?
- 这里的所有权流动清晰吗?

---

### 下一章预告

Ch 9 我们处理智能指针的"另一面":**内部可变性**。`Cell` / `RefCell` / `Mutex` —— 这些工具让你"通过共享借用也能修改"。看似违反借用规则,实际是更精细地控制不变量。

---

> **本章一句话总结**
>
> 智能指针不是关于"管理内存",是关于"表达所有权策略"。Box 独占、Rc 共享、Weak 弱引用、Cow 零拷贝——每种是工程问题的明确答案。
