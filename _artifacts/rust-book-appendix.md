# 附录

## A. Go → Rust 翻译速查表

| Go | Rust |
|---|---|
| `var x int = 5` | `let x: i32 = 5;` |
| `x := 5` | `let x = 5;` |
| `var x int` | `let mut x: i32 = 0;` /(必须初始化或后续显式赋值) |
| `func foo(a int) int { return a + 1 }` | `fn foo(a: i32) -> i32 { a + 1 }` |
| `func foo() (int, error)` | `fn foo() -> Result<i32, Error>` |
| `if err != nil { return err }` | `let x = something?;` |
| `[]int{1, 2, 3}` | `vec![1, 2, 3]` |
| `map[string]int{}` | `HashMap::<String, i32>::new()` |
| `make([]int, 0, 10)` | `Vec::with_capacity(10)` |
| `len(s)` | `s.len()` |
| `append(s, x)` | `s.push(x)` |
| `for i, x := range v { ... }` | `for (i, x) in v.iter().enumerate() { ... }` |
| `for k, v := range m { ... }` | `for (k, v) in &m { ... }` |
| `struct { X int; Y int }` | `struct Foo { x: i32, y: i32 }` |
| `interface { Foo() }` | `trait Foo { fn foo(&self); }` |
| `(impl 隐式)` | `impl Foo for MyType { fn foo(&self) { ... } }` |
| `nil` 检查 | `Option<T>` + `match` / `if let` |
| `panic("...")` | `panic!("...")` |
| `recover()` | `std::panic::catch_unwind(|| { ... })` |
| `chan int` | `tokio::sync::mpsc::channel::<i32>()` |
| `select { case ... }` | `tokio::select! { ... }` |
| `go f()` | `tokio::spawn(async { f().await })` |
| `sync.Mutex` | `std::sync::Mutex<T>` |
| `sync.WaitGroup` | `tokio::task::JoinSet` |
| `time.Sleep` | `tokio::time::sleep(...).await` |
| `context.Context` | `CancellationToken` + `select!` |
| `json.Marshal` | `serde_json::to_string` |
| `defer` | `Drop` trait / scope guard |

## B. C# → Rust 翻译速查表

| C# | Rust |
|---|---|
| `var x = 5;` | `let x = 5;` |
| `int x = 5;` | `let x: i32 = 5;` |
| `public string Name { get; set; }` | `pub struct Foo { name: String }` + getter/setter |
| `class Foo { ... }` | `struct Foo { ... }` + `impl Foo { ... }` |
| `interface IFoo { void Bar(); }` | `trait Foo { fn bar(&self); }` |
| `abstract class` | trait + default methods |
| `null` | `Option<T>::None` |
| `T?` (nullable) | `Option<T>` |
| `try / catch / finally` | `Result<T, E>` + `?` |
| `throw new Exception("...")` | `return Err(...)` |
| `async Task<int>` | `async fn ... -> i32` |
| `await x` | `x.await` |
| `Task.WhenAll(...)` | `futures::future::join_all(...).await` |
| `List<T>` | `Vec<T>` |
| `Dictionary<K, V>` | `HashMap<K, V>` |
| `IEnumerable<T>` | `impl Iterator<Item = T>` |
| `linq.Where(p)` | `.filter(p)` |
| `linq.Select(f)` | `.map(f)` |
| `linq.ToList()` | `.collect::<Vec<_>>()` |
| `using (var x = ...) { }` | scope-based Drop:`{ let x = ...; ... }` |
| `lock (obj) { ... }` | `let _g = mutex.lock(); ...` |
| `[Serializable]` | `#[derive(Serialize, Deserialize)]` |
| Generics `<T>` | Generics `<T>`(语法相似但语义不同——见 Ch 7) |
| `T : new()` 约束 | `T: Default` |
| `T : IComparable<T>` | `T: Ord` |
| `Action<T>` | `impl Fn(T)` / `Box<dyn Fn(T)>` |
| `Func<T, R>` | `impl Fn(T) -> R` |
| extension method | trait + blanket impl |
| `delegate` | function pointer / `Fn` trait |
| `nameof(x)` | `stringify!(x)` (宏) |
| `record` | `#[derive(Clone, PartialEq, Debug)] struct` |

## C. Cargo / Clippy 速查

### 常用命令

```bash
cargo new <name>            # 新 binary crate
cargo new --lib <name>      # 新 library crate
cargo check                 # 类型检查(快)
cargo build                 # 编译 debug
cargo build --release       # 编译 release
cargo run                   # 编译并运行
cargo run -- arg1 arg2      # 传参数
cargo test                  # 跑测试
cargo test <name>           # 跑名字含 name 的
cargo test --release        # release 模式测试
cargo doc --open            # 生成文档并打开
cargo clippy                # lint
cargo clippy -- -D warnings # warnings 当 error
cargo fmt                   # 格式化
cargo fmt --check           # 检查格式不修改
cargo update                # 升级 Cargo.lock
cargo tree                  # 显示依赖树
cargo tree -i <crate>       # 反向依赖
cargo expand                # 展开宏(需 cargo install cargo-expand)
cargo audit                 # 漏洞扫描
cargo deny                  # license / 重复依赖 / 漏洞综合检查
cargo install <crate>       # 全局安装
cargo bench                 # benchmark
cargo miri test             # Miri 跑 UB 检测(nightly)
```

