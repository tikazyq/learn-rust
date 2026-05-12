# 附录 D · Cargo / Clippy 速查

> 命令与配置的快速参考

**核心问题**:Cargo 常用命令与 Clippy lint 一览。

放手边,需要时翻。

---

## D.1 cargo 基础命令

```bash
# 项目
cargo new my-app                # 新建 binary
cargo new --lib my-lib          # 新建 library
cargo init                      # 在当前目录初始化

# 编译
cargo check                     # 只检查类型,不生成 binary(快)
cargo build                     # debug build
cargo build --release           # release build,优化开启
cargo build --target x86_64-unknown-linux-musl   # 交叉编译

# 运行
cargo run                       # 跑 default binary
cargo run --bin server          # 跑指定 binary
cargo run --example foo         # 跑 examples/foo.rs
cargo run --release             # release 跑
cargo run -- --port 8080        # 把参数传给程序(-- 后)

# 测试
cargo test                      # 跑全部
cargo test some_test_name       # 跑匹配名字的测试
cargo test --lib                # 只 src/ 单元测试
cargo test --tests              # 只 tests/ 集成测试
cargo test --doc                # 只 doc-test
cargo test -- --nocapture       # 显示 println!
cargo test -- --test-threads=1  # 串行(适合改全局状态的测试)

# 格式化 + lint
cargo fmt                       # 格式化
cargo fmt --check               # 检查是否已格式化(CI 用)
cargo clippy                    # lint
cargo clippy --fix              # 自动修复部分
cargo clippy -- -D warnings     # 警告变错误

# 文档
cargo doc                       # 生成 target/doc/...
cargo doc --open                # 打开浏览器
cargo doc --no-deps             # 不生成依赖文档(快)

# 依赖
cargo update                    # 更新 Cargo.lock
cargo update -p tokio --precise 1.40.0   # 锁定具体版本
cargo tree                      # 看依赖树
cargo tree -d                   # 重复依赖检查
```

---

## D.2 cargo 高级命令(常装的子命令)

```bash
# 安装
cargo install cargo-edit cargo-expand cargo-watch cargo-nextest

# cargo-edit
cargo add tokio --features full           # 加依赖
cargo add tokio@1                          # 指定版本
cargo rm serde                             # 移除
cargo upgrade                              # 升级所有依赖到 latest

# cargo-expand:看宏 / async 展开
cargo expand --bin myapp
cargo expand --lib path::module
cargo expand --tests test_name

# cargo-watch:文件改动自动跑命令
cargo watch -x check
cargo watch -x 'test some_test -- --nocapture'

# cargo-nextest:更快的 test runner
cargo nextest run

# 二进制体积分析
cargo install cargo-bloat
cargo bloat --release             # 看哪些函数最大
cargo bloat --release --crates    # 看哪个 crate 最大

# 未使用依赖
cargo install cargo-udeps
cargo +nightly udeps              # 找出 [dependencies] 里没用上的

# 过期依赖
cargo install cargo-outdated
cargo outdated

# 安全 / license 审计
cargo install cargo-audit cargo-deny
cargo audit
cargo deny check

# 覆盖率
cargo install cargo-llvm-cov
cargo llvm-cov --html

# 模糊测试
cargo install cargo-fuzz
cargo fuzz init
cargo fuzz run target_name
```

---

## D.3 常用 Cargo.toml 配置

### dependency 写法

```toml
[dependencies]
tokio = "1"                                          # 最新 1.x
tokio = { version = "1.40", features = ["full"] }    # 指定特性
local-lib = { path = "../local-lib" }                # 本地
git-lib = { git = "https://github.com/x/y.git", branch = "main" }
git-lib = { git = "https://...", tag = "v0.1" }
git-lib = { git = "https://...", rev = "abcdef" }    # 锁 commit
foo = { version = "1", default-features = false, features = ["bar"] }
foo = { version = "1", optional = true }             # feature 才启用
```

### profile

```toml
[profile.release]
opt-level = 3                # 0-3 / "s" / "z" (size)
lto = "thin"                 # "fat" / "thin" / false
codegen-units = 1            # 1 最优,默认 16
strip = "symbols"            # 减小二进制
debug = false                # 不加 debug info
panic = "abort"              # 不展开栈(更小)
overflow-checks = false

[profile.dev]
opt-level = 1                # dev build 也开一点优化
debug = "line-tables-only"   # 调用栈够用,体积更小
incremental = true

[profile.bench]
debug = true                 # 让 flamegraph 看得见名字

[profile.release-with-debug]   # 自定义 profile
inherits = "release"
debug = true
strip = "none"
```

### feature 写法

