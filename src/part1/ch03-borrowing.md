# Ch 3 · Borrowing 与 Lifetime —— 编译器是结对程序员

> "Lifetimes are the most distinctive feature of Rust. They're also the most misunderstood."

Ch 2 我们说 ownership 是"每个值有一个 owner,owner 出作用域时 drop"。这一章我们处理一个直接派生的问题:**如果某个函数想暂时使用一个值,但不想接管所有权,怎么办?**

答案是 **borrowing(借用)**。但借用不是免费的——为了保证安全,Rust 引入了一组借用规则,和一个叫 **lifetime** 的概念。

读完这章,你应该能:

1. 说清楚 `&T` 和 `&mut T` 为什么必须互斥
2. 看到 `'a` 标注时不再恐慌——你知道它在告诉编译器什么
3. 读懂 Rust 编译器最常见的 5 种借用报错
4. 给一个函数签名,判断它的生命周期标注是否合理
5. 知道 `'static` 的真实含义,不再误用

---

## 3.1 为什么需要借用?

先看一个看似无害的需求。我们有一个大 `Vec<String>`,想写个函数计算其中字符串的总长度:

```rust
fn total_length(strs: Vec<String>) -> usize {
    strs.iter().map(|s| s.len()).sum()
}

fn main() {
    let v = vec![
        String::from("hello"),
        String::from("world"),
    ];
    let n = total_length(v);
    println!("{}", n);
    // println!("{:?}", v);  // ❌ v 已经被 move 进 total_length
}
```

这个签名 `fn total_length(strs: Vec<String>)` 有问题——它接管了所有权。调用一次就消费一次,调用方再也用不了 `v` 了。

但语义上,`total_length` **只是想读一下**,根本不需要拥有这个 Vec。这正是借用要解决的事情:

```rust
fn total_length(strs: &Vec<String>) -> usize {
    strs.iter().map(|s| s.len()).sum()
}

fn main() {
    let v = vec![
        String::from("hello"),
        String::from("world"),
    ];
    let n = total_length(&v);
    println!("{}", n);
    println!("{:?}", v);  // ✅ v 还活着
}
```

`&Vec<String>` 是"借一下,不拿走"。调用方仍然拥有 `v`,函数只是临时看一眼。

> ⚠️ **本节剩余内容(借用的 mental model + 与 Go/C# 的对比)待补。**

---

## 3.2 借用的两条规则

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - 规则 1:任意时刻,要么多个 `&T`,要么一个 `&mut T`,二者互斥
> - 规则 2:任何引用必须在 owner 还活着的时候才有效
> - 这两条规则背后的工程动机:防 iterator invalidation、防 data race、防 dangling reference

---

## 3.3 Lifetime 标注:`'a` 到底告诉编译器什么

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - `'a` 不是给程序员看的,是给编译器看的
> - lifetime 是"这个引用必须比那个引用活得久"的约束语言
> - 大多数情况编译器自己推导(lifetime elision rules)
> - 什么时候必须手写

---

## 3.4 Lifetime Elision 三条规则

> ⚠️ **本节正文待补。**

---

## 3.5 五种最常见的借用报错

> ⚠️ **本节正文待补。** 这一节是这章最有工程价值的部分——把抽象的"借用规则"具体化成 debug 时真的能用上的模式识别清单。
>
> 应包含的五种典型报错:
>
> 1. `cannot borrow as mutable because it is also borrowed as immutable`
> 2. `borrowed value does not live long enough`
> 3. `cannot return reference to local variable`
> 4. `cannot move out of borrowed content`
> 5. `cannot borrow as mutable more than once at a time`
>
> 每种报错给:典型代码、编译器原话、解读、3 种修复方案。

---

## 3.6 `'static` 的真实含义

> ⚠️ **本节正文待补。**
>
> 关键澄清:`'static` 不是"程序结束才 drop",是"可以活到程序结束"。这两个差异很大。

---

## 3.7 Non-Lexical Lifetimes(NLL)

> ⚠️ **本节正文待补。**

---

## 3.8 实战:一个迭代器的借用陷阱

> ⚠️ **本节正文待补。**
>
> 实现一个简化版的 `WordIter`,演示借用检查器如何防止"边迭代边修改"的经典 bug。

---

## 3.9 习题

> ⚠️ **本节习题待补。**
>
> 建议包含一道"找出 5 个 `&` 引用各自的 lifetime 来源"的练习。

---

### 下一章预告

Ch 4 我们离开"内存"这个维度,进入"类型设计"。Rust 的 `enum` 不是 C 那种 enum,是真正的 sum type。配合 pattern matching,你能写出比 Go 简洁得多的领域模型代码。

---

> **本章一句话总结**
>
> 借用检查器不是路障,是结对程序员。它在你提交代码之前,把一类并发 bug、迭代失效、悬垂引用的问题都筛掉了。学会读它的报错,是学会 Rust 的关键转折。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
