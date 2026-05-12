# Ch 8 · 智能指针

> Box / Rc / Arc / Cow —— 一组语义各异的容器

**核心问题**:每种智能指针解决了什么问题?它们的运行时代价和编译期约束分别是什么?

C++ 程序员第一次看到 `Box`、`Rc`、`Arc` 会觉得熟悉:跟 `unique_ptr`、`shared_ptr` 是一对一对应。但 Rust 比 C++ 多了几样:`Cow`、`Deref coercion`、跟 GC 语言不一样的"清晰所有权语义"。Go 工程师没有对应物——Go 的指针是"裸引用 + GC",所有权概念隐形。

读完你应该能:

1. 看到 `Box<T>` 不再问"为什么不直接放栈上"
2. 在 `Rc` 和 `Arc` 之间果断选择
3. 解释 Cow 的"零拷贝优化"在什么场景值得
4. 看懂 `Deref` 的自动解引用规则
5. 给你的领域问题选对智能指针

---

## 8.1 `Box<T>`:把数据放到堆上

`Box<T>` 是最简单的智能指针:**一个堆指针**,大小固定为 `usize`,drop 时 free 内存。

### 三种典型用途

**用途一:把大对象从栈搬到堆。**

```rust
struct BigStruct {
    data: [u8; 1_000_000],   // 1 MB
}

fn main() {
    let big = Box::new(BigStruct { data: [0; 1_000_000] });
    // big 在栈上只占 8 字节(指针),真正的 1MB 在堆上
}
```

栈空间有限(通常 1-8 MB),大对象放栈上轻则慢、重则 stack overflow。

**用途二:递归类型。**

```rust
enum List {
    Cons(i32, Box<List>),   // 不能写 Box<List> 改成 List —— 类型大小未知
    Nil,
}
```

编译器算 `List` 大小时:`Cons(i32, List)` 的大小 = `4 + sizeof(List)` —— 递归。`Box<List>` 是固定大小指针,递归终止。

**用途三:trait object 容器。**

```rust,ignore
trait Animal { fn speak(&self); }

let zoo: Vec<Box<dyn Animal>> = vec![
    Box::new(Cat),
    Box::new(Dog),
];
```

不同实现类型大小不同,放进同一 `Vec` 只能通过 trait object,而 trait object 大小不确定,必须装在 `Box`(或 `&`、`Arc` 等)里。

### 跟 Go / C# 类比

| 场景 | Go | C# | Rust |
|---|---|---|---|
| 堆分配 | 编译器逃逸分析(隐式) | `new` / 引用类型(隐式) | `Box::new`(显式) |
| 递归类型 | 用 pointer(`*Node`) | 用 reference 类型(`class Node`) | `Box<Node>` |
| 接口容器 | `[]SomeInterface`(自动 box) | `List<ISomething>` | `Vec<Box<dyn Trait>>` |

Rust 的"显式 Box"不是麻烦——它让"这里有一次堆分配"在代码里可见。Go 把堆分配藏在编译器里,排查内存问题时反而头疼。

### 代价

- 一次 `malloc` + `free`
- 一次额外的间接寻址
- 总体跟 C++ `unique_ptr` 完全等价

---

## 8.2 `Rc<T>`:单线程共享所有权

`Rc<T>`(Reference Counted)= 共享所有权 + 引用计数 + **不允许跨线程**。

### 典型用法

```rust
use std::rc::Rc;

let a = Rc::new(String::from("hello"));
let b = Rc::clone(&a);   // 计数 +1,不是 deep clone
let c = Rc::clone(&a);   // 计数 +1
println!("count = {}", Rc::strong_count(&a)); // 3
// 全部 drop 后,String 才被释放
```

`Rc::clone` 是 cheap 操作,只 +1 计数器。约定上不写 `a.clone()` 而是 `Rc::clone(&a)`,让"这只是共享一份引用"这个意图更明显。

### 为什么不能跨线程

`Rc` 内部计数器是普通 `usize`,**没有原子操作**。两个线程同时 `+1`,可能丢失更新,导致内存提前释放(use-after-free)或永不释放(leak)。

Rust 编译器知道这点:`Rc<T>` 不实现 `Send`。你尝试把 `Rc` move 到另一个线程:

```rust,ignore
let a = Rc::new(0);
std::thread::spawn(move || {
    println!("{}", a);  // 编译错误:`Rc<i32>` cannot be sent between threads safely
});
```

