# Ch 14 · Cargo、Workspace、依赖管理

> 大型 Rust 项目的工程化

**核心问题**:大型 Rust 项目怎么组织?跟 Go module / pnpm workspace 有什么异同?

Cargo 在所有"语言官方包管理器"里被公认最好用——比 npm、go mod、pip / poetry 都设计得更严肃。这章不是 cargo 命令罗列,是讲**生产级项目怎么用 Cargo**。

读完你应该能:

1. 设计一个多 crate workspace
2. 用 feature flag 做"编译期可配置"而不踩 mutual-exclusive 的坑
3. 区分 `[dependencies]` / `[dev-dependencies]` / `[build-dependencies]`
4. 把编译时间从 10 分钟降到 2 分钟
5. 发一个 crate 到 crates.io

---

## 14.1 Cargo.toml 全字段解读

```toml
[package]
name = "my-service"
version = "0.3.1"
edition = "2021"               # 2015 / 2018 / 2021 / 2024
rust-version = "1.78"          # MSRV(最低支持版本)
authors = ["Alice <a@x.com>"]
description = "An example service"
license = "MIT OR Apache-2.0"  # SPDX
readme = "README.md"
repository = "https://github.com/x/y"
keywords = ["http", "service"] # 最多 5 个,crates.io 用
categories = ["web-programming"]

[dependencies]
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
my-shared = { path = "../shared" }                 # 同 workspace
private-lib = { git = "ssh://git@host/x.git", branch = "main" }

[dev-dependencies]
tokio-test = "0.4"
insta      = "1"

[build-dependencies]
cc = "1"

[features]
default = ["pg"]
pg = ["dep:sqlx-postgres"]
mysql = ["dep:sqlx-mysql"]

[profile.release]
lto = "thin"                   # link-time optimization
codegen-units = 1              # 全局优化(慢但快)
strip = "symbols"
panic = "abort"

[profile.dev]
opt-level = 1                  # dev build 加速

[[bin]]
name = "server"
path = "src/bin/server.rs"

[[bench]]
name = "throughput"
harness = false
```

### 几个关键字段

- **`edition`**:三年一版,改变语言行为(`2021` 启用了 `let_else`, disjoint capture in closures 等)。新项目直接 `2024`(2024 末稳定后)
- **`rust-version` (MSRV)**:申明你保证编译过的最低 rustc。库作者要谨慎,改动 MSRV 是 breaking change
- **`license = "MIT OR Apache-2.0"`**:Rust 生态约定双协议;不写 license crates.io 不让发布

---

## 14.2 Workspace 与 monorepo

```toml
# 仓库根 Cargo.toml
[workspace]
members = [
    "crates/core",
    "crates/api",
    "crates/cli",
]
resolver = "2"

[workspace.package]
version = "0.3.1"
edition = "2021"
license = "MIT"

[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
```

```toml
# crates/api/Cargo.toml
[package]
name = "api"
version.workspace = true
edition.workspace = true
license.workspace = true

[dependencies]
tokio.workspace = true   # 继承 workspace 里定义的版本
serde.workspace = true
core = { path = "../core" }
```

### 优势

- 多个 crate 共享一个 `Cargo.lock`(版本一致性强)
- 编译缓存可复用
- `cargo build` 在根目录一次构建全部 crate

### 常见分层

```
my-service/
├── crates/
│   ├── core/           # 业务模型,纯逻辑,no_std?可以
│   ├── persistence/    # DB / cache 适配器
│   ├── api/            # HTTP / gRPC 入口
│   ├── cli/            # 管理命令
│   └── testkit/        # 测试公用,dev-only
└── Cargo.toml
```

跟 Go monorepo 类比:每个 crate ≈ 一个 Go package。跟 pnpm workspace 类比:每个 crate ≈ 一个 npm package,但**依赖解析更严格**(版本统一、特性合并)。

---

## 14.3 Feature flags 设计

```toml
[features]
default = ["http", "pg"]
http  = ["dep:axum", "dep:tower"]
grpc  = ["dep:tonic"]
pg    = ["dep:sqlx-postgres"]
mysql = ["dep:sqlx-mysql"]
```

