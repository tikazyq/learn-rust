# 第 18 章 · Unsafe Rust —— Rustonomicon 速成

> "Safe Rust is the language. Unsafe Rust is the runtime contract."
> — Rustonomicon

这章是这本书的差异化章节。市面上的 Rust 教材大多止步于 safe Rust——讲完 Result、async/await 就结束。但你的目标是"全面掌握 Rust 含底层",unsafe 是必修。

读完这章你应该能:

1. 解释 unsafe 到底允许了什么,以及没改变什么
2. 列举 Rust 的 undefined behavior(UB)清单,知道每条踩了会怎样
3. 理解 stacked borrows / tree borrows 这套别名规则
4. 手动 impl Send/Sync 时知道你在承诺什么
5. 用 Miri 检测 unsafe 代码的 UB

---

## 18.1 unsafe 到底允许了什么

`unsafe` 不是"关掉所有检查"。它**只**允许五件事:

1. 解引用裸指针(`*ptr` 当 `ptr: *const T` 或 `*mut T`)
2. 调用 unsafe 函数
3. 访问或修改可变 static 变量
4. 实现 unsafe trait
5. 访问 union 的字段

仍然检查的:
- 类型检查
- 借用检查(在 `&T` 和 `&mut T` 上)
- 生命周期检查
- 私有性检查

```rust
unsafe fn dangerous() { ... }

unsafe {
    dangerous();           // ✅ unsafe 块里能调
    let ptr = 0x1000 as *const i32;
    let v = *ptr;          // ✅ 解引用裸指针(但这地址非法,运行时 segfault)

    let s = String::from("hi");
    let _ = s + "x";       // 仍然遵守 ownership 规则,这里 s 被 move
    // println!("{}", s);  // ❌ 仍然报借用错误
}
```

unsafe 是"我向编译器承诺这里我懂",不是"编译器闭嘴"。

---

## 18.2 Undefined Behavior 清单

Rust 的 UB 列表(`std::hint::unreachable_unchecked` 旁边的文档有完整版):

| UB 类型 | 例子 |
|---|---|
| Data race | 两个线程同时写一个 `*mut T`(未同步) |
| 解引用 null / 悬垂指针 | `*null::<i32>()`、`*已释放内存` |
| 解引用未对齐指针 | `*(0x1003 as *const u64)`(u64 要 8 字节对齐) |
| 违反 `&T` / `&mut T` 别名规则 | 同时存在 `&mut T` 和 `&T` 指向同一内存 |
| 读取未初始化内存 | `let x: i32 = MaybeUninit::uninit().assume_init()` |
| 类型 punning 违反 validity | bool 取值非 0/1、char 超 Unicode 范围、enum tag 超 variant |
| 调用错误的函数签名 | FFI 时声明类型跟实际不匹配 |
| 整数除零 / overflow(debug 模式 panic,release 是 UB? 不是 UB,是 wrap) | 实际上整数 overflow 不是 UB,而是 wrap(release)或 panic(debug) |
| 越界访问(裸指针) | `slice::get_unchecked` 越界 |

UB 的可怕之处:**编译器可以基于"UB 不会发生"的假设做激进优化**。一旦你触发 UB,程序可能行为完全不可预测——不是简单的崩溃。

举例:

```rust
unsafe fn foo(x: i32) -> i32 {
    if x < 0 {
        std::hint::unreachable_unchecked()  // 承诺这分支永不到达
    }
    x * 2
}

foo(-1);  // UB,编译器假定永不发生,实际优化可能跳过 if 检查直接 x * 2
```

---

## 18.3 别名规则:Stacked Borrows / Tree Borrows

Rust 的核心承诺:**`&mut T` 是独占的,`&T` 不能跟 `&mut T` 共存**。但在 unsafe 代码里,你可能创建多个裸指针指向同一内存——这时编译器怎么知道哪个是哪个?

### Stacked Borrows(原模型)

每个内存位置有一个"借用栈"。每次创建引用就 push 一个 tag,使用引用时检查 tag 是否还在栈里:

