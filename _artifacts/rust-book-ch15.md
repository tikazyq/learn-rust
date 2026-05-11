# 第 15 章 · Web 服务实战 —— Axum、sqlx、tracing

> "If you're building a web service in Rust today, this is the stack."

这章我们把 async / trait / error handling 这些概念落地——用 Axum 写一个生产级 HTTP 服务。

读完这章你应该能:

1. 用 Axum 写出地道的 handler、extractor、response
2. 设计中间件,用 tower::Layer 串起来
3. 用 sqlx 做编译期检查的数据库查询
4. 用 tracing 做结构化日志和 distributed tracing
5. 把这些拼起来,写一个能上生产的 Rust web 服务

---

## 15.1 Axum 的设计哲学:基于 tower::Service

Axum 不是从零设计的——它建立在 `tower` 生态上。`tower::Service` 是一个抽象:

```rust
pub trait Service<Request> {
    type Response;
    type Error;
    type Future: Future<Output = Result<Self::Response, Self::Error>>;
    fn call(&mut self, req: Request) -> Self::Future;
    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>>;
}
```

任何"请求 → 响应"的东西都是 Service:HTTP handler、gRPC handler、middleware、负载均衡器、限流器。整个 Axum 生态都是 Service 的组合。

这个设计让你**任何中间件都可重用**——一个 tower middleware 可以同时用在 HTTP、gRPC、内部 RPC 上。

---

## 15.2 第一个 Axum 服务

```rust
use axum::{Router, routing::get, Json};
use serde::Serialize;

#[derive(Serialize)]
struct Hello {
    message: String,
}

async fn handler() -> Json<Hello> {
    Json(Hello { message: "hello world".into() })
}

#[tokio::main]
async fn main() {
    let app = Router::new().route("/", get(handler));
    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
```

10 行代码,一个能跑的 HTTP 服务。

---

## 15.3 Handler 与 Extractor

Axum 的 handler 是普通 async 函数。参数通过 **extractor** 系统从请求里提取:

```rust
use axum::{
    extract::{Path, Query, State, Json as JsonExtract},
    http::StatusCode,
    Json,
};
use serde::Deserialize;

#[derive(Deserialize)]
struct CreateUser {
    name: String,
    email: String,
}

#[derive(Deserialize)]
struct ListParams {
    limit: Option<u32>,
    offset: Option<u32>,
}

async fn create_user(
    State(db): State<AppState>,
    JsonExtract(input): JsonExtract<CreateUser>,
) -> Result<Json<User>, StatusCode> {
    let user = db.insert(input.name, input.email).await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(user))
}

async fn get_user(
    State(db): State<AppState>,
    Path(id): Path<u64>,
) -> Result<Json<User>, StatusCode> {
    db.find_by_id(id).await
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}

async fn list_users(
    State(db): State<AppState>,
    Query(params): Query<ListParams>,
) -> Json<Vec<User>> {
    Json(db.list(params.limit.unwrap_or(10), params.offset.unwrap_or(0)).await)
}
```

extractor 列表:

| Extractor | 提取什么 |
|---|---|
| `Path<T>` | URL 路径参数 |
| `Query<T>` | URL query 参数 |
| `Json<T>` | JSON body |
| `Form<T>` | form-encoded body |
| `Headers` | 请求 headers |
| `State<T>` | 共享状态(下面讲) |
| `Extension<T>` | 老式 state(被 State 替代) |
| `Multipart` | multipart upload |

extractor 系统的设计妙处:**你只需声明参数类型,框架自动从请求里提取**。这是 trait 的力量——每个 extractor 是个 trait impl,axum 自动调用。

---

## 15.4 State 与共享资源

handler 经常需要访问共享资源(数据库连接池、配置、缓存):

```rust
#[derive(Clone)]
struct AppState {
    db: Arc<PgPool>,
    config: Arc<Config>,
}

async fn handler(State(state): State<AppState>) -> Json<...> {
    let row = sqlx::query!("SELECT * FROM users").fetch_one(&*state.db).await;
    // ...
}

#[tokio::main]
async fn main() {
    let state = AppState {
        db: Arc::new(create_pool().await),
        config: Arc::new(load_config()),
    };

    let app = Router::new()
        .route("/users", get(handler))
        .with_state(state);

    axum::serve(listener, app).await.unwrap();
}
```

