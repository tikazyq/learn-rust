# Ch 18 · Unsafe Rust —— Rustonomicon 速成

> "向编译器承诺以下不变量"

**核心问题**:unsafe 到底关掉了什么?程序员需要承诺什么?

`unsafe` 是 Rust 最被误解的关键字。常见误解:"unsafe 关掉了所有安全检查"。真相是:**它只关掉一小部分检查,但要求你手动承诺一组不变量**。绝大多数 Rust 工程师不应该写 unsafe;但每个 Rust 工程师都应该**读懂** unsafe,因为标准库、Tokio、SmallVec、Bytes 等基础库都在用它。

读完你应该能:

1. 说出 unsafe 能做的五件事
2. 解释 Stacked Borrows 模型简化版
3. 列出 10 种 UB,并知道为什么"看起来没事"也可能是 UB
4. 用 Miri 验证 unsafe 代码
5. 写一个简单的 unsafe 抽象(比如 ring buffer),并把 unsafety 包裹在安全 API 内

---

## 18.1 unsafe 能做的五件事

`unsafe` 在 Rust 里**只**多给你这五个能力:

1. **解引用裸指针** `*const T` / `*mut T`
2. **调用 unsafe 函数**(包括 FFI)
3. **访问 / 修改可变 static 变量**
4. **实现 unsafe trait**(如 `Send`, `Sync` 手写)
5. **访问 union 字段**

注意它**不**给你:

- 关掉借用检查 —— `&` 和 `&mut` 规则仍然成立
- 关掉类型检查 —— 类型仍要匹配
- 跳过 trait bound

`unsafe { }` 块**比初学者想的小得多**。

---

## 18.2 Aliasing 规则:Stacked Borrows / Tree Borrows

Rust 编译器假设:**任一时刻,要么有任意多个 `&T`,要么有恰好一个 `&mut T`**。这条 alias 规则即便在 unsafe 里也得守。违反 → UB。

### Stacked Borrows 模型(简化)

每个内存位置内部有一个"borrow stack"。每次创建引用,push 一个 tag 上栈;访问该位置时,该位置上的 tag 必须在栈中。访问破坏栈结构 → UB。

实战要点:

- 写 `&mut x` 之后,**所有先前由 x 派生的 `&` 都失效**(包括裸指针!)
- 裸指针 `as *const _` / `as *mut _` 时,只有"最近一次创建"的那条链上的指针有效

### 反例

```rust,ignore
unsafe {
    let mut x = 0u8;
    let p = &mut x as *mut u8;     // 创建 mutable raw ptr
    let q = &mut x as *mut u8;     // 再创建一个 —— p 失效
    *p = 1;                         // ❌ UB,虽然编译过
    *q = 2;
}
```

代码看着像无害,但 Stacked Borrows 视角下是 UB,优化器可能据此把 `*p = 1` 整段删掉。

### Tree Borrows

Rust 团队在研发更宽松的模型 Tree Borrows,允许更多看起来合理但 Stacked Borrows 拒绝的模式。**实践中目前以 Stacked Borrows 为准**(Miri 默认是它)。

---

## 18.3 UB(未定义行为)清单

unsafe 代码里你必须避免的事(部分,完整看 Rustonomicon):

1. **悬空指针解引用** —— 指向已 drop / 已 free 的位置
2. **未对齐访问** —— 解引用 misaligned pointer
3. **野指针 / null 解引用**(裸指针)
4. **违反 aliasing 规则**(见上)
5. **数据竞争** —— 两线程同时无同步访问同一可变位置
6. **读取未初始化内存**
7. **整数溢出**(`unchecked_add` 等;safe 默认是 wrap 或 panic)
8. **错误的转换** —— `&u32` cast 到 `&u64` 然后读取
9. **不变量违反** —— `bool` 里塞 2、`enum` 里塞非法 discriminant、`char` 塞代理对
10. **panic 跨 FFI 边界**
11. **错误的生命周期** —— 用 `transmute` 延长生命周期
12. **不为 Send 的类型跨线程**(手写 `unsafe impl Send`)
13. **错误地 mem::transmute** —— size/align/语义不对

UB 不是"会崩溃"的同义词——很多 UB **看起来运行良好**,直到优化器 / 不同硬件 / 不同 rustc 版本下崩溃。**别相信"我跑过没事"**。

---

## 18.4 `UnsafeCell` 的真实含义

```rust,ignore
struct UnsafeCell<T> { value: T }
```

为什么必须有这个类型?因为 Rust 编译器**假定** `&T` 是 immutable,可以做积极优化(缓存到寄存器、常量折叠)。

`UnsafeCell<T>` **告诉编译器**"这个位置可能被并发修改,不能假设它不变"。**唯一能 legally 从 `&T` 取 `*mut T` 的类型**就是 `UnsafeCell<T>`。

所有内部可变性(`Cell`, `RefCell`, `Mutex`, `AtomicXxx`)都基于 `UnsafeCell`。

---

## 18.5 Lifetime variance(回顾 Ch 7)