```rust
let mut x = 5;
let r1 = &mut x;        // push tag T1
let r2 = &mut *r1;      // push tag T2
*r2 = 6;                // OK,T2 在栈顶
*r1 = 7;                // pop T2(被覆盖),r1 仍在,OK
// *r2 = 8;             // ❌ T2 已被 pop,UB
```

这就是为什么"重借用"是合法的——内层借用结束后外层借用还能用。

### Tree Borrows(新模型,2023+)

Stacked Borrows 在某些合法 unsafe 模式下过于严格。Tree Borrows 用树结构表示借用关系,更宽松也更精确。

实操你不用记规则,但应该知道:**Miri 在用这套模型检测你的 unsafe 代码,如果 Miri 报错,大概率你违反了别名规则,即使代码看起来"应该正确"**。

---

## 18.4 裸指针 vs 引用

裸指针:`*const T` / `*mut T`。

```rust
let x = 42;
let p: *const i32 = &x;                  // 安全:从引用得来
let q = 0x1000 as *const i32;            // 安全:仅创建,未解引用
unsafe {
    let v = *p;                          // unsafe:解引用
}
```

裸指针的特点:
- 可以为 null
- 可以悬垂
- 不遵守借用规则(多个 `*mut T` 并存合法)
- 解引用必须 unsafe

### 从引用得到裸指针,反之亦然

```rust
let mut x = 5;
let p: *mut i32 = &mut x;                // 引用 → 裸指针
unsafe {
    let r: &mut i32 = &mut *p;           // 裸指针 → 引用(unsafe)
}
```

裸指针 → 引用的转换是 unsafe 的——你承诺这指针非 null、对齐、指向有效初始化的 T,没有别名冲突。

### `NonNull<T>`

`std::ptr::NonNull<T>` 是"保证非 null"的裸指针,适合实现智能指针:

```rust
use std::ptr::NonNull;

struct MyBox<T> {
    ptr: NonNull<T>,
}
```

NonNull 让 `Option<MyBox<T>>` 跟 `MyBox<T>` 同样大小(null pointer optimization)。

---

## 18.5 UnsafeCell:内部可变性的根基

你可能没意识到——`Cell`、`RefCell`、`Mutex` 都建立在一个底层 primitive:`UnsafeCell<T>`。

```rust
pub struct UnsafeCell<T: ?Sized> { value: T }

impl<T: ?Sized> UnsafeCell<T> {
    pub fn get(&self) -> *mut T { ... }    // 注意是 &self 返回 *mut T
}
```

`UnsafeCell::get` 是 **唯一合法的"从 &T 得到 *mut T"的途径**——所有其他类型都受借用规则约束,只有 UnsafeCell 是编译器特殊照顾的"内部可变性钩子"。

`Cell` / `RefCell` / `Mutex` 等内部都有 `UnsafeCell<T>`,通过它实现"&T 也能修改"。

工程含义:你**几乎永远不需要直接用 UnsafeCell**。stdlib 已经把所有合理的内部可变性模式封装好了。但理解它的存在,能让你不再觉得"&self 修改"是魔法。

---

## 18.6 手动 impl Send / Sync

绝大部分类型 Send / Sync 自动推导。但当你设计含裸指针的类型,自动推导失败:

```rust
struct MyContainer {
    data: *mut u8,
    len: usize,
}

// MyContainer 不自动 Send / Sync,因为 *mut u8 不是
```

如果你**确信**它跨线程安全(比如 data 实际指向 heap,且类型设计保证不会并发访问),手动 impl:

```rust
unsafe impl Send for MyContainer {}
unsafe impl Sync for MyContainer {}
```

`unsafe impl` 是你向编译器承诺"我已经分析过,这个类型跨线程安全"。如果你说错,后果是 data race(UB)。

### 正确的 unsafe impl 的判断

`Send` 的承诺:**T 的所有权移到另一线程,再被使用,不会引发 UB**。
`Sync` 的承诺:**多个线程同时持有 &T,并发使用,不会引发 UB**。

判断时:
- 内部裸指针是 owned 还是 borrowed?owned 才可能 Send。
- 内部状态修改有同步保护吗?有才可能 Sync。
- 跟外部资源(文件、socket)的关系?有些资源 OS 层面就线程局部。