编译期堵死。这就是 Rust 类型系统的胜利——同一个 bug 在 C++ 是 segfault,Go 没有 Rc 这么直接的设计但有 channel 之类的等价坑。

### 循环引用问题

`Rc` + `Rc` 的 graph 会有循环引用:

```rust,ignore
struct Node {
    next: Option<Rc<RefCell<Node>>>,
}

let a = Rc::new(RefCell::new(Node { next: None }));
let b = Rc::new(RefCell::new(Node { next: Some(a.clone()) }));
a.borrow_mut().next = Some(b.clone());
// a -> b -> a -> b -> ... 计数器永远 > 0,内存泄漏
```

`Rc` 不防循环,它只在计数归零时才释放。

### `Weak<T>`:打破循环

```rust
use std::rc::{Rc, Weak};
use std::cell::RefCell;

struct Parent { children: RefCell<Vec<Rc<Child>>> }
struct Child  { parent:   RefCell<Weak<Parent>> }
```

约定:**owner 持有 `Rc`,被引用者持有 `Weak`**。父持有子 = `Rc<Child>`,子反向引用父 = `Weak<Parent>`。

`Weak` 不增加 strong count;访问要 `upgrade()` 拿到 `Option<Rc<T>>`(可能 None,表示对方已被释放)。

---

## 8.3 `Arc<T>`:多线程共享所有权

`Arc<T>`(Atomic Reference Counted)= `Rc<T>` 的多线程版,计数器用原子操作。

```rust
use std::sync::Arc;
use std::thread;

let data = Arc::new(vec![1, 2, 3]);
let mut handles = vec![];
for _ in 0..4 {
    let data = Arc::clone(&data);
    handles.push(thread::spawn(move || {
        println!("{:?}", data);
    }));
}
for h in handles { h.join().unwrap(); }
```

### 代价:为什么 Arc 比 Rc 慢

每次 `clone` / `drop`:

- `Rc`:一条 `inc` / `dec` 普通指令(约 1 ns)
- `Arc`:一条 `lock xadd` 原子指令(10-30 ns,跨 CPU cache 时可达 100 ns)

差距 10x-100x。对于热路径上每秒数百万次 clone 的场景(比如频繁的事件分发),`Rc` 和 `Arc` 的差距体感明显。

**经验**:单线程用 `Rc`,跨线程必须 `Arc`。**不要"为了将来扩展性"默认用 Arc** —— 在还没有跨线程需求时,这只是无谓的开销。

### Arc + Mutex / RwLock

`Arc<T>` 共享的是**不可变引用**。要共享并修改:

```rust
use std::sync::{Arc, Mutex};
let counter = Arc::new(Mutex::new(0));
let c = Arc::clone(&counter);
std::thread::spawn(move || { *c.lock().unwrap() += 1; });
```

`Arc<Mutex<T>>` 是 Rust 多线程共享可变状态的**事实标准**。看到这个组合不要诧异。

---

## 8.4 `Cow<'a, T>`:Clone on Write

### 动机

API 设计常见两难:

- 接收 `&str` 性能好,但调用方有 `String` 时要写 `&s`
- 接收 `String` 接口对调用方友好,但要 clone

`Cow`(Clone on Write)= **可能借用、可能拥有的两态枚举**。

```rust,ignore
pub enum Cow<'a, T: ?Sized + ToOwned> {
    Borrowed(&'a T),
    Owned(<T as ToOwned>::Owned),
}
```

### 经典场景:可能修改的字符串

```rust
use std::borrow::Cow;

fn normalize<'a>(s: &'a str) -> Cow<'a, str> {
    if s.contains(' ') {
        Cow::Owned(s.replace(' ', "_"))   // 需要修改,分配新 String
    } else {
        Cow::Borrowed(s)                  // 不需要修改,零拷贝
    }
}

fn main() {
    let a = normalize("hello");       // 借用,零分配
    let b = normalize("hi there");    // 拥有,一次分配
    println!("{} / {}", a, b);
}
```

**调用方完全感知不到差别**——`Cow<str>` 自动 `Deref` 成 `&str`,跟 `String` 一样能用 `.len()`、`.chars()`。

### 在 API 边界返回 Cow

