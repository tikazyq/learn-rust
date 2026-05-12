# 附录 B · Go → Rust 概念翻译大全

> 200+ 条对应关系

**核心问题**:Go 中的每个概念在 Rust 中对应什么?

这附录给你一个"翻译字典":Go 概念左 → Rust 概念右。**注意**:很多翻译不是 1:1,Rust 常常**没有完全等价物**,但你能找到"做相似事情的工具"。

---

## B.1 基础类型与字面量

| Go | Rust | 备注 |
|---|---|---|
| `int` | `i32` / `i64` / `isize` | Go `int` 平台相关,Rust 倾向显式 |
| `int8 / int16 / int32 / int64` | `i8 / i16 / i32 / i64` | 一致 |
| `uint8 (byte)` | `u8` | 一致 |
| `float32 / float64` | `f32 / f64` | 一致 |
| `bool` | `bool` | 一致 |
| `string` (UTF-8) | `String` / `&str` | Rust 区分 owned / borrowed |
| `[]byte` | `Vec<u8>` / `&[u8]` | 同上 |
| `rune` | `char` (4 字节 Unicode scalar) | 一致 |
| `nil` | `Option::None` | Rust 没有 null |
| `true / false` | `true / false` | 一致 |
| `0x1f`, `1_000_000` | `0x1f`, `1_000_000` | 字面量分隔符一致 |
| `const Pi = 3.14` | `const PI: f64 = 3.14;` | Rust 要求类型 |

---

## B.2 控制流

| Go | Rust |
|---|---|
| `if x > 0 { ... } else { ... }` | `if x > 0 { ... } else { ... }` |
| `for i := 0; i < n; i++ {}` | `for i in 0..n {}` |
| `for _, v := range items {}` | `for v in &items {}` |
| `for { ... } / break / continue` | `loop { ... } / break / continue` |
| `switch x { case 1: ... }` | `match x { 1 => ..., _ => ... }` |
| `switch { case x>0: ... }` | `match x { _ if x > 0 => ..., _ => ... }` |
| `defer f()` | `Drop` trait / RAII / scopeguard crate |
| `panic("msg")` | `panic!("msg")` |
| `recover()` | `std::panic::catch_unwind` |
| `goto` | 没有 |

---

## B.3 函数与方法

| Go | Rust |
|---|---|
| `func add(a, b int) int { return a+b }` | `fn add(a: i32, b: i32) -> i32 { a + b }` |
| `func (s Type) M() {}`(value receiver) | `impl Type { fn m(self) {} }` |
| `func (s *Type) M() {}`(pointer receiver) | `impl Type { fn m(&mut self) {} }` |
| 多返回值 `(a, b, err)` | `(a, b, Result)` 或 tuple |
| variadic `args ...int` | `args: &[i32]` 或 slice / `Vec` |
| closure `func(x int) int { return x+1 }` | `\|x: i32\| x + 1`(或 `move \|...\| ...`) |
| 函数作参数 `f func(int) int` | `f: impl Fn(i32) -> i32` 或 `Box<dyn Fn...>` |
| 命名返回值 | 没有(用 tuple 解构) |

---

## B.4 struct 与 interface

| Go | Rust |
|---|---|
| `type Point struct { X, Y float64 }` | `struct Point { x: f64, y: f64 }` |
| `Point{X:1, Y:2}` | `Point { x: 1.0, y: 2.0 }` |
| anonymous struct | tuple struct `struct Wrap(i32)` 或 `struct A { x: i32 }` |
| embedded struct(组合) | 显式字段 + 实现 `Deref`(谨慎) |
| `interface { Read(p []byte) (int, error) }` | `trait Read { fn read(&mut self, buf: &mut [u8]) -> Result<usize, Error>; }` |
| `interface{}` (empty) | `Box<dyn Any>` |
| structural typing(隐式实现) | nominal,显式 `impl Trait for Type` |
| type assertion `v.(*T)` | `(x as &dyn Any).downcast_ref::<T>()` |
| 标签 `\`json:"name"\`` | `#[serde(rename = "name")]` |

---

## B.5 错误处理

| Go | Rust |
|---|---|
| `if err != nil { return err }` | `?` 运算符 / `Result::map_err` |
| `error` interface | `Result<T, E>` + `std::error::Error` trait |
| `errors.New("msg")` | `anyhow!("msg")` / 自定义 enum |
| `fmt.Errorf("ctx: %w", err)` | `err.context("ctx")`(anyhow)|
| `errors.Is(err, ErrFoo)` | `matches!(err, AppError::Foo)` |
| `errors.As(err, &target)` | 用 enum 匹配 |
| panic / recover | `panic!` / `catch_unwind`(不推荐做 error handling) |

---

## B.6 并发

