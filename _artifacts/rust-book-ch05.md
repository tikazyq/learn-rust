# 第 5 章 · 错误处理 —— Result、? 与工程实践

> "Errors are values."
> — Rob Pike(关于 Go,但 Rust 走得更远)

Go 的 `if err != nil` 仪式感强但啰嗦。C# 的 try/catch 隐藏控制流。Java 的 checked exception 让人想哭。Rust 的选择:**错误是值,但语法不啰嗦**。

读完这章你应该能:

1. 解释 Rust 为什么没有 exception,以及这选择的工程含义
2. 用 `?` 操作符写出比 Go 短得多的错误处理代码
3. 给一个项目设计错误层次:库用 `thiserror`、应用用 `anyhow`,知道为什么
4. 决定什么时候该 panic、什么时候该返回 Result
5. 把 Stiglab 一个模块的错误层次做一次重设计

---

## 5.1 Rust 为什么没有 exception?

C++、Java、C#、Python、JS 都有 exception。Rust 没有。这是有意识的设计选择,不是疏忽。

### Exception 的隐藏成本

考虑 C# 代码:

```csharp
public User LoadUser(int id) {
    var conn = OpenConnection();
    var data = conn.Query($"SELECT * FROM users WHERE id={id}");
    return ParseUser(data);
}
```

这函数能抛多少种异常?

- `OpenConnection`:`SqlException` / `TimeoutException` / `IOException` / ...
- `Query`:同上,加 `SqlException` 的子类一堆
- `ParseUser`:`FormatException` / `NullReferenceException` / ...

调用方不看实现就不知道。文档可能写,可能没写,可能过期。每个异常都是一条**隐藏的控制流路径**——你的代码可能在任何 `.Method()` 调用处突然跳到上层 catch。

### Rust 的选择:错误显式化

Rust 强制你**用类型表达错误的可能性**。一个可能失败的函数,签名上必须写出来:

```rust
fn load_user(id: UserId) -> Result<User, LoadUserError> { ... }
```

调用方一看签名就知道这函数会失败,且**只可能用 `LoadUserError` 这一种方式失败**。没有隐藏控制流,没有未声明的异常。

### `Result<T, E>` 是普通 enum

回顾 Ch 4:

```rust
enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

没有特殊性。它就是个 enum。你可以 match 它、可以 map 它、可以放进 Vec、可以序列化——**它是值,不是控制流装置**。

### 工程含义对比

| 维度 | C# / Java exception | Go error | Rust Result |
|---|---|---|---|
| 函数签名是否声明可能错误 | ❌(checked exception 除外) | ✅ | ✅ |
| 调用方是否被强制处理 | ❌(可以不 catch) | ❌(可以忽略 err) | ✅(必须处理 Result,unwrap 也算) |
| 错误是值还是控制流 | 控制流 | 值 | 值 |
| 性能:成功路径 | 快 | 快 | 快(零成本) |
| 性能:失败路径 | 慢(stack unwinding) | 快 | 快(就是返回值) |
| 错误传播语法 | 自动(冒泡) | 啰嗦 | `?` 简洁 |

Rust 拿到了 Go 的"显式"+ C# 的"语法不啰嗦"——`?` 操作符是关键。

---

## 5.2 `?` 操作符:Rust 错误处理的核心语法

Go 错误处理的标志性代码:

```go
data, err := fetch()
if err != nil {
    return nil, err
}
parsed, err := parse(data)
if err != nil {
    return nil, err
}
result, err := process(parsed)
if err != nil {
    return nil, err
}
return result, nil
```

Rust 等价代码:

```rust
fn pipeline() -> Result<Result, MyError> {
    let data = fetch()?;
    let parsed = parse(data)?;
    let result = process(parsed)?;
    Ok(result)
}
```

`?` 在做的事情:

```rust
let data = fetch()?;
// 等价于
let data = match fetch() {
    Ok(v) => v,
    Err(e) => return Err(From::from(e)),
};
```

如果 `fetch()` 返回 `Ok(v)`,`?` 取出 `v` 继续;如果返回 `Err(e)`,`?` 把 `e` 转换成函数的错误类型,提前 return。

**关键细节**:`?` 调用了 `From::from(e)`——所以函数的错误类型 `E` 不需要跟 `fetch` 返回的错误类型完全一致,只要存在 `From<FetchError> for E` 的实现即可。这个细节是构造错误层次的基石。

### `?` 也能用在 Option

```rust
fn first_two_chars(s: &str) -> Option<(char, char)> {
    let mut chars = s.chars();
    let a = chars.next()?;  // Option 是 None 就提前返回 None
    let b = chars.next()?;
    Some((a, b))
}
```

`?` 在 `Option` 上的语义跟在 `Result` 上一样——None 提前返回 None。

### `?` 不能跨边界

`?` 要求函数返回类型跟使用 `?` 的表达式兼容。**在返回 `()` 的函数(包括 `main`)里直接用 `?` 编译不过**。

修复方式:`main` 函数也可以返回 `Result`:

```rust
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let data = std::fs::read_to_string("config.toml")?;
    println!("{}", data);
    Ok(())
}
```

这是写 CLI 工具时的标准 `main` 签名。

---

## 5.3 错误层次设计:`thiserror` vs `anyhow`

实际项目里你不会只用一种错误类型。你需要**为不同层次设计不同错误类型**。

### 一个典型的错误层次

考虑你 Stiglab Control Plane 的某个模块:

```
HTTP handler 层:把错误转成 HTTP response
        ▲
        │ uses
        │