### Additive 原则

**Feature 必须是叠加式的:开 feature 只新增功能,不删除、不替换**。原因:Cargo 会合并所有上层 crate 用到的 feature(union),你不能假定某个 feature 是关的。

反例:

```toml
[features]
small-int = []        # 想要的语义:类型变 i32
large-int = []        # 想要的语义:类型变 i64
# 如果 crate A 开 small-int,crate B 开 large-int,合并后两个都开,语义崩了
```

修正:用 trait / 类型抽象代替,或者拆成两个 crate。

### 跟 Go build tag 对比

| | Go build tag | Rust feature |
|---|---|---|
| 控制粒度 | 文件级 | 代码块级(`#[cfg(feature)]`) |
| 互斥/叠加 | 不限 | 强烈要求叠加 |
| 默认行为 | 显式标 | `default` feature |

### 何时该用 feature

- 给同一 crate 选择**不同的可选依赖**(pg / mysql / sqlite)
- 给可选功能做"按需编译"(`http` / `grpc`)
- 调试 / 性能 / 工具用途(`tracing`, `metrics`)

何时**不**该用 feature(用 trait / 枚举更好):

- 运行时配置(env / config 决定)
- A/B 测试(不需要编译时分支)

---

## 14.4 dev-dependencies / build-dependencies 的边界

| 类别 | 何时编译 | 何时进入二进制 |
|---|---|---|
| `[dependencies]` | 总是 | 是 |
| `[dev-dependencies]` | 仅测试 / 示例 / 基准 | 否 |
| `[build-dependencies]` | 仅 build.rs 时 | 否(但产物可能影响代码生成) |

### 典型 dev-deps

```toml
[dev-dependencies]
tokio-test = "0.4"
insta = "1"
proptest = "1"
criterion = "0.5"
mockall = "0.13"
```

### 典型 build-deps + build.rs

```toml
[build-dependencies]
cc = "1"
tonic-build = "0.12"
```

```rust,ignore
// build.rs
fn main() {
    println!("cargo:rerun-if-changed=proto/foo.proto");
    tonic_build::compile_protos("proto/foo.proto").unwrap();
}
```

**陷阱**:把测试用的 helper 放 `[dependencies]`,导致生产二进制带上不该有的代码。审计时盯这个。

---

## 14.5 cargo 命令全家桶

```bash
# 编译 & 检查
cargo check                # 不生成二进制,只过类型检查(快 3x)
cargo build                # debug 编译
cargo build --release      # release 编译
cargo build --profile=ci   # 自定义 profile

# 运行
cargo run -p api -- --port 8080   # 跑 workspace 里的 api crate

# 测试
cargo test                 # 全部测试
cargo test --doc           # 只 doc tests
cargo test -- --nocapture  # 测试里 println! 真的打印
cargo test --release       # 用 release build 跑(慢编译,快运行)
cargo nextest run          # 第三方,并行更猛

# Lint & 格式
cargo fmt                  # rustfmt
cargo fmt --check          # CI 用
cargo clippy               # lint
cargo clippy -- -D warnings   # 警告变错误

# 文档
cargo doc --open
cargo doc --no-deps        # 只生成本 crate 的

# 基准
cargo bench

# 依赖
cargo update               # 更新 Cargo.lock
cargo update -p tokio      # 只更新一个
cargo tree                 # 看依赖树
cargo tree -d              # 看重复依赖(版本冲突)
cargo outdated             # 查可升级(第三方插件)
cargo udeps                # 查未使用的依赖(第三方插件)

# 安装第三方
cargo install ripgrep
cargo install --git ... --branch ...
```

### 三个最该装的子命令

```bash
cargo install cargo-edit       # cargo add / cargo rm / cargo upgrade
cargo install cargo-nextest    # 更快的 test runner
cargo install cargo-expand     # 看宏 / async 展开后什么样
```

---

## 14.6 依赖审计

### cargo audit

