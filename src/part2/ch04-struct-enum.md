# Ch 4 · Struct、Enum、Pattern Matching —— 用类型表达领域

> "Make illegal states unrepresentable."
> — Yaron Minsky

Part I 我们处理了内存维度——所有权、借用、生命周期。Part II 我们换一个视角:**类型系统作为领域建模工具**。

读完这章你应该能:

1. 用 enum 替代 Go 的 `interface{}` + type switch 模式
2. 理解为什么 Rust 的 pattern matching 是穷尽性检查的——这等于编译器替你写测试
3. 设计 newtype 来避免"全是 String 和 u64"的类型贫血代码
4. 把一个状态机从"struct + status enum"风格,重构成"enum 即状态"风格

---

## 4.1 Struct 三种形式

Rust 的 struct 有三种形式,各有用途。

### 命名字段 struct(最常见)

```rust
struct User {
    name: String,
    email: String,
    active: bool,
}

let u = User {
    name: String::from("Marvin"),
    email: String::from("m@hp.com"),
    active: true,
};
```

跟 Go 的 struct、C# 的 record 用法相似。

### Tuple struct

```rust
struct Point(f64, f64);

let p = Point(1.0, 2.0);
println!("{}, {}", p.0, p.1);
```

> ⚠️ **本节剩余内容(unit struct + 三种形式的工程选用)待补。**

---

## 4.2 Newtype 模式

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - 用 `struct UserId(u64)` 替代裸 `u64` 的工程动机
> - 编译期防"参数类型对但语义错"的 bug
> - 跟 TS branded types / C# strongly-typed id 的对比
> - 性能:零成本(`#[repr(transparent)]`)

---

## 4.3 Enum 不只是枚举

> ⚠️ **本节正文待补。**
>
> 关键论点:Rust 的 enum 是 **sum type / tagged union**,跟 C/Java/Go 的 enum(只是命名的整数)完全不同。
>
> 应包含:
>
> - 带数据的 enum 变体
> - 用 enum 替代 OO 多态的实际模式
> - 跟 TS discriminated union、Haskell ADT 的对照

---

## 4.4 Pattern Matching:编译器替你写测试

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - `match` 的穷尽性检查
> - 各种 pattern:literal / range / struct destructure / enum / `_` / `if guard`
> - `if let` / `let else` / `while let` 简写
> - 跟 Go switch、C# switch expression 的对比

---

## 4.5 Option<T> 与 Result<T, E>:语言级 sum type

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - `Option<T>` 的定义与用法,为什么 Rust 没有 null
> - `Result<T, E>` 的定义,为什么 Rust 没有 exception
> - `?` 操作符的真实含义(`From` trait 链路)
> - 常用 combinator:`map` / `and_then` / `unwrap_or` / `ok_or`

---

## 4.6 实战:重新设计 Session 状态机

> ⚠️ **本节正文待补。** 这是本章最有工程价值的部分——演示两种状态机风格的对比。
>
> **风格 A · struct + status 字段**:
>
> ```rust
> enum SessionState { Created, Running, Finished, Failed }
>
> struct Session {
>     id: SessionId,
>     state: SessionState,
>     started_at: Option<Instant>,
>     finished_at: Option<Instant>,
>     result: Option<SessionResult>,
>     error: Option<SessionError>,
>     // ... 一堆 Option,因为各状态用不到的字段都得是 Option
> }
> ```
>
> 问题:很多 `Option` 字段,状态与字段的对应关系靠注释维护,容易出现"Finished 状态但 finished_at 是 None"的非法状态。
>
> **风格 B · enum 即状态**:
>
> ```rust
> enum SessionState {
>     Created { config: Config },
>     Running { config: Config, started_at: Instant },
>     Finished { config: Config, started_at: Instant, finished_at: Instant, result: SessionResult },
>     Failed { config: Config, started_at: Option<Instant>, error: SessionError },
> }
>
> struct Session {
>     id: SessionId,
>     state: SessionState,
> }
> ```
>
> 每个状态变体只包含该状态有效的字段。非法状态在类型层面就不可表达。
>
> **风格 C · typestate(每个状态是不同类型)**:进一步把状态推到类型系统,转换函数消费旧状态返回新状态,编译器保证只能从合法状态出发调用合法方法。

---

## 4.7 状态转换:`fn start(self) -> Result<Self, Self>`

> ⚠️ **本节正文待补。**
>
> 演示用所有权语义保证状态机正确性:转换函数**消费 self**(`self` 不是 `&self`),意味着调用一次,旧状态就不存在了。这跟 Go 的 `s.Start()` 完全不同——Go 里旧的 Session 对象仍然可访问,容易产生"已经 start 的 session 又被 start 一次"的 bug。
>
> 完整代码示例(从对话历史恢复):
>
> ```rust
> impl Session {
>     pub fn start(self) -> Result<Self, Self> {
>         match self.state {
>             SessionState::Created { config } => Ok(Session {
>                 id: self.id,
>                 state: SessionState::Running {
>                     config,
>                     started_at: Instant::now(),
>                 },
>             }),
>             other => Err(Session { id: self.id, state: other }),
>             // 不在 Created 状态,无法 start,返回原样
>         }
>     }
>
>     pub fn finish(self, result: SessionResult) -> Result<Self, Self> {
>         match self.state {
>             SessionState::Running { config, started_at } => Ok(Session {
>                 id: self.id,
>                 state: SessionState::Finished {
>                     config,
>                     started_at,
>                     finished_at: Instant::now(),
>                     result,
>                 },
>             }),
>             other => Err(Session { id: self.id, state: other }),
>         }
>     }
> }
> ```

---

## 4.8 习题

> ⚠️ **本节习题待补。**

---

> **本章一句话总结**
>
> Rust 的 struct + enum + pattern matching 不只是语法糖——它是 Yaron Minsky 那句 "make illegal states unrepresentable" 的工程实现。学会用类型表达领域,你的 bug 在编译期就死掉一大半。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