要点:
- AppState 实现 `Clone`(因为每个请求都会 clone 一份 state)
- 内部用 Arc 避免真的 clone 大对象
- 用 `.with_state(state)` 注入到 router

---

## 15.5 错误处理:IntoResponse

handler 返回 `Result<T, E>` 时,`E` 需要实现 `IntoResponse`,告诉 axum 怎么转成 HTTP 响应。

```rust
use axum::response::{IntoResponse, Response};
use axum::http::StatusCode;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum AppError {
    #[error("not found")]
    NotFound,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("internal error")]
    Internal(#[from] sqlx::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            AppError::NotFound => (StatusCode::NOT_FOUND, "not found".to_string()),
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            AppError::Internal(e) => {
                tracing::error!(error = ?e, "internal error");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
        };
        (status, message).into_response()
    }
}

async fn handler() -> Result<Json<User>, AppError> {
    let user = find_user().await?;     // 自动 ? + IntoResponse
    Ok(Json(user))
}
```

工程要点:
- 内部错误(如 sqlx)的细节**不暴露**给 client(可能含敏感信息)
- 内部错误**记 error 日志**,定位用
- 给 client 的错误信息**人话**

---

## 15.6 中间件:tower::Layer

中间件是请求/响应链上的一站。axum 用 tower::Layer:

```rust
use tower::ServiceBuilder;
use tower_http::trace::TraceLayer;
use tower_http::cors::CorsLayer;
use tower_http::compression::CompressionLayer;
use std::time::Duration;

let app = Router::new()
    .route("/users", get(handler))
    .layer(
        ServiceBuilder::new()
            .layer(TraceLayer::new_for_http())
            .layer(CorsLayer::permissive())
            .layer(CompressionLayer::new())
            .timeout(Duration::from_secs(30))
    )
    .with_state(state);
```

常用 tower-http middleware:
- `TraceLayer`:记录请求日志
- `CorsLayer`:CORS 处理
- `CompressionLayer`:gzip 响应
- `TimeoutLayer`:请求超时
- `RateLimitLayer`:限流
- `SetResponseHeader`:设响应头

### 自定义 middleware

axum 0.7+ 推荐用 `axum::middleware::from_fn`:

```rust
use axum::{middleware, response::Response, extract::Request};

async fn log_middleware(req: Request, next: middleware::Next) -> Response {
    let path = req.uri().path().to_string();
    tracing::info!(path = %path, "request");
    let response = next.run(req).await;
    tracing::info!(path = %path, status = %response.status(), "response");
    response
}

let app = Router::new()
    .route("/", get(handler))
    .layer(middleware::from_fn(log_middleware));
```

---

## 15.7 sqlx:编译期检查的 SQL

sqlx 区别于其他 ORM 的核心特性:**SQL 在编译期被检查**。

### 基础用法

```rust
let row = sqlx::query!("SELECT id, name FROM users WHERE id = $1", user_id)
    .fetch_one(&pool)
    .await?;

println!("{} {}", row.id, row.name);
```

`query!` 是宏。编译时它做的事:
1. 连接到你 `DATABASE_URL` 指向的数据库
2. 把 SQL 发过去 `PREPARE`
3. 获取每个列的类型
4. 生成 strongly-typed 的 Rust struct

如果你 SQL 有错(列名拼错、类型不对),**编译失败**。这比运行时才发现强一万倍。

### 离线模式

编译时连数据库不方便(CI、新开发机)。sqlx 提供 `cargo sqlx prepare`:

```bash
cargo sqlx prepare    # 把元数据写到 .sqlx 目录
```

之后编译时如果 `SQLX_OFFLINE=true`,sqlx 用 .sqlx 里的缓存,不连数据库。生产 CI 必备。

### Migration

```bash
cargo install sqlx-cli
sqlx migrate add create_users     # 创建 migration 文件
sqlx migrate run                  # 应用 migration
```

```rust
// 代码里跑 migration
sqlx::migrate!("./migrations").run(&pool).await?;
```

### Transaction

```rust
let mut tx = pool.begin().await?;
sqlx::query!("INSERT INTO users (name) VALUES ($1)", name)
    .execute(&mut *tx)
    .await?;
sqlx::query!("INSERT INTO audit_log (action) VALUES ('user_created')")
    .execute(&mut *tx)
    .await?;
tx.commit().await?;
```

