# 第 16 章 · 测试、基准、可观测性

> "If you can't measure it, you can't improve it. If you can't observe it in production, you don't have a production system."

这章是 Part V 的收尾,把 Rust 的工程化拼图补完。我们看测试栈(单元 / 集成 / property / snapshot)、benchmark(criterion / flamegraph)、生产可观察性(metrics / tokio-console)。

读完这章你应该能:

1. 写不同层级的测试,知道每层覆盖什么
2. 用 proptest 做属性测试,用 insta 做 snapshot 测试
3. 用 criterion 做严格的 microbenchmark
4. 用 flamegraph 定位性能热点
5. 用 tokio-console 排查 async 性能问题

---

## 16.1 测试栈分层

| 层级 | 工具 | 覆盖 |
|---|---|---|
| 单元测试 | `#[test]` | 单个函数、struct method |
| 集成测试 | `tests/` 目录 | crate 公共 API |
| Property test | `proptest` / `quickcheck` | 不变量(对任意输入都成立) |
| Snapshot test | `insta` | 复杂输出(JSON、错误消息、AST) |
| End-to-end test | `tokio::test` + 真实服务 | 整个系统 |

最佳实践:**单元测试占大头,property test 补不变量,集成 / e2e 测关键路径**。

---

## 16.2 单元测试基础

Rust 单元测试就写在源文件里:

```rust
// src/math.rs
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_works() {
        assert_eq!(add(2, 3), 5);
    }

    #[test]
    fn add_handles_negative() {
        assert_eq!(add(-1, 1), 0);
    }

    #[test]
    #[should_panic(expected = "overflow")]
    fn add_overflow_panics() {
        add(i32::MAX, 1);   // 假设 add 在 overflow 时 panic
    }
}
```

`#[cfg(test)]` 让 mod 只在测试时编译,不出现在 release 二进制。

### 跑测试

```bash
cargo test                          # 跑所有测试
cargo test add_works                # 跑名字含 add_works 的
cargo test --lib                    # 只跑单元测试(不跑集成测试)
cargo test --test integration       # 只跑 tests/integration.rs
cargo test -- --nocapture           # 不捕获 stdout(看 println!)
cargo test -- --test-threads=1      # 串行(默认并行,有共享状态时用)
```

### Async 测试

```rust
#[tokio::test]
async fn async_test() {
    let result = some_async_fn().await;
    assert_eq!(result, expected);
}
```

`#[tokio::test]` 自动起一个 Tokio runtime。

### 测试组织模式

复杂业务逻辑,测试组织成"Arrange / Act / Assert":

```rust
#[test]
fn user_can_be_created_with_valid_email() {
    // Arrange
    let input = CreateUser {
        name: "Marvin".into(),
        email: "m@example.com".into(),
    };

    // Act
    let result = User::create(input);

    // Assert
    assert!(result.is_ok());
    let user = result.unwrap();
    assert_eq!(user.email, "m@example.com");
}
```

测试名字像句子,失败时一眼看出意图。

---

## 16.3 集成测试

`tests/` 目录下的每个 `.rs` 文件是独立的集成测试 crate:

```
my-crate/
├── src/
│   └── lib.rs
├── tests/
│   ├── api_test.rs
│   └── db_test.rs
```

```rust
// tests/api_test.rs
use my_crate::*;

#[tokio::test]
async fn create_then_get_user() {
    let api = MyApi::new();
    let user = api.create_user("Marvin", "m@example.com").await.unwrap();
    let fetched = api.get_user(user.id).await.unwrap();
    assert_eq!(fetched.name, "Marvin");
}
```

集成测试只能用 crate 的 `pub` API,模拟外部调用方视角。

### 共享 fixtures

如果多个集成测试共享 setup 代码,放 `tests/common/mod.rs`:

```rust
// tests/common/mod.rs
pub async fn setup_test_db() -> PgPool { /* ... */ }

// tests/api_test.rs
mod common;
use common::setup_test_db;

#[tokio::test]
async fn ... { let pool = setup_test_db().await; ... }
```

### 测试用的临时数据库

集成测试经常需要真实数据库。模式:

```rust
async fn setup_test_db() -> PgPool {
    let url = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
    // 用 random 数据库名,测试隔离
    let db_name = format!("test_{}", uuid::Uuid::new_v4());
    let admin_pool = PgPool::connect(&url).await.unwrap();
    sqlx::query(&format!("CREATE DATABASE {}", db_name)).execute(&admin_pool).await.unwrap();
    let pool = PgPool::connect(&format!("{}/{}", url, db_name)).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    pool
}
```

每个测试一个独立数据库,平行测试不冲突。`sqlx` 有内置 `#[sqlx::test]` 宏自动做这事。

---

## 16.4 Property Testing 用 proptest

普通测试是"举例子",property test 是"声明不变量,框架随机生成输入":