unsafe 代码里 variance 错误是常见 unsoundness 来源:

```rust,ignore
struct WrongPtr<'a, T> {
    ptr: *mut T,
    _marker: PhantomData<&'a T>,   // ❌:Should it be &'a mut T?
}
```

如果你的 `WrongPtr<'a, T>` 实际上拿"独占可变"语义,但用 `PhantomData<&'a T>`(协变),编译器允许"短 lifetime 当长 lifetime 用",安全 API 就 unsound。

**经验**:写带生命周期参数的 unsafe 类型,先停下来画 variance 表。

---

## 18.6 写正确的 unsafe 代码的工程纪律

1. **把 unsafe 关在最小作用域里**
   - 不要把整个函数 `unsafe fn`;`unsafe` 块越短越好

2. **文档化 SAFETY 注释**
   ```rust,ignore
   // SAFETY: ptr 来自 Box::into_raw,刚刚分配,未被 free;
   //         且 buffer 长度满足 self.cap,所以 offset cap-1 仍在有效范围内。
   unsafe { ptr.add(self.cap - 1).write(value) }
   ```
   社区惯例:每个 unsafe 块 / unsafe fn 都要有 `SAFETY:` 注释,说明你为什么相信不变量成立

3. **暴露 safe API,unsafe 锁在内部**
   - 库用户用 `Vec::push` 不该见 unsafe;`push` 内部一堆 unsafe,但 `push` 本身是 safe fn,因为内部确保了不变量

4. **测试用 Miri**
   ```bash
   rustup install nightly
   rustup +nightly component add miri
   cargo +nightly miri test
   ```
   Miri 是 Rust 解释器,会检查 UB(stacked borrows、未初始化、悬空指针等)。**unsafe 代码的 CI 必跑 Miri**

5. **多人 review**
   - 内部规范:unsafe 修改需要至少 2 人 review

---

## 18.7 手动实现 Send / Sync

`Send` / `Sync` 是 auto trait —— 大部分时候不用你手写。但有些场景需要:

```rust,ignore
struct MyPool {
    inner: *mut PoolImpl,   // 裸指针,默认不 Send
}

// SAFETY: PoolImpl 内部用 Mutex 保护所有可变状态,可跨线程安全访问。
unsafe impl Send for MyPool {}
unsafe impl Sync for MyPool {}
```

危险:**你向编译器承诺这个类型是 thread-safe**。错了就是 data race,运行时崩。

**90% 的情况你不需要手写 Send/Sync**——如果你不知道为什么需要,就先别加。

---

## 18.8 Miri:Rust 的 UB 检测器

```bash
cargo +nightly miri test
```

Miri 会:

- 检测越界访问
- 检测未初始化读
- 检测 stacked borrows 违规
- 检测 misaligned access
- 检测数据竞争(实验性,加 `-Zmiri-num-cpus=N`)

代价:Miri 比正常执行慢 ~100x。**只跑小规模 unit test**,不能上集成测试。

### CI 集成示例

```yaml
- name: Miri
  run: |
    rustup toolchain install nightly --component miri
    cargo +nightly miri test --lib
```

---

## 18.9 案例分析:Vec::push 简化版

```rust,ignore
pub fn push(&mut self, value: T) {
    if self.len == self.cap {
        self.grow();   // 重分配,扩大 cap
    }
    unsafe {
        // SAFETY: self.len < self.cap(刚检查过或扩容后必满足);
        //         self.ptr.add(self.len) 在有效 allocation 范围内;
        //         该位置目前是未初始化(超出 len),可以 write 而不 drop 旧值
        std::ptr::write(self.ptr.add(self.len), value);
    }
    self.len += 1;
}
```

仔细看 SAFETY 注释 —— 它精确描述了三个不变量。任何一条破了都 UB。这是工业级 unsafe 代码的写法。

### 推荐继续阅读源码

- `Vec` 的 `push` / `pop` / `extend_from_slice`
- `Box::new`(为什么是 unsafe 内部)
- `Rc` 的 `clone` / `drop`(strong / weak count 的原子顺序)
- `Mutex`(OS mutex 的封装)

---

## 习题

1. 不用 Box / Vec 等,只用 `alloc` API + 裸指针,实现一个固定大小的 `RingBuffer<T>`。要求暴露 safe API。**用 Miri 跑测试。**
2. 故意构造一个 Stacked Borrows 违规(同时存在两个 raw mut ptr 指向同一位置),用 Miri 测出来。
3. 给某个支持自定义 hasher 的 HashMap-like 类型手写 `unsafe impl Send`,写出 SAFETY 注释。让其他人 review。
4. 读 `std::cell::Cell` 的源码,理解为什么它是 safe 抽象但内部全是 unsafe。
5. 写一篇 200 字"为什么 unsafe 不该 disable warnings"的内部文档,论证立场。

---

> **本章一句话总结**
>
> unsafe 不是"关掉安全检查",是"我向编译器承诺以下不变量"。读懂这个差别,unsafe 才能写得正确——大部分人不需要写它,但每个人都应该看得懂它。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
