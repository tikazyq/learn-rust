# Ch 18 · Unsafe Rust —— Rustonomicon 速成

> 向编译器承诺以下不变量

**核心问题**:unsafe 到底关掉了什么?程序员需要承诺什么?

> ⚠️ **本章正文待补。** 以下是章节骨架,完整原文(从对话历史看应在你本地)覆盖进来即可。

---

## 章节结构

### 18.1 · unsafe 能做的五件事

- 解引用裸指针
- 调用 unsafe 函数
- 访问/修改可变 static
- 实现 unsafe trait
- 访问 union 字段

### 18.2 · Aliasing 规则

- Stacked Borrows / Tree Borrows 模型简介

### 18.3 · Undefined Behavior 清单

- 你必须避免的事情

### 18.4 · UnsafeCell 的真实含义

- 为什么 &T 不一定不可变

### 18.5 · Lifetime variance

- 协变 / 逆变 / 不变
- PhantomData 的必要性

### 18.6 · 写正确的 unsafe 代码

- 封装边界 / 不变量文档 / 调用方契约

### 18.7 · 手动实现 Send / Sync

- 危险与必要

### 18.8 · Miri

- Rust 的 UB 检测器
- 如何纳入 CI

### 18.9 · 案例分析

- Vec::push / Box::new / Rc::clone 的源码

---

## 习题

> 习题:实现一个 unsafe 但正确的 ring buffer,用 Miri 验证

---

> **本章一句话总结**
>
> unsafe 不是'关掉安全检查',是'我向编译器承诺以下不变量'。读懂这个差别,unsafe 才能写得正确。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