```rust
use proptest::prelude::*;

fn reverse<T: Clone>(v: &[T]) -> Vec<T> {
    v.iter().rev().cloned().collect()
}

proptest! {
    #[test]
    fn reverse_twice_is_identity(v: Vec<i32>) {
        prop_assert_eq!(reverse(&reverse(&v)), v);
    }

    #[test]
    fn reverse_preserves_length(v: Vec<i32>) {
        prop_assert_eq!(reverse(&v).len(), v.len());
    }
}
```

proptest 随机生成几百个 `Vec<i32>` 测试这些不变量。**找到反例时还会自动缩小**——给你最小的失败输入。

### Property test 适合什么

- 编解码:`decode(encode(x)) == x`
- 排序:输出长度等于输入、输出有序、输出是输入的 permutation
- 状态机:任意操作序列后不变量保持
- 解析器:`parse(format(x)) == Ok(x)`

### Property test 不适合什么

- 业务流程(需要特定场景)
- 副作用(发邮件、写数据库)
- 单纯的"调用一下看返回什么"

工程经验:**核心算法用 property test 补一层,生产代码主要还是单元测试**。

---

## 16.5 Snapshot Testing 用 insta

复杂输出(JSON / 错误消息 / AST)用 assertEq 写起来痛苦。snapshot test:

```rust
use insta::assert_yaml_snapshot;

#[test]
fn user_serialization() {
    let user = User { id: 1, name: "Marvin".into(), email: "m@x.com".into() };
    assert_yaml_snapshot!(user);
}
```

第一次跑测试时,insta 把 user 序列化保存到 `tests/snapshots/...` 文件。之后跑测试,把当前输出跟保存的对比,不一致就失败。

修改输出有意为之时:

```bash
cargo install cargo-insta
cargo insta review     # 交互式 review 所有变更
```

### 适合的场景

- API 响应格式
- 错误消息文本
- 代码生成器输出
- 序列化结果

snapshot 是"contract 测试"的轻量版——不用手写预期,框架记下来。

---

## 16.6 Mock 与 dependency injection

Rust 没有反射,但通过 trait 可以做 mock:

```rust
#[async_trait::async_trait]
trait UserRepository {
    async fn find(&self, id: u64) -> Option<User>;
    async fn save(&self, user: User) -> Result<(), Error>;
}

// 生产实现
struct PgUserRepository { pool: PgPool }

// 测试用 mock(手写 / 用 mockall 自动生成)
use mockall::mock;

mock! {
    UserRepository {}
    #[async_trait::async_trait]
    impl UserRepository for UserRepository {
        async fn find(&self, id: u64) -> Option<User>;
        async fn save(&self, user: User) -> Result<(), Error>;
    }
}

#[tokio::test]
async fn service_test() {
    let mut mock = MockUserRepository::new();
    mock.expect_find()
        .with(eq(42))
        .returning(|_| Some(User { id: 42, ..Default::default() }));

    let service = UserService::new(Box::new(mock));
    let user = service.get_user(42).await.unwrap();
    assert_eq!(user.id, 42);
}
```

工程经验:**mock 是手段不是目的**。Rust 社区的倾向是"减少 mock"——通过 in-memory 实现(InMemoryRepo)或者真实但隔离的 fixture(test database)替代 mock。mock 多了测试容易脆。

---

## 16.7 Benchmark 用 criterion

`cargo bench` 用 stable Rust 要靠 criterion crate:

```toml
[dev-dependencies]
criterion = { version = "0.5", features = ["html_reports"] }

[[bench]]
name = "my_bench"
harness = false
```

`benches/my_bench.rs`:

```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion};

fn fibonacci(n: u64) -> u64 {
    if n < 2 { n } else { fibonacci(n - 1) + fibonacci(n - 2) }
}

fn bench_fib(c: &mut Criterion) {
    c.bench_function("fib 20", |b| {
        b.iter(|| fibonacci(black_box(20)))
    });
}

criterion_group!(benches, bench_fib);
criterion_main!(benches);
```

```bash
cargo bench
```

criterion 做的事:
- 自动 warmup
- 多次测量取统计(均值、标准差、异常值)
- 跟上次跑的结果对比,告诉你 regression / improvement
- 生成 HTML 报告

`black_box(x)` 阻止编译器把表达式优化掉(否则 microbenchmark 经常被优化成 nothing)。

### 比较不同实现

```rust
fn bench_sort(c: &mut Criterion) {
    let mut group = c.benchmark_group("sort");
    let data: Vec<i32> = (0..1000).rev().collect();

    group.bench_function("std sort", |b| {
        b.iter(|| {
            let mut v = data.clone();
            v.sort();
            black_box(v);
        })
    });

    group.bench_function("unstable sort", |b| {
        b.iter(|| {
            let mut v = data.clone();
            v.sort_unstable();
            black_box(v);
        })
    });

    group.finish();
}
```

输出会并排显示两种实现的性能对比。

### Microbench 的陷阱

- 编译器优化太狠:用 black_box
- 缓存效应:第一次跑 vs 第 100 次跑数据已经 hot 了
- 输入太小:测出来全是 setup 开销

工程经验:**microbench 用来对比两个实现,绝对数字别太当真**。系统级性能要在真实场景里测。

---

## 16.8 Profiling:flamegraph 与 perf

