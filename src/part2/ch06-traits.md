# Ch 6 · Trait —— 比 interface 多了什么

> "Traits are the closest thing Rust has to inheritance, and they're nothing like inheritance."

Go 有 interface,C# 有 interface,TS 有 interface。三种 interface 各不一样,但都是"一组方法签名的集合"。Rust 的 trait 远超过这个——它有 associated types、有 blanket impl、有 marker trait、有 object safety 规则、有静态/动态分发的明确区分。

这章是 Part II 的核心,也是这本书技术密度最高的章节之一。读完你应该能:

1. 解释 Rust trait 跟 Go interface、C# interface、Haskell typeclass 的根本差异
2. 选择正确的 trait 设计:associated type vs generic parameter
3. 判断一个 trait 能不能做 trait object,以及对象安全规则的工程含义
4. 选择 `dyn Trait` vs `impl Trait` vs `T: Trait`
5. 给一个领域模型设计一组合理的 trait

---

## 6.1 从 Go interface 到 Rust trait

### Go interface

```go
type Reader interface {
    Read(p []byte) (n int, err error)
}

type FileReader struct { ... }

func (f *FileReader) Read(p []byte) (n int, err error) { ... }

// FileReader 自动实现了 Reader,因为它有匹配的方法签名
// 这是 structural typing —— "看起来像鸭子"
```

Go interface 是 structural——任何带匹配方法的类型自动满足 interface,不需要显式声明。

### Rust trait

```rust
trait Reader {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, Error>;
}

struct FileReader { /* ... */ }

impl Reader for FileReader {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, Error> { /* ... */ }
}
```

Rust 是 nominal——必须**显式 `impl Trait for Type`** 才算实现。光是有匹配方法的类型不算实现 trait。

### 这个差异为什么重要?

Go structural typing 的好处:解耦灵活,你可以为已有类型隐式满足新 interface。

代价:**意图不清晰**。FileReader 实现 Reader 是巧合还是设计?Go 不区分。

Rust 的选择:**实现是设计决定,不是巧合**。`impl Reader for FileReader` 这一行明确表达"我就是要让 FileReader 当 Reader 用"。代价是写多一行,收益是意图明确。

更深一点:Rust 允许你**为已有类型实现你定义的 trait**,这是 Go interface 做不到的:

```rust
// 你定义的 trait
trait MyDescribe {
    fn describe(&self) -> String;
}

// 实现给 std 的 String
impl MyDescribe for String {
    fn describe(&self) -> String {
        format!("a string of length {}", self.len())
    }
}

// 现在 String 有 describe 方法了
let s = String::from("hello");
println!("{}", s.describe());
```

这叫 **extension** —— 给已有类型加新行为。Go 做不到(你不能给 std 类型加方法),C# 用 extension method 部分做到,Rust 用 trait 系统完整做到。

> ⚠️ **本节剩余内容(orphan rule + 与 Haskell typeclass 的关系)待补。**

---

## 6.2 Associated Type vs Generic Parameter

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - 两者的语法对比
> - 何时选哪个的工程判断(关键问题:一个类型实现这个 trait 时,这个类型参数能取多少种值?)
> - `Iterator::Item` 为什么是 associated type
> - 跟 C# generic interface 的对比

---

## 6.3 Default Method 与 Supertrait

> ⚠️ **本节正文待补。**

---

## 6.4 Blanket Impl

> ⚠️ **本节正文待补。**
>
> `impl<T: Display> ToString for T` 这种"为所有满足条件的类型实现这个 trait"的能力是 Go 完全没有的。这一节讲它的能力和工程意义。

---

## 6.5 Trait Object 与 Object Safety

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - `dyn Trait` 的实现机制(fat pointer = data + vtable)
> - object safety 规则:为什么有些 trait 不能做 trait object
> - 对象安全规则背后的工程动机
> - 解决方案:`Self: Sized` 约束、把违规方法做成 default method

---

## 6.6 静态分发 vs 动态分发

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - `impl Trait`(静态分发) vs `dyn Trait`(动态分发)
> - 性能差异:monomorphization vs vtable indirection
> - 代码体积差异
> - 何时选哪个的实际判断

---

## 6.7 Marker Trait:`Send` / `Sync` / `Copy` / `Sized`

> ⚠️ **本节正文待补。**

---

## 6.8 实战:为领域模型设计一组 trait

> ⚠️ **本节正文待补。**
>
> 用 Onsager 的 Artifact 模型为例,设计 `Artifact` / `Persistable` / `Versionable` / `Verifiable` 等一组 trait,演示 trait 拆分与组合。

---

## 6.9 习题

### 习题 6.5(开放)

回顾你写的 Go interface 或 C# interface。挑一个,试着用 Rust trait 重新设计:

- 哪些 method 该是 default method?
- 是否应该用 supertrait 拆分关注点?
- 该用 associated type 还是 generic parameter?
- 是否需要保留 object safety?

不需要敲代码。设计本身的练习更有价值。

---

### 下一章预告

Ch 7 处理 trait 的双胞胎:**泛型与生命周期的进阶**。

我们会讲 monomorphization 的实际成本、where 子句的复杂用法、variance(协变/逆变)、HRTB(higher-ranked trait bounds)、GAT(generic associated types)。这些是 Rust 类型系统最深的部分,读懂之后你能看懂 stdlib 里几乎任何 trait 设计。

---

> **本章一句话总结**
>
> Trait 不是 interface 的复刻。它是 Haskell typeclass 的近亲,带着 nominal typing、associated types、blanket impl、object safety 等一组特性,共同构成 Rust 抽象表达力的基础。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
