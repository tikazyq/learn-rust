# 第 14 章 · Cargo、Workspace、依赖管理

> "Cargo is what makes Rust feel modern. Without it, the language would be 70% as good."

如果你来自 Go(go mod 还行)、Node.js(npm 混乱)、Java(Maven 复杂)、Python(pip / poetry / uv / conda / ...),你会很快爱上 Cargo——它是当今最优秀的语言级包管理器之一。

读完这章你应该能:

1. 配置一个合理的 Cargo.toml,知道每个字段的工程意义
2. 设计 workspace,把 monorepo 跑顺
3. 用 feature flag 做条件编译,避免常见反模式
4. 编译时间长?知道怎么优化

---

## 14.1 Cargo.toml 全字段解读

一个生产项目的典型 Cargo.toml:

```toml
[package]
name = "my-service"
version = "0.3.0"
edition = "2021"
rust-version = "1.75"
description = "Stiglab Control Plane"
license = "Apache-2.0"
repository = "https://github.com/stiglab/stiglab"
readme = "README.md"

[dependencies]
tokio = { version = "1.35", features = ["full"] }
axum = "0.7"
serde = { version = "1.0", features = ["derive"] }
sqlx = { version = "0.7", features = ["runtime-tokio", "postgres"] }
anyhow = "1.0"
tracing = "0.1"

[dev-dependencies]
tokio-test = "0.4"
mockall = "0.12"

[build-dependencies]
prost-build = "0.12"

[features]
default = ["postgres"]
postgres = ["sqlx/postgres"]
mysql = ["sqlx/mysql"]

[profile.release]
opt-level = 3
lto = "fat"
codegen-units = 1
strip = true

[profile.dev]
opt-level = 0
debug = true
```

逐字段说明:

### `[package]`

| 字段 | 含义 |
|---|---|
| `name` | crate 名,publish 时是唯一的 |
| `version` | semver 版本号 |
| `edition` | "2015" / "2018" / "2021" / "2024",决定语言特性集 |
| `rust-version` | 最低支持的 Rust 版本(MSRV),Cargo 会拦下不兼容版本 |
| `description` / `license` / etc. | crates.io 元数据 |

### `[dependencies]` 写法

```toml
tokio = "1.35"                                       # 最简
tokio = { version = "1.35" }                         # 等价
tokio = { version = "1.35", features = ["full"] }    # 启用 feature
tokio = { path = "../tokio" }                        # 本地路径
tokio = { git = "https://github.com/tokio-rs/tokio", rev = "abc123" }  # git
tokio = { version = "1.35", optional = true }        # optional(需要 feature 启用)
```

### Semver 含义

`tokio = "1.35"` 表示 `>=1.35.0, <2.0.0`。Cargo 会选择满足这个范围的最新版本。

如果你想锁死版本:`tokio = "=1.35.0"`。生产代码很少这么做,因为 Cargo.lock 已经锁死了具体版本。

### `Cargo.lock`

`Cargo.lock` 记录构建时实际用的版本。最佳实践:

- **应用程序**:lock 文件 commit 到 git,保证可重现构建
- **库**:lock 文件 **不** commit(让下游自己 resolve),Cargo 也默认 gitignore

### `[dev-dependencies]`

只在跑测试和 example 时编译,production 构建不包含:

```toml
[dev-dependencies]
tokio-test = "0.4"
```

### `[build-dependencies]`

`build.rs` 用的依赖,跟运行时无关:

```toml
[build-dependencies]
prost-build = "0.12"
```

---

## 14.2 Workspace:monorepo 的标准做法

Stiglab / Onsager 这类项目,代码会自然分成多个 crate(API、core、CLI、utility 等)。workspace 把它们组织在一个 git 仓库:

### workspace 根的 Cargo.toml

```toml
[workspace]
resolver = "2"
members = [
    "crates/control-plane",
    "crates/agent",
    "crates/shared",
    "crates/cli",
]

[workspace.dependencies]
tokio = { version = "1.35", features = ["full"] }
serde = { version = "1.0", features = ["derive"] }
anyhow = "1.0"
tracing = "0.1"

[workspace.package]
version = "0.3.0"
edition = "2021"
license = "Apache-2.0"
```