### 重要的 clippy lint

| Lint | 用途 |
|---|---|
| `clippy::unwrap_used` | 拦截 `.unwrap()` |
| `clippy::expect_used` | 拦截 `.expect()` |
| `clippy::missing_docs_in_private_items` | 文档强制 |
| `clippy::pedantic` | 严格模式(部分有用,部分太严) |
| `clippy::cognitive_complexity` | 函数过于复杂 |
| `clippy::too_many_arguments` | 参数过多 |
| `clippy::large_enum_variant` | enum variant 太大,考虑 Box |
| `clippy::needless_clone` | 不必要的 clone |
| `clippy::redundant_clone` | 同上 |
| `clippy::or_fun_call` | `.unwrap_or(expensive())` 应改用 `unwrap_or_else` |

CI 强烈推荐:`cargo clippy -- -D warnings`,任何 lint 都不放过。

## D. 编译器错误码索引(高频)

| 错误码 | 含义 |
|---|---|
| E0277 | trait bound 不满足 |
| E0382 | 用了被 move 走的值 |
| E0384 | 给 immutable 变量赋值 |
| E0432 | use 路径不存在 |
| E0499 | 同时有多个 &mut |
| E0502 | 同时有 &mut 和 & |
| E0507 | 不能从借用中 move |
| E0515 | 返回了对临时值的引用 |
| E0521 | borrowed data escapes outside of closure |
| E0597 | 借用比被借用值活得久 |
| E0599 | 类型没有这个方法 |
| E0716 | 临时值被 drop |

任何错误 `rustc --explain EXXXX` 看详细解释。

## E. 推荐阅读路径

### 必读

1. **The Rust Programming Language**(官方书,免费):`https://doc.rust-lang.org/book/`
2. **Rust by Example**:`https://doc.rust-lang.org/rust-by-example/`
3. **The Rustonomicon**(unsafe Rust 圣经):`https://doc.rust-lang.org/nomicon/`
4. **Async Book**:`https://rust-lang.github.io/async-book/`
5. **Tokio Tutorial**:`https://tokio.rs/tokio/tutorial`

### 进阶

6. **Rust Atomics and Locks**(Mara Bos):并发底层
7. **Programming Rust, 2nd ed**(Blandy, Orendorff, Tindall):系统性强
8. **Zero To Production In Rust**(Luca Palmieri):工程实战
9. **Rust for Rustaceans**(Jon Gjengset):中高级技术细节

### 视频

- Jon Gjengset 的 YouTube channel(Crust of Rust 系列):深度技术讲解
- Ryan Levick 的 channel:轻松入门
- ThePrimeagen:实战类

### 跟踪生态

- Rust Blog:`https://blog.rust-lang.org/`
- This Week in Rust:`https://this-week-in-rust.org/`(每周通讯,生态动态)
- Rust Subreddit:`/r/rust`

### 阅读源码

- `tokio`:async runtime 的现代典范
- `axum`:tower-based web framework
- `sqlx`:编译期 SQL 校验
- `serde`:序列化库,trait 系统的极致运用
- `clap`:CLI parser,macro 大量运用

## F. 这本书的 12 周学习节奏(回顾)

| 周 | 章节 | 重点 |
|---|---|---|
| Week 1 | Ch 1-2 | 心智迁移、ownership |
| Week 2 | Ch 3 | borrow + lifetime,跨这关就 80% 了 |
| Week 3 | Ch 4-5 | enum、错误处理,工程地道度上一个台阶 |
| Week 4 | Ch 6-7 | trait + 泛型,类型系统主要工具 |
| Week 5 | Ch 8-9 | 智能指针 + 内部可变性 |
| Week 6 | Ch 10 | 闭包 + iterator |
| Week 7 | Ch 11 | 线程并发 |
| Week 8 | Ch 12-13 | async / Tokio,这是你 Stiglab 的核心 |
| Week 9 | Ch 14-15 | Cargo + Axum,生产栈 |
| Week 10 | Ch 16 | 测试、benchmark、可观察性 |
| Week 11 | Ch 17-18 | 宏 + unsafe(深水区) |
| Week 12 | Ch 19-20 | FFI + capstone |

**实操建议**:每章读完 + 写习题 + 找 Stiglab/Onsager 里相关代码看一段。

---

> **整本书一句话总结**
>
> Rust 给你的不是"更快的代码",是"工程上的确定性"——内存安全、并发安全、错误显式、契约清晰。代价是前几周心智迁移痛苦,但跨过 borrow checker 这关之后,你写出来的代码会让你信任。
