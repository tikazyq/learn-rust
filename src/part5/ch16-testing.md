# Ch 16 · 测试、基准、可观测性

> 生产级 Rust 的质量保证

**核心问题**:怎么给 Rust 项目建立完整的质量保障矩阵?

Rust 自带 `cargo test`,但生产工程里"测试"远不止跑一遍 unit test。这章讲完整矩阵:**单元测试 → 集成测试 → property-based → snapshot → mock → benchmark → flamegraph → tokio-console → 内存分析**。

读完你应该能:

1. 给一个 crate 写齐三种形态的测试
2. 用 proptest 找到边界 case bug
3. 用 insta 做 snapshot 测试,理解什么时候它合适
4. 用 criterion 做严肃 benchmark(防止编译器优化掉)
5. 用 flamegraph + pprof 定位 CPU 热点

---

## 16.1 三种测试形态

### 单元测试:跟模块同文件

```rust,ignore
pub fn add(a: i32, b: i32) -> i32 { a + b }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn adds() { assert_eq!(add(2, 3), 5); }

    #[test]
    #[should_panic(expected = "overflow")]
    fn overflows() {
        let _ = add(i32::MAX, 1);
    }
}
```

- `#[cfg(test)]` 只在 `cargo test` 时编译
- 可以访问 crate 内部 `pub(crate)` 项
- `#[should_panic]` 测断言失败

### 集成测试:`tests/` 目录

```
my-crate/
├── src/
│   └── lib.rs
└── tests/
    ├── basic.rs
    ├── api.rs
    └── common/
        └── mod.rs   ← 测试间共用代码
```

```rust,ignore
// tests/api.rs
use my_crate::Client;
#[test]
fn create_then_list() {
    let c = Client::new();
    c.create("alpha").unwrap();
    assert!(c.list().contains(&"alpha".to_string()));
}
```

- 每个文件是独立 crate(单独编译)
- 只能用 `pub` API(模拟外部用户)
- 共用代码放 `tests/common/mod.rs`(注意:不是 `common.rs`,否则 cargo 把它当独立测试 crate)

### Doc-test:文档即测试

```rust,ignore
/// Returns twice the input.
///
/// # Examples
/// ```
/// assert_eq!(my_crate::double(2), 4);
/// ```
pub fn double(x: i32) -> i32 { x * 2 }
```

`cargo test` 默认连 doc-test 一起跑。文档总跟实现同步——Rust 生态的好习惯。

跑特定类型的测试:

```bash
cargo test --lib       # 只跑 src/ 里的 #[test]
cargo test --tests     # 只跑 tests/ 集成测试
cargo test --doc       # 只跑 doc-test
```

---

## 16.2 Property-based testing

普通测试给一组 input 看 output;property test 描述"对任意输入,应满足的性质",**框架自动生成大量随机输入**找反例。

```rust,ignore
use proptest::prelude::*;

proptest! {
    #[test]
    fn sort_idempotent(mut v: Vec<i32>) {
        let a = { let mut x = v.clone(); x.sort(); x };
        let b = { let mut x = a.clone(); x.sort(); x };
        prop_assert_eq!(a, b);   // 排两次跟排一次相同
    }

    #[test]
    fn round_trip(s in "[a-z]+") {
        let encoded = encode(&s);
        let decoded = decode(&encoded);
        prop_assert_eq!(s, decoded);
    }
}
```

### 真实价值

`proptest` 在十秒内试 1000+ 输入,常找到人工想不到的 case:`""`(空)、`"\0"`、超长字符串、UTF-8 边界、负数边界。

经验:**任何"自反"性质**(encode→decode、parse→print、压缩→解压)都该写 prop test。

### quickcheck 还是 proptest

| | quickcheck | proptest |
|---|---|---|
| 历史 | 更老 | 更新 |
| 自定义 generator | 麻烦 | 优雅(`prop_compose!`) |
| shrinker(自动缩小反例) | 一般 | 强 |
| 社区使用 | 老项目 | 新项目首选 |

新项目用 proptest。

---

## 16.3 Snapshot testing(insta)

```rust,ignore
use insta::assert_yaml_snapshot;

#[test]
fn snapshot_user() {
    let u = make_user();
    assert_yaml_snapshot!(u);   // 第一次跑生成 .snap 文件,后续跑对比
}
```

第一次跑:生成 `tests/snapshots/foo__snapshot_user.snap`。后续跑对比;不一致 → 测试失败。

修订快照:

```bash
cargo install cargo-insta
cargo insta review     # 交互式 review 改动
cargo insta accept     # 全部接受
```

### 适用场景

- 序列化输出(JSON / YAML / 配置文件生成)
- 编译器 / linter 的诊断信息(rust-analyzer 自己就用 insta)
- 模板渲染
- CLI help 输出

**不适合**:逻辑判断(用普通断言更清晰)。

---

## 16.4 Mock 框架(mockall)

```rust,ignore
use mockall::*;

#[automock]
trait UserRepo {
    fn get(&self, id: u64) -> Option<User>;
    fn save(&mut self, u: &User);
}

fn service(repo: &dyn UserRepo, id: u64) -> Option<String> {
    repo.get(id).map(|u| u.name)
}

#[test]
fn test_service() {
    let mut mock = MockUserRepo::new();
    mock.expect_get()
        .with(predicate::eq(42))
        .returning(|_| Some(User { id: 42, name: "Bob".into() }));

    assert_eq!(service(&mock, 42), Some("Bob".into()));
}
```

### 工程经验

Rust 社区对 mock 的态度比 Java / C# **保守**:**优先用真实实现 + 测试 stub**。

- 用 trait 抽象边界(DB / HTTP / message queue)
- 测试时**实现一个内存版**而不是 mock
- 只有交互复杂(call order / call count assertion)时才上 mockall

为什么:trait 抽象边界后,内存版实现写一遍能给所有测试共用,可读性比一堆 `.expect_xxx().returning(...)` 好得多。

---

## 16.5 criterion 微基准

```toml
[dev-dependencies]
criterion = "0.5"

