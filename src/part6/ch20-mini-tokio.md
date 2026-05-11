# Ch 20 · Capstone:从零实现 Mini-Tokio

> 把全书概念串起来,写一个能跑的异步 runtime

**核心问题**:看完这本书,你能不能给 Tokio 提 PR?可以,从 issue tracker 找 good first issue 开始。

> ⚠️ **本章正文待补。** 以下是章节骨架,完整原文(从对话历史看应在你本地)覆盖进来即可。

---

## 章节结构

### 20.1 · 设计目标

- 支持 spawn / await / timer / channel

### 20.2 · 数据结构

- Task queue / Reactor / Waker

### 20.3 · step 1:单线程 executor + block_on

### 20.4 · step 2:支持 spawn 与并发 task

### 20.5 · step 3:实现 Sleep Future 与 timer wheel

### 20.6 · step 4:实现 channel

### 20.7 · step 5:多线程 work-stealing scheduler

### 20.8 · 与真 Tokio 对比

- 你做了哪些简化,真 Tokio 多了什么

---

## 习题

> 毕业作品:把 mini-tokio 跑通,然后给真 Tokio 提一个文档 PR

---

> **本章一句话总结**
>
> 走完这章,你就走完了从 GC 语言到 Rust 内部的全程。剩下的是日复一日的工程实践。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
