# Ch 11 · 线程与 Send/Sync

> Fearless concurrency 的真实含义

**核心问题**:Send 和 Sync 这两个 marker trait 是如何在编译期阻止 data race 的?

> ⚠️ **本章正文待补。** 以下是章节骨架,完整原文(从对话历史看应在你本地)覆盖进来即可。

---

## 章节结构

### 11.1 · std::thread::spawn 与 JoinHandle

- move closure 的必要性

### 11.2 · Send:类型可以被转移到另一个线程

- 哪些类型不是 Send(Rc / RefCell / raw pointer)

### 11.3 · Sync:类型的 &T 可以被多个线程共享

- Send 与 Sync 的关系
- auto trait

### 11.4 · std::sync::mpsc 与 Arc<Mutex>

- 经典共享状态模式

### 11.5 · crossbeam 的 scoped threads

- 借用栈数据的并发

### 11.6 · 共享内存 vs message passing

- Rust 哲学的取向
- Go 'share by communicating' 的呼应

### 11.7 · 实战:并发目录扫描器

- work-stealing 模式

---

## 习题

> ⚠️ 习题待补。

---

> **本章一句话总结**
>
> Send + Sync 是 Rust 敢叫 'fearless concurrency' 的根本原因——data race 这一整类 bug 在编译期就被堵死了。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