microbench 告诉你"这段代码多快",profiling 告诉你"整个程序里时间花在哪"。

### flamegraph

```bash
cargo install flamegraph
cargo flamegraph --bench my_bench         # 给 benchmark profile
cargo flamegraph --bin my-server -- args  # 给 binary profile
```

生成 SVG 火焰图:横轴是相对耗时,纵轴是调用栈。一眼看出热点函数。

Linux 需要装 perf 工具:

```bash
sudo apt install linux-tools-common linux-tools-generic
# 或者 perf 来自你的内核版本对应包
```

### 几个 profile 小技巧

- **release 模式 profile**:`cargo flamegraph --release`,否则 debug 信息会失真
- **保留 debug symbols**:Cargo.toml 里 `[profile.release] debug = true`,二进制大但 profile 准
- **多次 profile 取平均**:单次跑可能受系统状态干扰

### 系统级:perf record

更底层的:

```bash
perf record -g ./target/release/my-server
perf report
```

直接看 hot function、cache miss 等更细的指标。

---

## 16.9 Async 性能排查:tokio-console

普通 profiler 对 async 代码有局限——大部分时间花在等 IO,不是 CPU。`tokio-console` 是 Tokio 官方的 async 调试工具:

### 启用

`Cargo.toml`:

```toml
[dependencies]
tokio = { version = "1", features = ["full", "tracing"] }
console-subscriber = "0.2"
```

代码:

```rust
console_subscriber::init();
```

### 跑

```bash
cargo install tokio-console
# 一个终端跑服务
RUSTFLAGS="--cfg tokio_unstable" cargo run
# 另一个终端
tokio-console
```

显示:
- 所有 task 列表
- 每个 task 的 poll 次数、busy 时间、idle 时间
- 卡住的 task(很久没 poll、没醒)
- 锁争用情况

工程价值:Stiglab 这类 long-running async 服务,生产出问题排查 tokio-console 是关键工具。

---

## 16.10 Metrics:Prometheus 风格

Prometheus 是事实标准。Rust 生态:

- `metrics` crate:抽象层(类似 tracing)
- `metrics-exporter-prometheus`:具体 exporter

```rust
use metrics::{counter, gauge, histogram};

counter!("requests_total", 1, "method" => "GET", "path" => "/users");
gauge!("active_connections", 42.0);
histogram!("request_duration_seconds", duration);
```

启动 exporter:

```rust
use metrics_exporter_prometheus::PrometheusBuilder;

PrometheusBuilder::new()
    .with_http_listener(([0, 0, 0, 0], 9000))
    .install()?;
```

`http://localhost:9000/metrics` 暴露 Prometheus 格式的 metrics。

### 业务 metrics 命名

按 Prometheus 习惯:

- counter:`_total` 后缀(`requests_total`)
- gauge:无后缀(`active_connections`)
- histogram:`_seconds` / `_bytes` 等单位后缀(`request_duration_seconds`)

---

## 16.11 章末小结与习题

### 本章核心概念回顾

1. **测试栈分层**:单元 / 集成 / property / snapshot / e2e
2. **`#[cfg(test)]`** 让测试不进 release 二进制
3. **proptest**:声明不变量,框架随机找反例
4. **insta**:snapshot 测试,适合复杂输出
5. **mockall**:trait-based mock,但优先用 in-memory 实现
6. **criterion**:严格 microbenchmark,统计 + HTML 报告
7. **flamegraph**:可视化 profile 热点
8. **tokio-console**:async 专用调试,看 task 状态
9. **Prometheus metrics**:生产可观察性的事实标准

### 习题

#### 习题 16.1(简单)

给一个 `fn is_palindrome(s: &str) -> bool` 写至少 5 个单元测试,覆盖:空串、单字符、回文、非回文、含空格的回文。

#### 习题 16.2(中等)

给 `is_palindrome` 写 property test:
- 任何字符串 reverse 后再 reverse 等于原串
- `is_palindrome(s)` 等于 `is_palindrome(reverse(s))`

#### 习题 16.3(中等)

给 15.9 的用户 CRUD 服务写集成测试,覆盖:
- 创建用户后能 get 到
- get 不存在的用户返回 404
- delete 后再 get 返回 404

提示:用 axum 的 TestRequest,不要真起 HTTP server。

#### 习题 16.4(困难)

回到 Stiglab。给 Session 状态机加 property test:
- 任意操作序列后,Session ID 不变
- Finished 状态后不能再 start
- 状态转换时间戳单调递增

#### 习题 16.5(开放)

回顾你 Stiglab 代码的测试覆盖。问自己:
- 哪些核心逻辑覆盖不足?
- 哪些用 mock 用得过度,可以改成 in-memory 实现?
- 生产监控够吗?哪些 metric 该加?

---

### 下一章预告

Part VI 进入"深水区"。Ch 17 讲 macro——declarative 宏与 procedural 宏。

---

> **本章一句话总结**
>
> 测试 / benchmark / 可观察性是工程化的三根柱子,Rust 在每一根上都有成熟工具。掌握它们让你的代码能上生产、能演化、出问题能定位。