service 层:业务逻辑,可能调用多个 repository
        ▲
        │ uses
        │
repository 层:跟数据库交互
        ▲
        │ uses
        │
sqlx 库:返回 sqlx::Error
```

每一层的错误类型应该不同——repository 关心"数据库连接超时",service 关心"用户不存在",handler 关心"返回什么 HTTP status code"。

### `thiserror`:为库定义错误类型

`thiserror` 是个 derive macro,帮你简洁地定义错误 enum:

```rust
use thiserror::Error;

#[derive(Error, Debug)]
pub enum SessionError {
    #[error("session {0} not found")]
    NotFound(SessionId),

    #[error("session {0} is in invalid state: {1}")]
    InvalidState(SessionId, String),

    #[error("database error")]
    Database(#[from] sqlx::Error),

    #[error("config parse error")]
    Config(#[from] toml::de::Error),
}
```

它做的事情:
1. 自动 `impl Display for SessionError`(用 `#[error("...")]` 的字符串格式化)
2. 自动 `impl std::error::Error for SessionError`
3. `#[from]` 标记自动生成 `impl From<sqlx::Error> for SessionError`

`#[from]` 那行让 `?` 操作符自动工作——你的代码里 `pool.fetch_one(...).await?` 直接把 `sqlx::Error` 转成 `SessionError::Database`。

### `anyhow`:为应用做粗粒度错误

应用层(尤其是 main 函数、handler、CLI)经常不需要细分错误——你只关心"出错了,把错误打印或返回"。这种场景下 `anyhow` 更合适:

```rust
use anyhow::{Result, Context};

fn load_config(path: &str) -> Result<Config> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read {}", path))?;
    let config: Config = toml::from_str(&content)
        .context("failed to parse config")?;
    Ok(config)
}

fn main() -> Result<()> {
    let config = load_config("config.toml")?;
    println!("{:?}", config);
    Ok(())
}
```

`anyhow::Result<T>` 是 `Result<T, anyhow::Error>` 的别名。`anyhow::Error` 是个万能错误类型,可以从任何实现了 `std::error::Error` 的类型构造。

`with_context` / `context` 是 `anyhow` 的妙处——**给错误链添加上下文**:

```
Error: failed to read config.toml

Caused by:
    0: No such file or directory (os error 2)
```

这种链式错误信息,用 `thiserror` 也能做但麻烦,`anyhow` 是开箱即用。

### 分工原则

| 场景 | 用什么 | 为什么 |
|---|---|---|
| 库 / 公共 API | `thiserror` | 调用方需要 match 具体错误类型来决定行为 |
| 应用 / CLI / handler | `anyhow` | 调用方只关心成功失败,不细分错误类型 |
| 大型应用的服务层 | `thiserror`(细分) | 上层 handler 需要根据错误类型决定 HTTP 响应 |
| Quick prototype | `anyhow` 或 `Box<dyn Error>` | 还没想清楚错误层次,先跑起来 |

### 反模式:Box<dyn Error> 一把梭

```rust
fn whatever() -> Result<(), Box<dyn std::error::Error>> { ... }
```

`Box<dyn Error>` 能装下任何错误,但你失去了所有类型信息——调用方没法 match 来区别处理。

**临时代码可以**,生产 API 不要。要么用 `thiserror` 细分,要么用 `anyhow` 也比 `Box<dyn Error>` 好(`anyhow` 至少有 context、有 backtrace)。

---

## 5.4 panic vs Result:边界在哪里

什么时候用 `Result` 让调用方处理,什么时候直接 `panic!()` 让程序崩?

### Panic 的语义

`panic!()` 不是错误——它是**程序逻辑错误的信号**。意思是:"出现了不应该出现的状态,我没法继续,程序应该停止"。

默认行为是 unwinding(栈展开,所有 Drop 被调用,然后线程退出)。可以配置 `panic = "abort"`(直接终止)。

### 应该 panic 的场景

✅ **不变量被破坏**:进入了"理论上不可能"的代码路径

```rust
fn process(state: &State) {
    match state.kind {
        Kind::A => { /* ... */ }
        Kind::B => { /* ... */ }
        // 假如 state.kind 只能是 A 或 B,且这是不变量
        _ => unreachable!("invalid state kind: {:?}", state.kind),
    }
}
```

`unreachable!()` 是带语义的 panic,告诉读者"这里逻辑上不可能到达"。

✅ **测试代码、prototype**:`unwrap()`、`expect()` 用得理所当然

```rust
#[test]
fn test_parse() {
    let result = parse("hello").unwrap();  // 测试里 unwrap 没问题
    assert_eq!(result, "hello");
}
```

✅ **早期开发,先跑起来**:后期再细化错误处理

### 不应该 panic 的场景

❌ **任何 IO、网络、用户输入**:这些"会失败"是常态,必须用 Result

```rust
// 烂
let data = std::fs::read_to_string("config.toml").unwrap();  // 文件不存在?直接挂?

// 好
let data = std::fs::read_to_string("config.toml")?;
```

❌ **任何要发布到生产的库代码**:库不应该 panic,让调用方决定

❌ **服务器主循环**:一个请求处理出错,不应该让整个进程挂

### `unwrap()` vs `expect()`

```rust
let x = some_option.unwrap();              // panic 时只说 "called Option::unwrap on None"
let x = some_option.expect("config must be loaded by now");  // panic 时说你给的信息
```

工程经验:**生产代码里如果一定要 unwrap,一律用 expect 加 context**。这样 panic 信息至少能定位问题。clippy 有专门的 lint `unwrap_used` 帮你强制这个。

---

## 5.5 错误的可观察性

错误信息只在生产环境出错时有用。这一节讲怎么让错误信息有用。

### Display vs Debug

每个 Error 类型应该实现:
- `Display`:给用户看的(短、清晰)
- `Debug`:给开发者看的(详细、含上下文)

`thiserror` 的 `#[error("...")]` 自动实现 Display。Debug 可以 `#[derive(Debug)]`。

```rust
#[derive(Error, Debug)]
pub enum LoadError {
    #[error("file not found: {0}")]
    NotFound(String),
}

let e = LoadError::NotFound("config.toml".into());
println!("{}", e);   // "file not found: config.toml"
println!("{:?}", e); // "NotFound(\"config.toml\")"
```

### 错误链:source()

`std::error::Error::source()` 返回错误的"原因"——这是错误链的实现:

```rust
let err: Box<dyn Error> = ...;
let mut current = err.as_ref() as &dyn Error;
while let Some(source) = current.source() {
    eprintln!("caused by: {}", source);
    current = source;
}
```

`anyhow` 自动维护这个链,`{:#}` 格式化时会打印整条链:

```rust
println!("{:#}", anyhow_err);
// failed to load session: file not found: caused by: No such file or directory
```

### Backtrace

Rust 1.65+ 标准库支持 backtrace。`anyhow` 1.x 也支持。

```bash
RUST_BACKTRACE=1 cargo run
```

设了这个环境变量,panic 或 anyhow error 会带完整调用栈。生产环境一般这个变量是开的。

### 错误日志规范

工程实践:用 `tracing` crate(Ch 15 详讲)记录错误,而不是 `eprintln!`:

```rust
match do_something() {
    Ok(v) => v,
    Err(e) => {
        tracing::error!(error = ?e, "failed to do something");
        return Err(e);
    }
}
```

`error = ?e` 用 Debug 格式化,把整个错误结构(包括 source 链)写进日志。结构化日志在生产环境的可观察性远超 plain text。

---

## 5.6 实战:重设计 Stiglab 一个模块的错误层次

回到工程。假设 Stiglab 有这么一个模块:

```rust
// session_manager.rs
pub struct SessionManager {
    pool: PgPool,
}

impl SessionManager {
    pub async fn start_session(&self, id: SessionId) -> Result<Session, ???> {
        let row = sqlx::query!("SELECT * FROM sessions WHERE id = $1", id.0)
            .fetch_one(&self.pool)
            .await?;  // sqlx::Error

        let config: SessionConfig = serde_json::from_str(&row.config)?;  // serde_json::Error

        let session = Session::create(id, config);
        let session = session.start().map_err(|_| ???)?;  // 状态机错误

        sqlx::query!("UPDATE sessions SET status = 'running' WHERE id = $1", id.0)
            .execute(&self.pool)
            .await?;  // sqlx::Error

        Ok(session)
    }
}
```

`???` 处的设计就是错误层次决策。

### 设计错误 enum

```rust
use thiserror::Error;

#[derive(Error, Debug)]
pub enum SessionManagerError {
    #[error("session {0} not found")]
    NotFound(SessionId),

    #[error("session {0} is not in a state that can be started")]
    InvalidState(SessionId),

    #[error("database error")]
    Database(#[from] sqlx::Error),

    #[error("invalid session config")]
    InvalidConfig(#[from] serde_json::Error),
}
```

### 改写后的代码

```rust
impl SessionManager {
    pub async fn start_session(
        &self,
        id: SessionId,
    ) -> Result<Session, SessionManagerError> {
        let row = sqlx::query!("SELECT * FROM sessions WHERE id = $1", id.0)
            .fetch_optional(&self.pool)
            .await?
            .ok_or(SessionManagerError::NotFound(id))?;

        let config: SessionConfig = serde_json::from_str(&row.config)?;

        let session = Session::create(id, config);
        let session = session
            .start()
            .map_err(|_| SessionManagerError::InvalidState(id))?;

        sqlx::query!(
            "UPDATE sessions SET status = 'running' WHERE id = $1",
            id.0
        )
        .execute(&self.pool)
        .await?;

        Ok(session)
    }
}
```

### Handler 层把错误转 HTTP

Service 层返回了 `SessionManagerError`,但 HTTP handler 需要决定返回什么 status code:

```rust
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

impl IntoResponse for SessionManagerError {
    fn into_response(self) -> Response {
        let status = match &self {
            SessionManagerError::NotFound(_) => StatusCode::NOT_FOUND,
            SessionManagerError::InvalidState(_) => StatusCode::CONFLICT,
            SessionManagerError::InvalidConfig(_) => StatusCode::UNPROCESSABLE_ENTITY,
            SessionManagerError::Database(_) => {
                tracing::error!(error = ?self, "database error");
                StatusCode::INTERNAL_SERVER_ERROR
            }
        };
        (status, self.to_string()).into_response()
    }
}
```

注意 `Database` 分支:数据库错误不应该把 `sqlx::Error` 的细节暴露给 client(可能含敏感信息),只返回 500 + 内部记 error log。**错误的可见性是安全话题**——细节给运维,模糊化的版本给用户。

### 这个例子综合了什么

1. `thiserror` 给 service 层细粒度错误类型
2. `#[from]` 让 `?` 自动转换底层错误
3. `IntoResponse` 把业务错误转成 HTTP 响应,实现 service↔transport 解耦
4. 敏感错误(数据库)模糊化、记日志,不向 client 泄露
5. 整个错误流是显式的、类型化的、可重构的

---

## 5.7 章末小结与习题

### 本章核心概念回顾

1. **Rust 没有 exception**:错误是值,函数签名声明可能失败
2. **`?` 操作符**:简洁的错误传播,内部调用 `From::from` 做类型转换
3. **`thiserror` for libraries**:细粒度错误 enum,调用方可以 match
4. **`anyhow` for applications**:粗粒度错误 + context,人读得懂的错误链
5. **panic 是逻辑错误信号**:不变量破坏 / 测试 / unreachable,不是常规错误处理
6. **`expect` > `unwrap`**:必须 unwrap 时也加上 context
7. **错误的可观察性**:Display 给用户、Debug 给开发者、source 链 + backtrace + tracing 给运维
8. **service 层错误 ≠ HTTP 错误**:用 `IntoResponse` 在边界做转换

### 习题

#### 习题 5.1(简单)

把下面 Go 代码翻译成 Rust,使用 `?` 操作符:

```go
func loadAndParse(path string) (Config, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        return Config{}, err
    }
    config, err := parseConfig(data)
    if err != nil {
        return Config{}, err
    }
    return config, nil
}
```

#### 习题 5.2(中等)

设计一个 `BlogPostError` enum,用 `thiserror`,涵盖以下错误:

- 文章不存在(带 post id)
- 用户没有权限(带 user id 和 post id)
- 标题太长(带当前长度和最大长度)
- 数据库错误(包装 sqlx::Error)

#### 习题 5.3(中等)

下面代码用了 `unwrap`,改成正确的 Result + `?`:

```rust
fn read_user_age(id: u64) -> u32 {
    let conn = open_db().unwrap();
    let row = conn.query("SELECT age FROM users WHERE id = ?", id).unwrap();
    row.get::<u32>("age").unwrap()
}
```

#### 习题 5.4(困难,工程)

回到 Stiglab。找你模块里所有 `Result<T, E>` 返回的函数,分类:

- 哪些 E 应该是 `thiserror` 细分?
- 哪些可以是 `anyhow::Error`?
- 哪些其实应该是 `panic`?(不变量错误)

这个分类不需要 100% 精确,目的是建立"什么场景用什么错误"的判断习惯。

#### 习题 5.5(开放)

回顾你写过的 Go/TS/C# 代码。找一段错误处理特别啰嗦或特别松散的——比如 catch-all 的 try/catch、或一堆 `if err != nil { return err }`。

如果用 Rust 重写,错误层次怎么设计?是不是有些原本被吞掉的错误会被显式化?是不是有些重复的错误代码可以消失?

---

### 下一章预告

Ch 6 我们进入 Rust 类型系统的核心:**trait**。

trait 不是 Go interface 的复刻,也不是 C# interface 的翻版。它有自己的设计——associated types、blanket impl、object safety、static vs dynamic dispatch——这些一起让 Rust 的抽象表达力比 Go 高一个量级。

我们会重新设计 Onsager 的 Artifact 模型,看 trait 怎么帮你做出更好的 abstraction。

---

> **本章一句话总结**
>
> 错误处理不是负担,是契约。`Result` 让函数告诉调用方"我可能失败",`?` 让传播零成本,`thiserror` + `anyhow` 让你按层次设计错误而不被语法淹没。