```bash
cargo install cargo-audit
cargo audit
```

查 RustSec 数据库里的已知漏洞。CI 必跑。

### cargo deny

```toml
# deny.toml
[bans]
multiple-versions = "warn"
[licenses]
allow = ["MIT", "Apache-2.0", "BSD-3-Clause", "ISC"]
deny  = ["GPL-3.0"]
[advisories]
vulnerability = "deny"
unmaintained = "warn"
```

```bash
cargo install cargo-deny
cargo deny check
```

`cargo deny` 比 audit 强:它管 license、版本冲突、unmaintained crate。**任何对外发布的 Rust 产品都该接入**。

### supply chain

近两年供应链攻击逐步增多。生产配置:

- pin 主版本号,review 升级
- 关键依赖订 GitHub release notification
- `cargo vet` 标记 "我已 review 过这个版本"(Google / Mozilla 在用)

---

## 14.7 编译时间优化

Rust 编译慢是众所周知的痛。常用对策:

### 链接器换 lld 或 mold

```toml
# .cargo/config.toml
[target.x86_64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
```

`mold` 把"链接"从 10s 压到 1s,debug build 体感巨大。

### sccache:跨项目缓存

```bash
cargo install sccache
export RUSTC_WRAPPER=sccache
```

第一次编译完后,换 branch / 切项目都能复用编译产物。

### cargo-chef:Docker 构建加速

```dockerfile
FROM rust as planner
RUN cargo chef prepare --recipe-path recipe.json
FROM rust as cacher
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
# ...
```

把依赖编译跟源码编译分离,Docker 缓存命中率从 0% 到 95%。

### split debuginfo

```toml
[profile.dev]
split-debuginfo = "unpacked"  # macOS 默认,其他平台显式
debug = "line-tables-only"    # 比完整 debuginfo 小,够调用栈用
```

### 隔离泛型(见 Ch 7)

让 generic 函数转发到非 generic 内部函数。每个 generic 函数实例化都增加编译时间。

---

## 14.8 发布到 crates.io 的流程

1. **第一次准备**

   ```bash
   cargo login <token>   # 从 crates.io 拿 token
   ```

2. **Cargo.toml 必填字段**

   - `name` / `version` / `description` / `license` / `repository` / `readme`
   - `categories`(从 crates.io 列表选)/ `keywords`

3. **发布前 dry-run**

   ```bash
   cargo publish --dry-run
   cargo package --list   # 看会上传哪些文件
   ```

4. **正式发布**

   ```bash
   cargo publish
   ```

5. **Workspace 多 crate 发布**

   按依赖拓扑顺序逐个 publish,版本要先 bump:

   ```bash
   (cd crates/core && cargo publish)
   sleep 10   # 等 crates.io index 更新
   (cd crates/api  && cargo publish)
   ```

6. **撤回**

   `cargo yank --version 0.3.0` 把版本标记 yanked(不删除,但新项目不会拉)。删除需要给 crates.io 工作人员发邮件,很少批准。

### 维护 changelog

`CHANGELOG.md` 推荐 [Keep a Changelog](https://keepachangelog.com/) 格式。社区 ergonomic crates 都遵循。

---

## 习题

1. 把你某个个人项目重构成 workspace 结构,把 "core 逻辑" / "HTTP" / "CLI" 拆三个 crate。
2. 给一个 crate 加 `pg` / `mysql` 两个互斥的 feature(故意写错),用 `cargo build --features pg,mysql` 看会发生什么。改造成 additive。
3. 用 `cargo bloat` 找出你二进制里占用最大的 crate,讨论能否裁掉它的 feature。
4. 配 `mold` + `sccache`,对比 `cargo clean && cargo build` 的时间。
5. 用 `cargo deny` 加进 CI,故意引入一个 GPL 依赖,看 CI 怎么拦。

---

> **本章一句话总结**
>
> Cargo 是 Rust 工程化的基石。会用 Cargo 跟会写 Rust 同等重要——它是你跟整个生态、跟 CI、跟生产之间的胶水。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
