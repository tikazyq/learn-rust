# Ch 15 · Web 服务:Axum + sqlx + tracing

> 现代 Rust 生产级 HTTP 服务栈

**核心问题**:怎么用 Rust 写一个媲美 Go gin / C# ASP.NET Core 的生产级 HTTP 服务?

> ⚠️ **本章正文待补。** 以下是章节骨架,完整原文(从对话历史看应在你本地)覆盖进来即可。

---

## 章节结构

### 15.1 · Axum 设计哲学

- 基于 tower::Service 的中间件

### 15.2 · Handler / Extractor / IntoResponse 契约

### 15.3 · tower::Layer / tower::Service

- 中间件详解

### 15.4 · 状态共享

- State<Arc<AppState>> 标准模式

### 15.5 · sqlx 编译期检查

- query! 宏与 schema 的对接

### 15.6 · 连接池配置

- AnyPool 的工作原理

### 15.7 · tracing 结构化日志

- span / event / subscriber 模型

### 15.8 · OpenTelemetry 集成

### 15.9 · 错误处理

- 从 Result 到 HTTP response 的优雅链路

### 15.10 · 优雅关闭

- graceful shutdown 的正确实现

---

## 习题

> 习题:写一个带 JWT 鉴权 + 数据库 + 结构化日志的 REST 服务

---

> **本章一句话总结**
>
> Axum + sqlx + tracing 是 2026 年写 Rust web 服务的事实组合。掌握这三个,你能上生产。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