| Go | Rust |
|---|---|
| `go f()` | `std::thread::spawn(\|\| f())` 或 `tokio::spawn(async { f().await })` |
| `chan T` | `std::sync::mpsc::channel()` / `tokio::sync::mpsc` / `crossbeam::channel` |
| `select { case ... }` | `tokio::select!` / `crossbeam::select!` |
| `sync.Mutex` | `std::sync::Mutex<T>` / `tokio::sync::Mutex<T>` / `parking_lot::Mutex` |
| `sync.RWMutex` | `std::sync::RwLock<T>` / `parking_lot::RwLock` |
| `sync.WaitGroup` | `tokio::task::JoinSet` / `Arc<AtomicUsize>` + Notify |
| `sync.Once` | `std::sync::OnceLock<T>` |
| `context.Context` | `tokio_util::sync::CancellationToken` + propagate via async fn |
| `context.WithTimeout` | `tokio::time::timeout(dur, fut)` |
| `atomic.AddInt32` | `AtomicI32::fetch_add(1, Ordering::SeqCst)` |
| GC | ownership / Drop / Rc / Arc |

---

## B.7 包管理

| Go | Rust |
|---|---|
| `go.mod` | `Cargo.toml` |
| `go.sum` | `Cargo.lock` |
| `module example.com/foo` | `[package] name = "foo"` |
| `import "fmt"` | `use std::fmt;` |
| `package foo` | `mod foo;` / 一个 crate 一个名字 |
| `internal/` 包 | `pub(crate)` 可见性 |
| GOPATH / GOPROXY | crates.io / `[source.crates-io]` |
| vendoring | `cargo vendor` |
| `go mod tidy` | `cargo update` + `cargo udeps` |
| build tags | feature flags |

---

## B.8 测试

| Go | Rust |
|---|---|
| `func TestX(t *testing.T)` | `#[test] fn x() {}` |
| `t.Errorf / t.Fatalf` | `assert! / assert_eq! / panic!` |
| Benchmark `func BenchmarkX(b *testing.B)` | criterion `c.bench_function("x", ...)` |
| Example | doc-test ` ```rust ` |
| `go test ./...` | `cargo test` |
| race detector `-race` | Miri / `RUSTFLAGS="-Z sanitizer=thread"` |
| coverage `go test -cover` | `cargo llvm-cov` / `tarpaulin` |
| testing/quick | `proptest` / `quickcheck` |

---

## B.9 常用标准库

| Go | Rust |
|---|---|
| `fmt.Println` | `println!` |
| `fmt.Sprintf` | `format!` |
| `strings.Split` | `s.split(',').collect::<Vec<_>>()` |
| `strings.Builder` | `String::new()` + `push_str` |
| `bytes.Buffer` | `Vec<u8>` 或 `bytes::BytesMut` |
| `encoding/json` | `serde_json` |
| `net/http` server | `axum` / `actix-web` |
| `net/http` client | `reqwest` |
| `database/sql` | `sqlx` / `diesel` |
| `os.Open` | `std::fs::File::open` |
| `time.Now()` | `std::time::Instant::now()` / `chrono::Utc::now()` |
| `time.Sleep` | `std::thread::sleep` / `tokio::time::sleep` |
| `log` | `log` + `env_logger` 或 `tracing` |
| `flag` package | `clap` crate |
| `os.Getenv` | `std::env::var` |
| `regexp` | `regex` crate |
| `crypto/...` | `ring` / `rustls` / `RustCrypto` 套件 |
| `io.Reader / io.Writer` | `std::io::Read / Write` |

---

## B.10 生态对应

| 用途 | Go | Rust |
|---|---|---|
| Web 框架 | gin / chi / echo | axum / actix-web |
| RPC | grpc-go | tonic |
| 数据库 ORM | gorm / sqlx | sqlx / sea-orm / diesel |
| 日志 / 观测 | zap / zerolog | tracing |
| 配置 | viper | config / figment |
| CLI | cobra / urfave | clap |
| 序列化 | encoding/json / proto | serde + serde_json / prost |
| 任务调度 | robfig/cron | tokio-cron-scheduler |
| 缓存 / KV | redigo / go-redis | redis-rs / fred |
| 队列 | NATS / Kafka client | nats / rdkafka |
| 测试 mock | gomock | mockall |
| 性能分析 | pprof | pprof-rs / cargo flamegraph |
| 文档站点 | hugo / docusaurus | mdBook(本书在用) |

---

## 几条战略级差异

1. **Go 没有 borrow checker;Rust 没有 GC** —— 编码风格的根本差异
2. **Go 的 zero-value 设计 vs Rust 的"必须显式初始化"** —— Rust 让你少踩"看似为空,其实未定义"的坑
3. **Go 拥抱"代码量换显式";Rust 拥抱"类型表达力"** —— Go 经典 `if err != nil`;Rust `?` 一个字符
4. **Go `interface{}` 万能;Rust 鄙视 `dyn Any`** —— Rust 偏 generic / trait bound,运行时反射几乎不用
5. **Go 是 productivity-first;Rust 是 correctness-first** —— 两个语言适合的项目类型不同

---

> **本附录用法**:遇到不熟悉的 Rust 概念时,搜表里的 Go 对应物,先有大致印象,再读正文章节。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