[[bench]]
name = "my_bench"
harness = false
```

```rust,ignore
// benches/my_bench.rs
use criterion::{black_box, criterion_group, criterion_main, Criterion};

fn fib(n: u64) -> u64 {
    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

fn bench_fib(c: &mut Criterion) {
    c.bench_function("fib 20", |b| b.iter(|| fib(black_box(20))));
}

criterion_group!(benches, bench_fib);
criterion_main!(benches);
```

```bash
cargo bench
```

### 为什么必须 black_box

```rust,ignore
b.iter(|| fib(20));            // 编译器可能算出常量 6765,优化掉整个调用!
b.iter(|| fib(black_box(20)));  // 阻止编译器看穿参数
```

`black_box` 是**优化屏障**——告诉编译器"假装这个值你不知道"。所有 input 必须用它包,否则跑出来的可能是空循环。

### criterion 的优势

- 统计分析(置信区间、回归检测)
- 自动跟历史对比(`target/criterion/` 缓存)
- HTML 报告

---

## 16.6 cargo flamegraph

```bash
cargo install flamegraph
cargo flamegraph --bin my-app -- --some-args
```

生成 `flamegraph.svg`,浏览器打开。**纵轴是调用栈,横轴是 CPU 时间**。看哪个函数最宽 → 那就是热点。

依赖:Linux 上需要 `perf`,macOS 上需要 `dtrace`(且 SIP 关闭)。生产容器排查时,Linux 直接装 perf 跑。

### 解读

- **平坦宽的栈** → CPU 真在那里转
- **窄但很深** → 深递归 / 长调用链,可能 inline 没起作用
- **大段 `unknown` / `[unknown]`** → 缺 debug info,Cargo.toml 加 `debug = "line-tables-only"` for release

---

## 16.7 tokio-console(见 13.9)

```toml
console-subscriber = "0.4"
```

```rust,ignore
console_subscriber::init();
```

```bash
RUSTFLAGS="--cfg tokio_unstable" cargo run
tokio-console
```

查"async 任务为什么卡"。前提:跑的是 Tokio runtime。

---

## 16.8 pprof-rs:容器友好的 CPU profiling

```toml
[dependencies]
pprof = { version = "0.14", features = ["flamegraph", "criterion"] }
```

```rust,ignore
use pprof::ProfilerGuard;

let guard = ProfilerGuard::new(100).unwrap();   // 100Hz sampling
// ... 跑你的代码 ...
if let Ok(report) = guard.report().build() {
    let file = std::fs::File::create("flamegraph.svg").unwrap();
    report.flamegraph(file).unwrap();
}
```

**优势**:不需要 perf 权限,容器里也能跑。生产服务可暴露一个 `/debug/pprof` endpoint,运行时按需拿 profile。

---

## 16.9 内存分析

### heaptrack(Linux)

```bash
heaptrack ./my-app
heaptrack --analyze heaptrack.my-app.12345.gz
```

记录每次 malloc / free,GUI 分析:总分配、生命周期长的分配、leak。

### dhat-rs(跨平台,Cargo 集成)

```toml
[dependencies]
dhat = "0.3"
```

```rust,ignore
#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

fn main() {
    let _profiler = dhat::Profiler::new_heap();
    // ...
}
```

跑完生成 `dhat-heap.json`,丢 https://nnethercote.github.io/dh_view/dh_view.html 看。

### bytehound(中文社区有人用)

更现代的 heap profiler,UI 友好。Linux 上推荐。

---

## 16.10 测试隔离

### 文件系统

`tempfile` crate 给临时目录,drop 时自动清理:

```rust,ignore
use tempfile::tempdir;
let dir = tempdir().unwrap();
let path = dir.path().join("foo.txt");
// ... 用完
// dir drop 时整个临时目录递归删除
```

### 数据库

事实标准:**每个测试函数一个事务,测完 rollback**。

```rust,ignore
async fn test_db(pool: &PgPool) {
    let mut tx = pool.begin().await.unwrap();
    // ... 操作
    tx.rollback().await.unwrap();   // 不 commit
}
```

更高级:`sqlx::test` macro 自动给每个测试函数一个**独立 schema**,完全隔离。

### 外部服务

- **wiremock** / **httpmock**:启个本地 HTTP server,fixture 化外部 API
- **testcontainers-rs**:测试启动 docker 容器(真 Postgres、真 Redis)。CI 慢但隔离最干净

---

## 习题

1. 给一个简单的 parser 加上 `proptest` 测 "parse → print → parse 不变"。
2. 给一个 JSON 配置序列化加上 `insta::assert_json_snapshot!`,review 一次。
3. 写 criterion benchmark 对比 `Vec<i32>::sort` 跟自己实现的 quicksort,故意忘记 `black_box`,看结果失真。
4. 用 `cargo flamegraph` profile 一个有 hot loop 的程序,找到热点。
5. 用 `mockall` 写一个 HTTP client 的测试。再用"trait + 内存版实现"重写,对比可读性。

---

> **本章一句话总结**
>
> 测试和可观测性不是上线后才考虑的事。Rust 工具链让这些事情比 Go / C# 更系统化——但你得主动把工具一个个装起来,默认啥也没有。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