实际:stdlib 的 `Vec<T>` 怎么是 Send + Sync?它内部有 `*mut T`,但通过 ownership 和借用规则,保证不会有 data race。

---

## 18.7 Variance 与 PhantomData

Ch 7 提过 variance。在 unsafe 代码里 variance 突然重要——因为编译器无法从你的裸指针字段推导出 variance。

```rust
struct MyVec<T> {
    ptr: *mut T,
    len: usize,
    cap: usize,
}
// 这个 struct 在 T 上 invariant(裸指针是 invariant 的)
// 但实际语义上,Vec 应该在 T 上 covariant —— Vec<&'long T> 应该能当 Vec<&'short T> 用
```

解决方法:`PhantomData`。

```rust
use std::marker::PhantomData;

struct MyVec<T> {
    ptr: *mut T,
    len: usize,
    cap: usize,
    _marker: PhantomData<T>,        // 让 MyVec<T> 在 T 上 covariant
}
```

`PhantomData<T>` 是零大小标记,告诉编译器"这个类型逻辑上持有 T",从而推导出正确的 variance / drop check / Send / Sync。

stdlib 的 `Vec<T>` 内部就是 `RawVec<T>`,里面有 `*mut T` + `PhantomData<T>`。

### PhantomData 的其他形态

| 形态 | variance | 例子 |
|---|---|---|
| `PhantomData<T>` | covariant in T | Vec、Box |
| `PhantomData<&'a T>` | covariant in 'a 和 T | iter::Iter |
| `PhantomData<*const T>` | covariant in T, !Send + !Sync | 表示"指针但不跨线程" |
| `PhantomData<*mut T>` | invariant in T, !Send + !Sync | mutable 裸指针 |
| `PhantomData<fn() -> T>` | covariant in T, Send + Sync 即使 T 不是 | 函数指针 |
| `PhantomData<fn(T)>` | contravariant in T | 函数参数 |

选对 PhantomData 是 unsafe 代码常见难点。Rustonomicon 有完整指南。

---

## 18.8 Miri:UB 检测器

Miri 是 Rust 的 interpreter,精确检测 UB:

```bash
rustup +nightly component add miri
cargo +nightly miri test
cargo +nightly miri run
```

Miri 会:
- 检测越界访问
- 检测未初始化内存读取
- 检测别名规则违反(stacked borrows / tree borrows)
- 检测 data race(单线程模式有限,多线程靠 loom)

**任何包含 unsafe 的代码都应该跑 Miri**。CI 里加 `cargo miri test` 是 unsafe 代码工程化的基本要求。

### Miri 的限制

- 慢(比正常执行慢 100x+)
- 不能跑 FFI(没有 C 函数)
- 某些 syscall 不支持

但对内部 unsafe 算法的验证够用了。

---

## 18.9 实战:实现一个简化版 Vec

把本章工具串起来。实现 `MyVec<T>`,只支持 push / pop / index:

```rust
use std::alloc::{alloc, dealloc, realloc, Layout};
use std::marker::PhantomData;
use std::ptr::{self, NonNull};
use std::ops::Index;

pub struct MyVec<T> {
    ptr: NonNull<T>,
    len: usize,
    cap: usize,
    _marker: PhantomData<T>,
}

unsafe impl<T: Send> Send for MyVec<T> {}
unsafe impl<T: Sync> Sync for MyVec<T> {}

impl<T> MyVec<T> {
    pub fn new() -> Self {
        MyVec {
            ptr: NonNull::dangling(),  // 占位,无分配
            len: 0,
            cap: 0,
            _marker: PhantomData,
        }
    }

    pub fn push(&mut self, value: T) {
        if self.len == self.cap {
            self.grow();
        }
        unsafe {
            ptr::write(self.ptr.as_ptr().add(self.len), value);
        }
        self.len += 1;
    }

    pub fn pop(&mut self) -> Option<T> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        unsafe {
            Some(ptr::read(self.ptr.as_ptr().add(self.len)))
        }
    }

    fn grow(&mut self) {
        let new_cap = if self.cap == 0 { 4 } else { self.cap * 2 };
        let layout = Layout::array::<T>(new_cap).expect("overflow");

        let new_ptr = if self.cap == 0 {
            unsafe { alloc(layout) }
        } else {
            let old_layout = Layout::array::<T>(self.cap).unwrap();
            unsafe { realloc(self.ptr.as_ptr() as *mut u8, old_layout, layout.size()) }
        };

        self.ptr = NonNull::new(new_ptr as *mut T).expect("alloc failed");
        self.cap = new_cap;
    }
}

impl<T> Drop for MyVec<T> {
    fn drop(&mut self) {
        if self.cap > 0 {
            // 先 drop 所有元素
            while let Some(_) = self.pop() {}
            // 然后释放内存
            let layout = Layout::array::<T>(self.cap).unwrap();
            unsafe {
                dealloc(self.ptr.as_ptr() as *mut u8, layout);
            }
        }
    }
}

impl<T> Index<usize> for MyVec<T> {
    type Output = T;
    fn index(&self, idx: usize) -> &T {
        assert!(idx < self.len, "out of bounds");
        unsafe { &*self.ptr.as_ptr().add(idx) }
    }
}
```

