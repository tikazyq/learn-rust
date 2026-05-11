# Ch 12 · async/await 基础:Future、Pin、Waker

> Rust 异步模型的内部机制

**核心问题**:Rust 的 Future 跟 C# 的 Task 哪里不一样?为什么需要 Pin?

> ⚠️ **本章正文待补。** 以下是章节骨架,完整原文(从对话历史看应在你本地)覆盖进来即可。

---

## 章节结构

### 12.1 · Future trait 定义

- poll() 的签名与契约
- Poll::Ready / Poll::Pending

### 12.2 · async fn 是编译器生成的状态机

- 逐步展示编译产物

### 12.3 · 为什么 Rust Future 是 lazy 的

- 跟 C# Task 的 hot 模式对比

### 12.4 · .await 的解糖

- 让出控制权 + 注册 waker

### 12.5 · Pin 解决的真问题

- self-referential struct 的内存安全

### 12.6 · Waker 与 Context

- 谁来通知 Future 可以再次 poll

### 12.7 · 手撸最简 executor

- 50 行 Rust 跑通一个能 spawn 的 executor

### 12.8 · 为什么 Rust 选择'无运行时 by default'

---

## 习题

> 习题:实现一个 Sleep Future 与配套的 timer wheel(简化版)

---

> **本章一句话总结**
>
> Rust async 不是 magic——它是编译器把 async fn 翻译成状态机,加上一组接口契约(Future / Waker / Context)。理解这个,Tokio 内部就不再神秘。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
