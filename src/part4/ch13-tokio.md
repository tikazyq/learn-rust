# Ch 13 · Tokio 生产实战

> 从能跑到能上生产

**核心问题**:Tokio 的 scheduler 和 driver 是怎么工作的?生产中的常见陷阱有哪些?

> ⚠️ **本章正文待补。** 以下是章节骨架,完整原文(从对话历史看应在你本地)覆盖进来即可。

---

## 章节结构

### 13.1 · Tokio runtime 架构

- scheduler / driver / blocking pool

### 13.2 · tokio::spawn vs spawn_blocking

- CPU-bound 任务的处理

### 13.3 · tokio::sync 全家桶

- mpsc / oneshot / broadcast / watch / Notify / Mutex / RwLock / Semaphore

### 13.4 · select! 宏与 cancellation

- cancel safety 的概念

### 13.5 · Drop 在 async 里的陷阱

- 资源清理的正确做法

### 13.6 · tokio::time::sleep vs std::thread::sleep

- 在 async 上下文的灾难性差异

### 13.7 · Structured concurrency

- JoinSet / TaskTracker

### 13.8 · 性能调优

- worker thread 数量 / task 粒度 / CPU vs IO

### 13.9 · tokio-console 实战调试

---

## 习题

> 习题:给一个真实项目的 Control Plane 加一个带 cancellation 的健康检查 task

---

> **本章一句话总结**
>
> Tokio 是 Rust 生产 async 的事实标准。掌握它的内部不是炫技,是上生产之前的必修课。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
