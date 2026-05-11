# Ch 19 · FFI 与跨语言边界

> Rust 怎么跟 C / Python / JS / WASM 互操作

**核心问题**:Rust 和别的语言怎么互操作?每种边界各有什么坑?

> ⚠️ **本章正文待补。** 以下是章节骨架,完整原文(从对话历史看应在你本地)覆盖进来即可。

---

## 章节结构

### 19.1 · C ABI 基础

- extern "C" / #[repr(C)] / #[no_mangle]

### 19.2 · 调 C 库

- bindgen 自动生成 binding

### 19.3 · 暴露 Rust 给 C/C++

- cbindgen

### 19.4 · PyO3

- 暴露 Rust 给 Python(AI 工程价值大)

### 19.5 · napi-rs

- 暴露 Rust 给 Node.js

### 19.6 · WASM

- Rust 编译到浏览器

### 19.7 · FFI 安全检查清单

- lifetime 穿越边界
- panic 不能跨 FFI
- 错误码 vs 异常

### 19.8 · 真实案例

- ruff(Python linter)/ turbo(Vercel 构建工具)

---

## 习题

> 习题:用 PyO3 给 Python 暴露一个 Rust 计算密集函数

---

> **本章一句话总结**
>
> FFI 是 Rust 渗透到所有语言生态的能力。写得好的 Rust 库往往不是用 Rust 调用,是被 Python / Node / Web 调用。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