```rust,ignore
pub fn config_value(&self, key: &str) -> Cow<'_, str>
```

返回 Cow 让你保留"零拷贝"的可能,同时也允许"需要的时候返回临时构造的字符串"。serde 大量使用这个模式做 zero-copy 反序列化。

### 适用场景

- 字符串清洗 / 规范化(大概率不修改,小概率修改)
- 反序列化(JSON 字段大部分能借,带转义的需要拥有)
- HTTP header 解析

不适用:**总是需要修改**(直接返回 `String`)、**总是只读**(直接返回 `&str`)。**Cow 是"动态选择"的工具**。

---

## 8.5 `Deref` / `DerefMut`:智能指针的核心 trait

```rust,ignore
pub trait Deref {
    type Target: ?Sized;
    fn deref(&self) -> &Self::Target;
}
```

实现 `Deref` 后,**编译器会自动在你的类型和它的 `Target` 之间做转换**:

```rust
let b = Box::new(String::from("hello"));
let len: usize = b.len();   // 实际是 (*b).len(),即 String::len
```

`Box<String>` 通过 Deref 链 `Box<String> -> String -> str`,自动可以调 `str` 的方法。

### 自定义类型的 Deref

```rust
use std::ops::Deref;

struct UserId(u64);

impl Deref for UserId {
    type Target = u64;
    fn deref(&self) -> &u64 { &self.0 }
}

fn main() {
    let id = UserId(42);
    println!("{}", *id + 1);   // 43
}
```

### Deref coercion 链

```rust
fn takes_str(s: &str) { println!("{}", s); }

let owned: String = String::from("hi");
takes_str(&owned);              // String → str
let boxed: Box<String> = Box::new(owned);
takes_str(&boxed);              // Box<String> → String → str
let arc: std::sync::Arc<Box<String>> = std::sync::Arc::new(boxed);
takes_str(&arc);                // Arc → Box → String → str
```

四种类型自动转。这就是为什么 Rust 函数普遍接受 `&str` 而不是 `&String` —— 接 `&str` 调用方任何 string-like 类型都能传。

### Deref 的工程纪律

不要为业务类型滥用 Deref —— 它是**给"指针类型"用的**(Box / Rc / Arc / 自定义 smart pointer)。把 `User` Deref 到 `UserId`,看起来方便,但破坏了"我看到 `User` 调 `.id()` 就是访问 id 字段"的可读性。

**经验**:newtype + 显式 `.0` 访问 > 滥用 Deref。

---

## 8.6 何时选哪个:决策流程

```
需要堆分配?
├─ 不需要(数据小且作用域清晰) → 直接放栈
└─ 需要 → 进入下一步

需要多个所有者?
├─ 单一所有者 → Box<T>
└─ 多个所有者 → 进入下一步

需要跨线程共享?
├─ 单线程 → Rc<T>(共享只读)
│              Rc<RefCell<T>>(共享可变)
└─ 多线程 → Arc<T>(共享只读)
              Arc<Mutex<T>>(共享可变)
              Arc<RwLock<T>>(读多写少)

API 边界,返回值可能借可能拥有? → Cow<'a, T>
```

### 反模式提示

- `Arc<Mutex<HashMap<K, V>>>` 性能瓶颈 → 考虑 `DashMap` 或 `Arc<RwLock>`
- `Rc<RefCell<T>>` 双向数据结构 → 优先用 index(`Vec` + `usize`)替代指针
- `Box<dyn Trait>` 满天飞 → 检查是否能用 enum 替代

---

## 习题

1. 把一个 C++ 用 `shared_ptr` 实现的 LRU cache 翻成 Rust。要求线程安全。
2. 写一个 `fn trim_lower(s: &str) -> Cow<'_, str>`,只在需要时分配。
3. 故意构造一个 `Rc` 循环引用,用 `Weak` 修好。
4. 读 `std::sync::Arc` 源码,找到 `clone` 里那条 `fetch_add` 用的是什么 ordering(`Relaxed`?),并解释为什么这个 ordering 够。
5. 设计一个 plugin trait,使用方用 `Vec<Box<dyn Plugin>>` 持有。讨论:为什么不用 enum?

---

> **本章一句话总结**
>
> 智能指针不是"更智能的指针",是"封装了不同所有权语义的容器"。选对它,代码自然简洁;选错它,你会从一种 bug 跳进另一种。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
