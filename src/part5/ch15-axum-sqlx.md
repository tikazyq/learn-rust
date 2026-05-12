# Ch 15 · Web 服务:Axum + sqlx + tracing

> 现代 Rust 生产级 HTTP 服务栈

**核心问题**:怎么用 Rust 写一个媲美 Go gin / C# ASP.NET Core 的生产级 HTTP 服务?

2026 年的 Rust web 三件套:**axum**(框架,Tokio 团队出品)+ **sqlx**(数据库,编译期 SQL 检查)+ **tracing**(结构化日志 / 分布式追踪)。这章不教 hello world——那是文档活儿——而是讲生产里把这三个串起来的细节。

读完你应该能:

1. 解释 axum 的 `Handler` / `Extractor` / `IntoResponse` 三元组怎么协作
2. 用 `tower::Layer` 写中间件,知道 layer 的执行顺序
3. 用 sqlx 的 `query!` 宏在编译期校验 SQL,知道它的限制
4. 用 tracing 输出结构化 JSON 日志并接入 OpenTelemetry
5. 实现 graceful shutdown(等已有请求完成才退出)

---

## 15.1 Axum 设计哲学

axum 是 [tower](https://docs.rs/tower) 生态的一部分。底层 abstraction 是 `tower::Service`:

```rust,ignore
pub trait Service<Request> {
    type Response;
    type Error;
    type Future: Future<Output = Result<Self::Response, Self::Error>>;
    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>>;
    fn call(&mut self, req: Request) -> Self::Future;
}
```

任何 "Request → Future<Response>" 都是 Service。axum 的 router、handler、middleware 全部是 Service。

### 跟 Go / C# 类比

| | Go (chi/gin) | C# (ASP.NET Core) | axum |
|---|---|---|---|
| handler 形态 | `func(w, r)` | controller class method | 普通 async fn |
| middleware | `Middleware(next) http.Handler` | `IMiddleware` 或 delegate | `tower::Layer<S>` |
| DI | 手动或第三方 | 内置(constructor injection) | `State<T>` extractor |
| 类型安全 | 弱(string-based routes) | 强(model binding) | 强(参数类型 ↔ extractor) |

---

## 15.2 Handler / Extractor / IntoResponse 契约

### Handler 是普通 async fn

```rust,ignore
async fn hello() -> &'static str { "hi" }
async fn user(Path(id): Path<u64>) -> Json<User> { /* ... */ }
async fn login(Json(body): Json<LoginReq>) -> Result<Json<Token>, AppError> { /* ... */ }
```

axum 通过泛型 magic 把"参数是 extractor"、"返回值是 IntoResponse"的 async fn 自动适配成 `tower::Service`。

### Extractor:从请求里取东西

| Extractor | 取什么 |
|---|---|
| `Path<T>` | URL path 参数 |
| `Query<T>` | query string |
| `Json<T>` | request body (JSON) |
| `Form<T>` | request body (form-urlencoded) |
| `Bytes` / `String` | 原始 body |
| `Headers` | 请求头 |
| `State<T>` | 共享应用状态 |
| `Extension<T>` | 中间件注入的值 |
| `TypedHeader<...>` | 强类型 header |

### 一个 handler 可以有多个 extractor

```rust,ignore
async fn handler(
    Path(user_id): Path<u64>,
    Query(q): Query<ListParams>,
    State(state): State<AppState>,
    Json(body): Json<UpdateReq>,
) -> Result<Json<User>, AppError> { /* ... */ }
```

**最后一个非泛型 extractor 必须是 body**(`Json`/`Form`/`Bytes` 等),因为 body 只能消耗一次。

### IntoResponse:返回值如何变成 HTTP response

```rust,ignore
// 内置实现
impl IntoResponse for &'static str { /* 200 text/plain */ }
impl IntoResponse for String { ... }
impl<T: Serialize> IntoResponse for Json<T> { /* 200 application/json */ }
impl IntoResponse for StatusCode { ... }
impl IntoResponse for (StatusCode, String) { ... }
impl<T, E> IntoResponse for Result<T, E> where T: IntoResponse, E: IntoResponse { ... }
```

自定义错误类型:

```rust,ignore
enum AppError {
    NotFound,
    Db(sqlx::Error),
    Validation(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, msg) = match self {
            AppError::NotFound        => (StatusCode::NOT_FOUND, "not found".to_string()),
            AppError::Db(e)           => (StatusCode::INTERNAL_SERVER_ERROR, format!("db: {e}")),
            AppError::Validation(m)   => (StatusCode::BAD_REQUEST, m),
        };
        (status, Json(json!({ "error": msg }))).into_response()
    }
}
```

`Result<T, AppError>` 的 handler 就能 `?` 错误自动转 HTTP response。

---

## 15.3 tower::Layer / tower::Service 中间件

```rust,ignore
use axum::{Router, middleware};
use tower::ServiceBuilder;
use tower_http::{trace::TraceLayer, cors::CorsLayer, timeout::TimeoutLayer};

let app = Router::new()
    .route("/users/:id", get(get_user))
    .layer(
        ServiceBuilder::new()
            .layer(TraceLayer::new_for_http())
            .layer(TimeoutLayer::new(Duration::from_secs(10)))
            .layer(CorsLayer::permissive()),
    );
```

### 层的执行顺序

`ServiceBuilder` 的 layer **从上到下应用,但请求从外到内**:

```
请求 → TraceLayer → TimeoutLayer → CorsLayer → handler
响应  ← TraceLayer ← TimeoutLayer ← CorsLayer ← handler
```

理解这个顺序很关键——TraceLayer 在最外层,它能看到完整的请求 / 响应时间,包括 Timeout 和 CORS 的处理。

### 自定义中间件

简单写法:

```rust,ignore
use axum::{middleware::Next, response::Response, http::Request};

async fn auth(req: Request, next: Next) -> Result<Response, StatusCode> {
    let token = req.headers().get("authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or(StatusCode::UNAUTHORIZED)?;
    if !verify(token) { return Err(StatusCode::UNAUTHORIZED); }
    Ok(next.run(req).await)
}

let app = Router::new().route("/x", get(handler))
    .route_layer(middleware::from_fn(auth));
```

复杂的(需要状态、自己实现 Service trait)以后再写。

---

## 15.4 状态共享:State<Arc<AppState>>

```rust,ignore
#[derive(Clone)]
struct AppState {
    db: PgPool,
    redis: redis::Client,
    config: Arc<Config>,
}

#[tokio::main]
async fn main() {
    let state = AppState {
        db: PgPool::connect(&db_url).await.unwrap(),
        redis: redis::Client::open(redis_url).unwrap(),
        config: Arc::new(load_config()),
    };

    let app = Router::new()
        .route("/users/:id", get(get_user))
        .with_state(state);
}

async fn get_user(
    Path(id): Path<i64>,
    State(s): State<AppState>,
) -> Result<Json<User>, AppError> {
    let u = sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id)
        .fetch_one(&s.db).await?;
    Ok(Json(u))
}
```

`AppState` 必须 `Clone`(`PgPool` 内部是 `Arc`,clone 廉价)。如果有不可 clone 的字段,**包一层 `Arc`**。

### Extension vs State

- `State<T>` 是新版推荐,**编译期检查类型存在**
- `Extension<T>` 是旧版,运行时查找,缺失 → 500。**不推荐**

---

## 15.5 sqlx 编译期检查

```rust,ignore
let user = sqlx::query_as!(
    User,
    "SELECT id, name, email FROM users WHERE id = $1",
    user_id,
).fetch_one(&pool).await?;
```

`query_as!` 是过程宏,**编译时连真实数据库**校验:

1. SQL 语法正确
2. 表 / 字段存在
3. 类型匹配(`id: i64` 对应 SQL `bigint`)
4. 返回结构匹配 `User`

### 配置

```bash
# .env(开发)
DATABASE_URL=postgres://localhost/myapp_dev

# 或离线模式(CI 用)
cargo sqlx prepare        # 生成 .sqlx/ 缓存
git add .sqlx
# 之后构建无需 live DB,sqlx 用缓存
```

### 限制

- 动态 SQL(`SELECT * FROM table_decided_at_runtime`)不行 → 改用 `sqlx::query`(非宏,无编译期检查)
- 复杂 join 返回结构可能推断失败 → 用 `query_as!` 显式指定结构
- 涉及函数(`COALESCE(x, 0)`)的列,sqlx 不确定 nullable → 用 `x as "x!: i64"` 强制

### 跟 ORM 对比

| | sqlx | diesel | sea-orm | Go (sqlx / gorm) |
|---|---|---|---|---|
| 风格 | SQL-first,async | DSL,sync(async beta) | ORM,async | sqlx: SQL-first / gorm: ORM |
| 编译期检查 | ✅ | ✅(DSL层面) | ❌ | ❌ |
| 学习曲线 | 平 | 陡(DSL) | 中 | 平 / 平 |

经验:**业务复杂、SQL 多变 → sqlx**;**模型固定、要 migration 自动生成 → diesel / sea-orm**。

---

## 15.6 连接池配置

```rust,ignore
use sqlx::postgres::PgPoolOptions;
use std::time::Duration;

let pool = PgPoolOptions::new()
    .max_connections(20)
    .min_connections(5)
    .acquire_timeout(Duration::from_secs(5))
    .idle_timeout(Some(Duration::from_secs(300)))
    .max_lifetime(Some(Duration::from_secs(3600)))
    .connect(&db_url).await?;
```

### 池大小的工程经验

- **不要把 max_connections 调到 100+** —— Postgres 的连接是重资源(每个连接对应一个 server-side 进程,~10MB 内存)
- **公式经验**:`max_connections ≈ (核数 × 2) + 磁盘数`(参考 HikariCP 文档)
- N 个服务实例 → 总连接数 = N × max_connections,DB 端 `max_connections` 要够

### Statement timeout 服务端配

```sql
ALTER ROLE myapp SET statement_timeout = '5s';
```

防止慢查询占住连接拖垮整个池。

---

## 15.7 tracing 结构化日志

```rust,ignore
use tracing::{info, error, instrument};

#[instrument(skip(pool), fields(user_id = %id))]
async fn get_user(pool: &PgPool, id: i64) -> Result<User, AppError> {
    info!("fetching user");
    let u = sqlx::query_as!(User, "...", id).fetch_one(pool).await?;
    info!(name = %u.name, "got user");
    Ok(u)
}
```

### 三个核心概念

- **event**:一次日志事件(`info!`, `warn!`, `error!`)
- **span**:有起止的逻辑作用域(一次 HTTP request、一次 DB query)
- **subscriber**:消费 event / span,决定怎么输出

### 设置 subscriber

```rust,ignore
use tracing_subscriber::{fmt, EnvFilter};

fmt()
    .with_env_filter(EnvFilter::from_default_env())
    .with_target(true)
    .with_thread_ids(true)
    .json()                              // JSON 格式
    .with_current_span(true)
    .init();
```

```bash
RUST_LOG=info,sqlx=warn,my_service=debug cargo run
```

### 在 axum 里自动给每个请求一个 span

```rust,ignore
use tower_http::trace::TraceLayer;
let app = Router::new()
    .route("/...", get(...))
    .layer(TraceLayer::new_for_http());
```

每个请求会自动建一个 span,内部所有 log 自动带 `request_id`、`method`、`path`、`status`、`duration`。

---

## 15.8 OpenTelemetry 集成

```toml
opentelemetry = { version = "0.27", features = ["trace"] }
opentelemetry_sdk = { version = "0.27", features = ["rt-tokio"] }
opentelemetry-otlp = { version = "0.27", features = ["tonic"] }
tracing-opentelemetry = "0.28"
```

```rust,ignore
use opentelemetry::trace::TracerProvider as _;
use tracing_subscriber::prelude::*;

let exporter = opentelemetry_otlp::SpanExporter::builder()
    .with_tonic()
    .with_endpoint("http://otel-collector:4317")
    .build()?;

let provider = opentelemetry_sdk::trace::TracerProvider::builder()
    .with_batch_exporter(exporter, opentelemetry_sdk::runtime::Tokio)
    .build();

let tracer = provider.tracer("my-service");

tracing_subscriber::registry()
    .with(tracing_subscriber::fmt::layer())
    .with(tracing_opentelemetry::layer().with_tracer(tracer))
    .with(EnvFilter::from_default_env())
    .init();
```

之后所有 `tracing` span 自动导出到 OpenTelemetry collector,可以串到 Jaeger / Tempo / Datadog。

---

## 15.9 错误处理:从 Result 到 HTTP response

`thiserror` 定义错误类型 + 自己实现 `IntoResponse`(见 15.2)= 业务代码完全 `?`,框架自动转 HTTP。

```rust,ignore
use thiserror::Error;

#[derive(Error, Debug)]
enum AppError {
    #[error("not found")]
    NotFound,
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("validation: {0}")]
    Validation(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        // 重点:日志 + 状态码
        let status = match &self {
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::Db(_) => {
                tracing::error!(error = ?self, "db error");
                StatusCode::INTERNAL_SERVER_ERROR
            }
            Self::Validation(_) => StatusCode::BAD_REQUEST,
        };
        (status, Json(json!({ "error": self.to_string() }))).into_response()
    }
}
```

**关键**:5xx 错误**记日志**,4xx 不记(否则攻击者一通 bad request 把你日志刷满)。

---

## 15.10 优雅关闭(Graceful shutdown)

```rust,ignore
use tokio::signal;

async fn shutdown_signal() {
    let ctrl_c = async { signal::ctrl_c().await.unwrap(); };
    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .unwrap().recv().await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {} }
    tracing::info!("shutdown signal received");
}

let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await?;
axum::serve(listener, app)
    .with_graceful_shutdown(shutdown_signal())
    .await?;
```

行为:收到 SIGTERM / SIGINT 后:

1. 停止 accept 新连接
2. 等已有连接的请求处理完
3. **超过最长等待时间则强杀**(自己加 timeout)

K8s rolling update / SIGTERM handling 必备。

---

## 习题

1. 写一个 REST 服务:用户增删改查 + JWT 鉴权 + sqlx + tracing + graceful shutdown。
2. 用 `wrk` 压测 axum hello world,跟 Go gin 对比 QPS。
3. 故意写一个慢 handler(`tokio::time::sleep(60s)`),触发 shutdown,看连接是否优雅关闭。
4. 接 OpenTelemetry 到 Jaeger,在 Jaeger UI 里看一个跨服务调用 trace。
5. 测试 sqlx 的离线模式:用 `cargo sqlx prepare` 生成缓存,在没有 DB 的环境构建,看是否成功。

---

> **本章一句话总结**
>
> Axum + sqlx + tracing 是 2026 年写 Rust web 服务的事实组合。掌握这三个,你能上生产;写得地道,你能比 Go 同等服务 QPS 高 1.5-3 倍同时内存少一半。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