如果 commit 没调用,tx drop 时自动 rollback。

### 连接池配置

```rust
let pool = sqlx::postgres::PgPoolOptions::new()
    .max_connections(20)
    .min_connections(2)
    .max_lifetime(Duration::from_secs(60 * 30))
    .acquire_timeout(Duration::from_secs(3))
    .connect(&database_url)
    .await?;
```

工程经验:
- `max_connections` 不要超过 DB 服务器的限制
- 多个服务实例共享 DB,要预留 buffer
- `acquire_timeout` 短一点(几秒),否则请求级超时会被它吃掉

---

## 15.8 tracing:结构化日志与 distributed tracing

`tracing` 是 Rust 的事实标准 logging crate。它的核心概念:

- **Event**:单次日志(类似 log crate 的 info!/error!)
- **Span**:一段持续时间(请求处理、数据库查询、外部调用)
- **Subscriber**:消费 events / spans 的后端

### 基础用法

```rust
use tracing::{info, error, warn, debug, trace, span, Level};

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();    // 初始化默认 subscriber

    info!("server starting");
    let _span = span!(Level::INFO, "request_handler", request_id = "abc").entered();

    info!("inside handler");
    if let Err(e) = do_something().await {
        error!(error = ?e, "operation failed");
    }
}
```

### 结构化字段

跟 plain text log 不同,tracing 鼓励 key-value:

```rust
info!(user_id = user.id, name = %user.name, "user logged in");
```

- `%user.name` 用 Display 格式
- `?user` 用 Debug 格式
- 否则按字面值

输出(默认 formatter):

```
2026-05-11T08:30:42Z  INFO request_handler{request_id="abc"}: user logged in user_id=42 name="Marvin"
```

### 用 #[instrument] 注解

```rust
#[tracing::instrument(skip(pool), fields(user_id = id))]
async fn load_user(pool: &PgPool, id: u64) -> Result<User, sqlx::Error> {
    // 自动创建一个 span 围绕这个函数,带上 user_id 字段
    let user = sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id as i64)
        .fetch_one(pool)
        .await?;
    Ok(user)
}
```

`#[instrument]` 自动创建 span,函数参数自动加进字段。`skip(pool)` 排除某些字段(避免巨大的对象被打印)。

### OpenTelemetry 集成

生产环境通常要把 tracing 数据发到 Jaeger / Tempo / Honeycomb 等:

```rust
use opentelemetry::trace::TraceContextExt;
use tracing_opentelemetry::OpenTelemetryLayer;
use tracing_subscriber::layer::SubscriberExt;

let tracer = opentelemetry_jaeger::new_agent_pipeline()
    .with_service_name("stiglab-control-plane")
    .install_simple()?;

let subscriber = tracing_subscriber::Registry::default()
    .with(tracing_subscriber::fmt::layer())
    .with(OpenTelemetryLayer::new(tracer));

tracing::subscriber::set_global_default(subscriber)?;
```

之后每个 span 都自动变成 distributed trace 的一段。Stiglab Control Plane 上生产应该这么做。

---

## 15.9 完整示例:用户 CRUD 服务

把所有东西拼起来:

