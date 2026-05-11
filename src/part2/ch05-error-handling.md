# Ch 5 · 错误处理工程化 —— Result、`?`、thiserror、anyhow

> "Errors are not exceptions. They are values."

Go 和 Rust 在错误处理上有一个共识:**错误是值,不是异常**。但 Rust 把这个理念推得更远——`Result<T, E>` 是类型系统强制的,`?` 让传播零成本,`thiserror` + `anyhow` 让错误层次化设计变得自然。

这章你不会学到"如何写更多 try/catch",你会学到**如何用类型系统设计错误层次**。

读完这章,你应该能:

1. 区分什么时候用 `panic!`,什么时候用 `Result`
2. 设计一个错误类型层次(`thiserror`),让上层调用方能精确处理也能粗略包装
3. 在应用层用 `anyhow` 简化错误传播,在库层用 `thiserror` 精确建模
4. 把 `Result` 优雅地映射到 HTTP response / CLI exit code / 日志
5. 看出别人代码里"错误处理设计不当"的味道

---

## 5.1 错误处理的两条路:返回 vs panic

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - `panic!`:不变量被打破,继续运行没意义
> - `Result`:预期会发生的错误,调用方需要处理
> - 边界情况:`unwrap()` / `expect()` 的何时合理
> - 跟 Go err / Java exception / C# exception 的对比

---

## 5.2 `Result<T, E>` 与 `?` 操作符

> ⚠️ **本节正文待补。**
>
> 关键点:`?` 不仅"提前返回",它还**做 `From` trait 转换**。理解这一层,后面层次化错误才能设计好。

---

## 5.3 用 `thiserror` 设计库的错误类型

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - `#[derive(Error)]` 的工作机制
> - `#[error("...")]` 与 `#[from]`
> - 透传 + 包装的设计选择
> - 为什么库应该用 `thiserror` 而不是 `anyhow`

---

## 5.4 用 `anyhow` 简化应用层错误

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - `anyhow::Error` 的特性:统一类型 + context 链
> - `.context()` / `.with_context()` 的妙用
> - 跟 Go 的 `fmt.Errorf("...: %w", err)` 对比
> - 为什么应用应该用 `anyhow` 而不是 `thiserror`

---

## 5.5 错误层次化设计

> ⚠️ **本节正文待补。**
>
> 应包含一个三层错误结构的真实例子:
>
> - 底层:数据库错误、IO 错误等(`thiserror` 细分)
> - 中层:领域错误(`SessionError`、`ArtifactError`,包装底层错误)
> - 顶层:应用错误(`anyhow::Error`,带 context)
>
> 跟 HTTP layer / Axum IntoResponse 集成。

---

## 5.6 实战:从 Stiglab 真实场景设计错误

> ⚠️ **本节正文待补。**

---

## 5.7 习题

### 习题 5.4(困难,工程)

回到你的项目。找你模块里所有 `Result<T, E>` 返回的函数,分类:

- 哪些 E 应该是 `thiserror` 细分?
- 哪些可以是 `anyhow::Error`?
- 哪些其实应该是 `panic`?(不变量错误)

这个分类不需要 100% 精确,目的是建立"什么场景用什么错误"的判断习惯。

### 习题 5.5(开放)

回顾你写过的 Go/TS/C# 代码。找一段错误处理特别啰嗦或特别松散的——比如 catch-all 的 try/catch、或一堆 `if err != nil { return err }`。

如果用 Rust 重写,错误层次怎么设计?是不是有些原本被吞掉的错误会被显式化?是不是有些重复的错误代码可以消失?

---

### 下一章预告

Ch 6 我们进入 Rust 类型系统的核心:**trait**。

trait 不是 Go interface 的复刻,也不是 C# interface 的翻版。它有自己的设计——associated types、blanket impl、object safety、static vs dynamic dispatch——这些一起让 Rust 的抽象表达力比 Go 高一个量级。

---

> **本章一句话总结**
>
> 错误处理不是负担,是契约。`Result` 让函数告诉调用方"我可能失败",`?` 让传播零成本,`thiserror` + `anyhow` 让你按层次设计错误而不被语法淹没。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