每行 unsafe 都有承诺:
- `ptr::write(..., value)`:承诺目标内存未初始化(push 时是 cap 内的未初始化区)
- `ptr::read(...)`:承诺源内存已初始化(pop 时是已 push 的元素)
- `&*self.ptr.as_ptr().add(idx)`:承诺 idx < len(已 assert)

跑 `cargo miri test` 验证。

### 这个例子展示了什么

- `NonNull<T>` 的实际用法
- `PhantomData<T>` 给 covariance
- `unsafe impl Send / Sync` 承诺线程安全
- 手动管理 alloc / realloc / dealloc
- 手动管理 drop 顺序

100 行代码,等同于一个简化的 `Vec<T>`。stdlib `Vec` 比这复杂 10 倍——优化、特化、内存对齐、容错——但核心结构一致。

---

## 18.10 章末小结与习题

### 本章核心概念回顾

1. **unsafe 只允许 5 件事**:解引用裸指针 / 调 unsafe 函数 / 改 mut static / 实现 unsafe trait / 访问 union
2. **UB 清单**:data race / 悬垂 / 未对齐 / 别名违反 / 未初始化 / 类型 punning 等
3. **Stacked / Tree Borrows**:别名规则在 unsafe 代码里的具体模型
4. **裸指针 vs 引用**:裸指针无借用规则,转引用是 unsafe
5. **UnsafeCell**:内部可变性的唯一合法根基
6. **手动 Send / Sync**:`unsafe impl` 是承诺,错了 UB
7. **PhantomData**:控制 variance 和"逻辑持有"
8. **Miri**:CI 必跑,检测大部分 UB

### 习题

#### 习题 18.1(简单)

下面代码有 UB,找出来:

```rust
fn main() {
    let p: *const i32 = std::ptr::null();
    unsafe { println!("{}", *p); }
}
```

#### 习题 18.2(中等)

实现一个 unsafe 函数 `swap<T>(a: *mut T, b: *mut T)` 交换两个指针指向的值。要求:不要求 T: Copy。

#### 习题 18.3(中等)

下面 unsafe impl 错在哪?

```rust
struct MyRefCell<T> {
    value: UnsafeCell<T>,
}

unsafe impl<T> Sync for MyRefCell<T> {}
```

#### 习题 18.4(困难)

把 18.9 的 MyVec 扩展:加 `iter` 方法返回迭代器(`MyVec::iter` -> `Iter<'_, T>`)。要求生命周期正确,Miri 通过。

#### 习题 18.5(开放)

读 Rustonomicon(`https://doc.rust-lang.org/nomicon/`)的"Implementing Vec"章节,跟你 18.9 的实现对比,找出你遗漏的细节。

---

### 下一章预告

Ch 19 处理 unsafe 的一个具体战场:FFI 与跨语言。extern C、bindgen、PyO3——你 AI 工程师的工作里这块特别重要。

---

> **本章一句话总结**
>
> Safe Rust 是语言契约,Unsafe Rust 是程序员契约。每写一行 unsafe,你向编译器承诺一件事。承诺错误是 UB,Miri 是你最好的朋友。