```toml
[features]
default = ["pg", "tls"]
pg = ["dep:sqlx-postgres"]
mysql = ["dep:sqlx-mysql"]
tls = ["dep:rustls", "dep:rustls-pemfile"]
unstable = []                # 仅启用 #[cfg(feature = "unstable")] 代码块

[dependencies]
sqlx-postgres = { version = "0.8", optional = true }
sqlx-mysql    = { version = "0.8", optional = true }
rustls        = { version = "0.23", optional = true }
rustls-pemfile= { version = "2", optional = true }
```

### 镜像 / 私有源

```toml
# .cargo/config.toml
[source.crates-io]
replace-with = "ustc"

[source.ustc]
registry = "https://mirrors.ustc.edu.cn/crates.io-index"

# 私有源
[registries.my-corp]
index = "ssh://git@host/my-registry"
```

### workspace

```toml
[workspace]
members = ["crates/*"]
resolver = "2"

[workspace.package]
version = "0.1.0"
edition = "2021"

[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
```

### `[patch]` 覆盖依赖

```toml
[patch.crates-io]
serde = { git = "https://github.com/serde-rs/serde", branch = "main" }
```

---

## D.4 Clippy 常见 lint

按类别(`clippy::category`):

### `clippy::correctness`(默认 deny)

| Lint | 含义 |
|---|---|
| `clippy::approx_constant` | 用了近似常量(0.999... 而非 std::f64::consts::PI) |
| `clippy::wrong_self_convention` | `to_x` 应该 `&self`,`into_x` 应该 `self` |
| `clippy::eq_op` | `x == x` 永远 true |
| `clippy::erasing_op` | `x * 0` 之类 |

### `clippy::style`

| Lint | 含义 |
|---|---|
| `clippy::needless_return` | `return x;` 在末尾(应该 `x`) |
| `clippy::collapsible_if` | `if a { if b { ... } }` 可合并 |
| `clippy::redundant_field_names` | `Foo { x: x }` 可写 `Foo { x }` |
| `clippy::let_and_return` | `let x = ...; x` 可直接 `...` |
| `clippy::single_match` | `match x { A => ..., _ => () }` 用 `if let` |

### `clippy::complexity`

| Lint | 含义 |
|---|---|
| `clippy::needless_borrow` | `&&x` 多余 |
| `clippy::unnecessary_unwrap` | `if x.is_some() { x.unwrap() }` 用 if let |
| `clippy::useless_conversion` | `String::from(s.to_string())` 多余 |
| `clippy::map_unwrap_or` | `.map(...).unwrap_or(...)` 用 `.map_or(...)` |

### `clippy::perf`

| Lint | 含义 |
|---|---|
| `clippy::redundant_clone` | clone 多余 |
| `clippy::large_enum_variant` | enum 一个变体远大于其他(浪费内存) |
| `clippy::format_in_format_args` | `format!("{}", format!(...))` 嵌套 |
| `clippy::useless_vec` | `&vec![1, 2, 3]` 应该 `&[1, 2, 3]` |

### `clippy::pedantic`(默认不开)

更严格,可选开。**生产 crate 推荐**:

```rust,ignore
#![warn(clippy::pedantic)]
#![allow(clippy::module_name_repetitions)]   // 觉得太烦的关掉
```

### 整 crate 配置

```rust,ignore
// crate root
#![warn(clippy::all, clippy::pedantic)]
#![warn(missing_docs)]
#![deny(unsafe_code)]      // 整个 crate 禁 unsafe
#![forbid(unsafe_code)]    // 更严:连 #[allow] 也覆盖不了
```

---

## D.5 rustfmt 配置(`rustfmt.toml`)

```toml
# 行宽
max_width = 100

# import 整理
imports_granularity = "Crate"   # 把 use 按 crate 合并
group_imports = "StdExternalCrate"
reorder_imports = true

# 字符串 / 数组格式
use_field_init_shorthand = true
use_try_shorthand = true

# 调用链
chain_width = 80
fn_call_width = 80

# 注释
wrap_comments = true
comment_width = 100
normalize_comments = true

# 函数参数
fn_params_layout = "Tall"

# trailing comma
trailing_comma = "Vertical"

# 把 fn body 短的并到一行
fn_single_line = false
```

`unstable_features = true` 后能用更多选项,但需要 nightly rustfmt。

---

## 常用 CI 套路

```yaml
- run: cargo fmt --check
- run: cargo clippy --all-targets --all-features -- -D warnings
- run: cargo test --all-features
- run: cargo audit
- run: cargo deny check
```

任何 PR 都过这五关 → 代码质量底线有了。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