```rust
use axum::{
    Router,
    routing::{get, post, delete},
    extract::{State, Path, Json as JsonExtract},
    response::{IntoResponse, Response, Json},
    http::StatusCode,
};
use serde::{Serialize, Deserialize};
use sqlx::PgPool;
use std::sync::Arc;
use thiserror::Error;
use tower::ServiceBuilder;
use tower_http::trace::TraceLayer;

#[derive(Clone)]
struct AppState {
    db: Arc<PgPool>,
}

#[derive(Serialize, sqlx::FromRow)]
struct User {
    id: i64,
    name: String,
    email: String,
}

#[derive(Deserialize)]
struct CreateUser {
    name: String,
    email: String,
}

#[derive(Error, Debug)]
enum AppError {
    #[error("not found")]
    NotFound,
    #[error("invalid input: {0}")]
    BadRequest(String),
    #[error("database error")]
    Database(#[from] sqlx::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            AppError::NotFound => (StatusCode::NOT_FOUND, "not found".to_string()),
            AppError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            AppError::Database(e) => {
                tracing::error!(error = ?e, "db error");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
        };
        (status, msg).into_response()
    }
}

#[tracing::instrument(skip(state))]
async fn list_users(State(state): State<AppState>) -> Result<Json<Vec<User>>, AppError> {
    let users = sqlx::query_as!(User, "SELECT id, name, email FROM users LIMIT 100")
        .fetch_all(&*state.db)
        .await?;
    Ok(Json(users))
}

#[tracing::instrument(skip(state), fields(id = %id))]
async fn get_user(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> Result<Json<User>, AppError> {
    let user = sqlx::query_as!(User, "SELECT id, name, email FROM users WHERE id = $1", id)
        .fetch_optional(&*state.db)
        .await?
        .ok_or(AppError::NotFound)?;
    Ok(Json(user))
}

#[tracing::instrument(skip(state, input))]
async fn create_user(
    State(state): State<AppState>,
    JsonExtract(input): JsonExtract<CreateUser>,
) -> Result<Json<User>, AppError> {
    if input.name.is_empty() {
        return Err(AppError::BadRequest("name required".into()));
    }
    let user = sqlx::query_as!(
        User,
        "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id, name, email",
        input.name, input.email,
    )
    .fetch_one(&*state.db)
    .await?;
    Ok(Json(user))
}

#[tracing::instrument(skip(state))]
async fn delete_user(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> Result<StatusCode, AppError> {
    let result = sqlx::query!("DELETE FROM users WHERE id = $1", id)
        .execute(&*state.db)
        .await?;
    if result.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(20)
        .connect(&std::env::var("DATABASE_URL")?)
        .await?;
    sqlx::migrate!("./migrations").run(&pool).await?;

    let state = AppState { db: Arc::new(pool) };

    let app = Router::new()
        .route("/users", get(list_users).post(create_user))
        .route("/users/:id", get(get_user).delete(delete_user))
        .layer(ServiceBuilder::new().layer(TraceLayer::new_for_http()))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await?;
    tracing::info!("server listening on :3000");
    axum::serve(listener, app).await?;
    Ok(())
}
```

100 行,生产级的 CRUD 服务。带:
- 类型安全的 SQL
- 结构化错误处理
- 结构化日志(每个 handler 自动有 span)
- 连接池
- middleware(请求日志)

---

## 15.10 章末小结与习题

### 本章核心概念回顾

1. **Axum 基于 tower::Service**:中间件、客户端、负载均衡器都是 Service
2. **Extractor**:声明参数类型,自动提取
3. **State**:Clone + Arc 模式,跨 handler 共享资源
4. **IntoResponse**:错误自动转 HTTP 响应,业务错 vs 内部错分开处理
5. **sqlx**:编译期 SQL 检查 + 离线模式 + migration
6. **tracing**:结构化日志 + span + OpenTelemetry
7. **#[instrument]**:函数级 span,生产可观察性的基础

### 习题

#### 习题 15.1(简单)

写一个返回 JSON `{"status":"ok"}` 的 `/health` endpoint。

#### 习题 15.2(中等)

给 15.9 的服务加 JWT 鉴权:
- `/login` endpoint 接受用户名密码,返回 JWT
- 其他 endpoints 需要在 Authorization header 带 JWT
- 用 middleware 验证 token

#### 习题 15.3(中等)

把 sqlx 的连接池配置改成从配置文件读(toml 或 yaml)。要支持热加载——更新配置文件后服务自动应用。

#### 习题 15.4(困难)

给 15.9 的服务加 OpenTelemetry,把 trace 发到 Jaeger 或 Tempo。每个 HTTP 请求应该是一个 root span,内部数据库调用是 child span。

#### 习题 15.5(开放)

回到 Stiglab Control Plane。看看现有 Axum 代码,问自己:

- handler 的错误处理是否地道?有没有内部错暴露给 client?
- tracing 覆盖率够吗?重要操作都有 span 吗?
- sqlx 用得对吗?有没有 N+1 查询?
- 有没有缺失的中间件?(timeout / rate limit / CORS)

---

### 下一章预告

Ch 16 处理工程化的最后一块:测试、benchmark、可观察性的完整栈。

---

> **本章一句话总结**
>
> Axum + sqlx + tracing 是当今 Rust web 服务最成熟的栈。它们各自的设计哲学(tower::Service / 编译期 SQL / 结构化 trace)互相强化,合起来给你生产级的开发体验。