### 子 crate 引用 workspace 依赖

```toml
# crates/control-plane/Cargo.toml
[package]
name = "stiglab-control-plane"
version.workspace = true
edition.workspace = true
license.workspace = true

[dependencies]
tokio.workspace = true                          # 直接用 workspace 定义的
serde.workspace = true
axum = "0.7"                                    # 子 crate 自己的依赖
shared = { path = "../shared" }                 # 引用同 workspace 的另一个 crate
```

### workspace 的好处

- **统一版本**:所有子 crate 共享 tokio 版本,不会有 `tokio 1.30` 和 `tokio 1.35` 同时编译
- **快速 build**:Cargo 只 build 改过的 crate,大型项目重要
- **共享 lock**:`Cargo.lock` 在 workspace 根,所有 crate 共享
- **统一 metadata**:version/edition/license 集中管理

### Resolver v2

`resolver = "2"` 是 Edition 2021 的默认值。差异:

- v1 把所有依赖的 feature 取并集(可能导致 dev-dependency 引入的 feature 污染 production build)
- v2 隔离 dev-dependencies、target-specific 依赖、build-dependencies 的 feature

工程经验:新项目永远用 resolver = "2"。

---

## 14.3 Feature Flags:条件编译

Feature 让一个 crate 可以提供多套行为/依赖,用户选择性启用。

### 定义 feature

```toml
[features]
default = ["postgres"]                    # 默认启用 postgres
postgres = ["sqlx/postgres"]              # 启用 sqlx 的 postgres feature
mysql = ["sqlx/mysql"]
sqlite = ["sqlx/sqlite"]
all-databases = ["postgres", "mysql", "sqlite"]
```

下游用户:

```toml
my-service = { version = "0.3", default-features = false, features = ["mysql"] }
```

`default-features = false` 关闭默认 feature,然后选自己要的。

### 在代码里用 feature

```rust
#[cfg(feature = "postgres")]
pub mod postgres_backend {
    // 只在 postgres feature 启用时编译
}

#[cfg(feature = "mysql")]
pub mod mysql_backend {
    // ...
}
```

### Feature 的设计原则

**Additive(累加性)**:多个 feature 同时启用应该工作,不应互斥。

❌ 反模式:

```toml
[features]
runtime-tokio = []
runtime-async-std = []   # 跟 tokio 互斥,但定义上没拦住
```

✅ 好的设计:

```toml
[features]
default = ["runtime-tokio"]
runtime-tokio = ["dep:tokio"]
```

不提供互斥 feature——下游要切 runtime 就 `default-features = false` + 选另一个。

### 一个 feature 不该启用太多依赖

如果一个 feature 把 dep tree 撑大 5 倍,设计有问题。考虑拆 feature 或拆 crate。

---

## 14.4 编译时间优化

Rust 编译慢是众所周知的。几个常用优化:

### 用 `cargo check` 替代 `cargo build`(开发时)

```bash
cargo check     # 只做类型检查,不生成代码,3-5 倍快
cargo build     # 完整编译
```

开发时只要 IDE 报错就行,不用真的生成二进制。

### 用 sccache

`sccache` 是 Mozilla 的编译缓存,在跨项目复用相同的依赖编译结果:

```bash
cargo install sccache
export RUSTC_WRAPPER=sccache
cargo build     # 第一次正常,第二次复用缓存
```

特别适合 CI/CD 和 monorepo。

### 用 lld linker

链接是 Rust 编译的最慢一步。`lld`(LLVM linker)比默认 `ld` 快很多。

`.cargo/config.toml`:

```toml
[target.x86_64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=lld"]
```

### 关掉 debug info(如果不调试)

`Cargo.toml`:

```toml
[profile.dev]
debug = 0       # 默认是 2(完整 debug info)
```

权衡:0 比 2 快很多,但 backtrace 没函数名。开发时 1 是不错的平衡。

### Split debuginfo

Rust 1.71+ 支持把 debug info 切到独立文件,主二进制更小,启动更快:

```toml
[profile.dev]
split-debuginfo = "unpacked"
```

### 减少代码生成单元

```toml
[profile.release]
codegen-units = 1     # 默认 16,改 1 编译慢但代码更优
```

只 release 用,dev 保留默认(16,并行编译快)。

### `cargo-chef`(Docker 构建)

`cargo-chef` 把依赖编译和源码编译分两步,Docker 层缓存友好:

```dockerfile
FROM rust:1.75 AS chef
RUN cargo install cargo-chef
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json     # 只编译依赖
COPY . .
RUN cargo build --release                                    # 增量编译你的代码
```

第二次 docker build 时,如果依赖没变,只重新编译你的源码——分钟级 → 秒级的差异。

---

## 14.5 cargo 常用命令速查

| 命令 | 用途 |
|---|---|
| `cargo new <name>` | 创建新 binary crate |
| `cargo new --lib <name>` | 创建新 library crate |
| `cargo check` | 类型检查,快 |
| `cargo build` | 编译 |
| `cargo build --release` | release 模式编译(开优化) |
| `cargo run` | 编译并运行 |
| `cargo run --release` | release 模式运行 |
| `cargo test` | 跑所有测试 |
| `cargo test <name>` | 跑名字包含 name 的测试 |
| `cargo bench` | 跑 benchmark(需要 nightly 或 criterion) |
| `cargo doc --open` | 生成文档并在浏览器打开 |
| `cargo clippy` | lint(强烈推荐,比 rustc 严格) |
| `cargo fmt` | 格式化代码 |
| `cargo update` | 升级 Cargo.lock 中的依赖到最新允许版本 |
| `cargo tree` | 显示依赖树 |
| `cargo audit` | 检查依赖里的已知漏洞 |
| `cargo deny` | 更全面的依赖检查(license / 重复版本 / 漏洞) |
| `cargo expand` | 显示宏展开后的代码 |
| `cargo install <name>` | 全局安装一个 binary crate |
| `cargo publish` | 发布到 crates.io |

工程习惯:**在 CI 里跑 `cargo check && cargo clippy -- -D warnings && cargo fmt --check && cargo test`**,这四步过了再 merge。

---

## 14.6 章末小结

### 本章核心概念回顾

1. **Cargo.toml**:声明依赖、feature、profile、workspace
2. **Cargo.lock**:应用 commit,库不 commit
3. **Workspace**:monorepo 标配,共享 lock + 统一版本 + 增量构建
4. **Feature flags**:additive 设计,不要互斥 feature
5. **编译优化**:cargo check、sccache、lld、cargo-chef
6. **Resolver v2**:Edition 2021+ 标配,隔离 feature 污染

### 习题

#### 习题 14.1(简单)

写一个 Cargo.toml,定义一个名为 `my-cli` 的 binary crate,依赖 tokio、clap、anyhow。

#### 习题 14.2(中等)

设计一个 workspace:
- root
- crates/cli(binary)
- crates/core(library,被 cli 依赖)
- crates/shared(被 core 和 cli 都依赖)

写出根 Cargo.toml 和各子 crate 的 Cargo.toml。

#### 习题 14.3(中等)

给一个 crate 加 feature:
- 默认启用 "postgres"
- 可选 "mysql"
- 可选 "redis" 缓存层

写出 [features] 部分,并展示在代码中如何用 `#[cfg(feature = "...")]`。

#### 习题 14.4(困难)

回到 Onsager。看看现有的 Cargo workspace,问自己:

- 各 crate 的边界对吗?有没有 over-fragmented 或 under-fragmented?
- workspace 依赖共享了吗?
- 编译时间能优化吗?

写一个改造方案。

---

### 下一章预告

Ch 15 进入 Web 服务实战——Axum、sqlx、tracing。
是你 Stiglab 每天用的栈,这章把背后的设计串起来讲清楚。

---

> **本章一句话总结**
>
> Cargo 不只是包管理器,是 Rust 工程效率的核心。掌握 workspace + feature + 编译优化,你的开发体验会上一个台阶。
