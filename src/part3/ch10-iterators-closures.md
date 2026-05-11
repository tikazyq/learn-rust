# Ch 10 · Iterator 与闭包

> Rust 函数式编程的两大支柱

**核心问题**:为什么 Rust 的 iterator 是零成本抽象?三种 Fn trait 到底有什么差别?

> ⚠️ **本章正文待补。** 以下是章节骨架,完整原文(从对话历史看应在你本地)覆盖进来即可。

---

## 章节结构

### 10.1 · Iterator trait 的真实定义

- next() -> Option<Item>
- 懒求值的工程意义

### 10.2 · Iterator adapter 全家桶

- map / filter / fold / collect / zip / chain / flat_map / scan

### 10.3 · Iterator 是零成本抽象的证据

- 看 LLVM IR / 汇编
- 与等价 for 循环对比

### 10.4 · Fn / FnMut / FnOnce 三种 closure trait

- 捕获模式与调用次数的关系

### 10.5 · move closure 与所有权

- 什么时候必须 move

### 10.6 · 实战:用 iterator 链替代命令式循环

---

## 习题

> 习题:把一段 Go 循环代码改写成 Rust iterator 链,对比可读性和性能

---

> **本章一句话总结**
>
> Iterator 是 Rust 把函数式抽象做成零成本的关键设计。掌握它,你能写出比 Go 更简洁同时同样快的代码。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
