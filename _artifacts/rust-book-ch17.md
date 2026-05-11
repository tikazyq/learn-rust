# 第 17 章 · 宏 —— 声明宏与过程宏

> "Macros are how Rust extends itself without changing the compiler."

宏在 Rust 生态无处不在——`println!`、`vec!`、`#[derive(Debug)]`、`#[tokio::main]`、`sqlx::query!`、`#[serde(...)]`——但你日常使用它们不需要知道实现细节。这一章我们打开盒子。

读完你应该能:

1. 写 declarative macro 处理简单的代码生成
2. 知道 procedural macro 三种形式(derive / attribute / function-like)各自的场景
3. 看懂 `syn` + `quote` + `proc-macro2` 这套工具栈
4. 给 Onsager 设计一个 derive macro,免去重复样板代码

---

## 17.1 宏 vs 函数:区别在编译期

普通函数:运行时执行,操作运行时的值。
宏:编译期执行,操作代码的语法树。

```rust
println!("{} {}", a, b);    // 宏:展开成具体的格式化代码
print(a, b);                 // 函数:用确定的方式打印两个参数
```

宏的优势:**变参、可变类型、生成代码**——函数做不到。
宏的劣势:**调试难、错误信息不直观、IDE 支持有限**。

工程经验:**优先函数,函数表达不了再宏**。

---

## 17.2 Declarative Macro:`macro_rules!`

最简单的宏,用 pattern matching 风格定义:

```rust
macro_rules! square {
    ($x:expr) => {
        $x * $x
    };
}

let n = square!(5);     // 展开成 5 * 5
let m = square!(2 + 3); // 展开成 (2 + 3) * (2 + 3) —— 注意会重复计算!
```

`$x:expr` 是一个 metavariable,捕获一个表达式。`expr` 是 fragment specifier,说明捕获什么类型的语法元素。

### Fragment specifiers

| 名字 | 捕获什么 |
|---|---|
| `expr` | 表达式 |
| `stmt` | 语句 |
| `ty` | 类型 |
| `pat` | 模式 |
| `ident` | 标识符 |
| `path` | 路径(`std::vec::Vec`) |
| `tt` | token tree(最通用) |
| `block` | `{ ... }` 块 |
| `literal` | 字面量(`42`、`"hi"`) |

### 多个 arm

```rust
macro_rules! max {
    ($a:expr) => { $a };
    ($a:expr, $($rest:expr),+) => {
        std::cmp::max($a, max!($($rest),+))
    };
}

let m = max!(1, 5, 3, 8, 2);  // 8
```

`$($rest:expr),+` 是 repetition——匹配一个或多个用逗号分隔的表达式。

### Repetition 语法

| 形式 | 含义 |
|---|---|
| `$(...)*` | 零次或多次 |
| `$(...)+` | 一次或多次 |
| `$(...)?` | 零次或一次 |
| `$(...),*` | 用逗号分隔,零次或多次 |

### 一个稍复杂的例子:hashmap! 字面量

```rust
macro_rules! hashmap {
    ($($key:expr => $value:expr),* $(,)?) => {{
        let mut map = std::collections::HashMap::new();
        $(
            map.insert($key, $value);
        )*
        map
    }};
}

let m = hashmap! {
    "a" => 1,
    "b" => 2,
    "c" => 3,
};
```

读法:`$($key:expr => $value:expr),*` 匹配多个 "key => value" 对(逗号分隔)。后面 `$(...)*` 把 `map.insert(...)` 重复展开。

`$(,)?` 允许末尾尾随逗号(可选)。

### macro_rules 的限制

- 只能做 token tree 层面的转换,不能"理解"代码语义
- 不能做条件编译之外的复杂判断
- hygiene 规则严格(避免名字冲突),但有时反而限制表达

复杂场景需要 procedural macro。

---

## 17.3 Procedural Macros:三种形式

Procedural macro 是用 Rust 代码生成 Rust 代码——更强大,也更复杂。三种形式:

| 形式 | 用法 | 例子 |
|---|---|---|
| **Derive** | `#[derive(MyMacro)]` 给 struct/enum 加 | `#[derive(Debug)]`、`#[derive(Serialize)]` |
| **Attribute** | `#[my_macro(...)]` 修饰 item | `#[tokio::main]`、`#[tracing::instrument]` |
| **Function-like** | `my_macro!(...)` 像 macro_rules | `sqlx::query!`、`tokio::select!` |

### Procedural macro 必须在独立 crate

```toml
# my-derive-macro/Cargo.toml
[package]
name = "my-derive-macro"
version = "0.1.0"

[lib]
proc-macro = true        # 标记为 proc-macro crate

[dependencies]
proc-macro2 = "1.0"
quote = "1.0"
syn = { version = "2.0", features = ["full"] }
```

```rust
// my-derive-macro/src/lib.rs
use proc_macro::TokenStream;

#[proc_macro_derive(MyMacro)]
pub fn my_macro_derive(input: TokenStream) -> TokenStream {
    // 解析 input,生成 output
    TokenStream::new()
}
```

### 工具栈:syn + quote + proc-macro2

- `syn`:把 TokenStream 解析成 AST
- `quote`:把 Rust 代码模板渲染成 TokenStream
- `proc-macro2`:跨 proc-macro / non-proc-macro 上下文用的 token 表示

---

## 17.4 写一个 Derive Macro

目标:给 `#[derive(Builder)]` 自动生成 builder pattern。

输入:

```rust
#[derive(Builder)]
struct Config {
    host: String,
    port: u16,
    timeout: u64,
}
```

期望生成:

```rust
impl Config {
    fn builder() -> ConfigBuilder { ConfigBuilder::default() }
}

#[derive(Default)]
struct ConfigBuilder {
    host: Option<String>,
    port: Option<u16>,
    timeout: Option<u64>,
}

impl ConfigBuilder {
    fn host(mut self, value: String) -> Self { self.host = Some(value); self }
    fn port(mut self, value: u16) -> Self { self.port = Some(value); self }
    fn timeout(mut self, value: u64) -> Self { self.timeout = Some(value); self }
    fn build(self) -> Result<Config, &'static str> {
        Ok(Config {
            host: self.host.ok_or("host required")?,
            port: self.port.ok_or("port required")?,
            timeout: self.timeout.ok_or("timeout required")?,
        })
    }
}
```

调用方:

```rust
let config = Config::builder()
    .host("localhost".into())
    .port(8080)
    .timeout(30)
    .build()
    .unwrap();
```

### 实现

```rust
use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, DeriveInput, Data, Fields};

#[proc_macro_derive(Builder)]
pub fn builder_derive(input: TokenStream) -> TokenStream {
    // 1. 解析输入
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;                       // Config
    let builder_name = quote::format_ident!("{}Builder", name);   // ConfigBuilder

    // 2. 提取字段
    let fields = match &input.data {
        Data::Struct(s) => match &s.fields {
            Fields::Named(f) => &f.named,
            _ => panic!("Builder only supports named fields"),
        },
        _ => panic!("Builder only supports structs"),
    };

    // 3. 生成 builder struct 的字段(每个是 Option<T>)
    let builder_fields = fields.iter().map(|f| {
        let name = &f.ident;
        let ty = &f.ty;
        quote! { #name: Option<#ty> }
    });

    // 4. 生成 setter 方法
    let setters = fields.iter().map(|f| {
        let name = &f.ident;
        let ty = &f.ty;
        quote! {
            pub fn #name(mut self, value: #ty) -> Self {
                self.#name = Some(value);
                self
            }
        }
    });

    // 5. 生成 build 方法的字段初始化
    let build_fields = fields.iter().map(|f| {
        let name = &f.ident;
        let err_msg = format!("{} required", name.as_ref().unwrap());
        quote! {
            #name: self.#name.ok_or(#err_msg)?
        }
    });

    // 6. 拼接所有部分
    let expanded = quote! {
        #[derive(Default)]
        pub struct #builder_name {
            #(#builder_fields),*
        }

        impl #name {
            pub fn builder() -> #builder_name {
                #builder_name::default()
            }
        }

        impl #builder_name {
            #(#setters)*

            pub fn build(self) -> Result<#name, &'static str> {
                Ok(#name {
                    #(#build_fields),*
                })
            }
        }
    };

    expanded.into()
}
```

### 解读

- `parse_macro_input!(input as DeriveInput)`:解析 token 流成 AST
- `#name`:在 quote 模板里插入变量
- `#(#fields),*`:展开 iterator,逗号分隔
- 最后 `expanded.into()` 把生成的代码返回给编译器

### 编译用户代码时

用户 `#[derive(Builder)]` 时,编译器调用我们的 macro 函数,把生成的 token 拼接到用户代码后。`cargo expand` 可以看展开结果。

### 错误处理

上面用 `panic!` 处理错误——但 panic 在 proc macro 里报错信息很丑。生产 macro 用 `syn::Error`:

```rust
fn process(input: DeriveInput) -> syn::Result<TokenStream> {
    let fields = match &input.data {
        Data::Struct(s) => match &s.fields {
            Fields::Named(f) => &f.named,
            _ => return Err(syn::Error::new_spanned(
                &input,
                "Builder only supports named fields",
            )),
        },
        _ => return Err(syn::Error::new_spanned(
            &input,
            "Builder only supports structs",
        )),
    };
    // ...
}
```

错误带 span 信息,IDE 能在准确位置标红。

---

## 17.6 Attribute Macros

`#[tokio::main]` 那种风格:

```rust
#[proc_macro_attribute]
pub fn my_attr(attr: TokenStream, item: TokenStream) -> TokenStream {
    // attr 是属性内的参数:#[my_attr(foo, bar)]
    // item 是被修饰的代码
    let item: syn::ItemFn = syn::parse(item).unwrap();
    // 修改 item,生成新代码
    quote! { #item }.into()
}
```

经典例子:`#[tokio::main]` 把 async main 包装成同步 main:

```rust
// 用户写
#[tokio::main]
async fn main() {
    // ...
}

// 展开成
fn main() {
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        // ...
    });
}
```

### `#[tracing::instrument]` 的简化版

```rust
#[proc_macro_attribute]
pub fn log_calls(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let input = parse_macro_input!(item as syn::ItemFn);
    let name = &input.sig.ident;
    let block = &input.block;
    let sig = &input.sig;

    let expanded = quote! {
        #sig {
            println!("ENTER {}", stringify!(#name));
            let result = (|| #block)();
            println!("EXIT {}", stringify!(#name));
            result
        }
    };

    expanded.into()
}
```

```rust
#[log_calls]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
// 调用时自动打印 ENTER add / EXIT add
```

---

## 17.7 Function-like Macros

```rust
#[proc_macro]
pub fn my_macro(input: TokenStream) -> TokenStream {
    // input 是括号内的所有 token
    quote! { /* ... */ }.into()
}
```

调用:`my_macro!(arg1, arg2)`。

经典例子:`sqlx::query!` —— 解析 SQL 字符串,连数据库验证,生成强类型查询代码。

### 简化示例:env! 风格

```rust
#[proc_macro]
pub fn ensure_env(input: TokenStream) -> TokenStream {
    let key: syn::LitStr = syn::parse(input).unwrap();
    let value = std::env::var(key.value())
        .expect("environment variable not set at compile time");
    quote! { #value }.into()
}
```

```rust
let api_key = ensure_env!("API_KEY");
// 编译时读 API_KEY 环境变量,内嵌进代码;没设就编译失败
```

这种"编译期读环境/文件/数据库"的能力是 procedural macro 的杀手锏——SQL 编译期校验、配置编译期校验、模板编译期渲染。

---

## 17.8 给 Onsager 设计一个 Derive Macro

实战:Onsager 的 Artifact 模型有多种类型,每种都要实现 `Artifact` trait。可以写个 `#[derive(Artifact)]` 减少样板。

```rust
#[derive(Artifact)]
#[artifact(kind = "spec")]
struct SpecArtifact {
    id: ArtifactId,
    content: String,
    dependencies: Vec<ArtifactId>,
}
```

期望生成:

```rust
impl Artifact for SpecArtifact {
    fn id(&self) -> ArtifactId { self.id }
    fn kind(&self) -> ArtifactKind { ArtifactKind::Spec }
    fn dependencies(&self) -> &[ArtifactId] { &self.dependencies }
}
```

宏读 `#[artifact(kind = "spec")]` 决定 kind 返回什么,自动从字段生成 id / dependencies。

### 实现骨架

```rust
#[proc_macro_derive(Artifact, attributes(artifact))]
pub fn artifact_derive(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;

    // 解析 #[artifact(kind = "...")]
    let mut kind_str = None;
    for attr in &input.attrs {
        if attr.path().is_ident("artifact") {
            attr.parse_nested_meta(|meta| {
                if meta.path.is_ident("kind") {
                    let value: syn::LitStr = meta.value()?.parse()?;
                    kind_str = Some(value.value());
                }
                Ok(())
            }).unwrap();
        }
    }
    let kind_ident = quote::format_ident!("{}",
        kind_str.unwrap().to_uppercase().chars().next().unwrap().to_string() +
        &kind_str.unwrap()[1..]
    );

    let expanded = quote! {
        impl Artifact for #name {
            fn id(&self) -> ArtifactId { self.id }
            fn kind(&self) -> ArtifactKind { ArtifactKind::#kind_ident }
            fn dependencies(&self) -> &[ArtifactId] { &self.dependencies }
        }
    };
    expanded.into()
}
```

(这只是骨架,生产质量需要更多错误处理和字段名校验。)

工程价值:Onsager 如果有 8 种 artifact,每种至少省 5 行样板。8 × 5 = 40 行手动同步的代码消失,所有 artifact 接口一致性由 macro 保证。

---

## 17.9 宏调试与最佳实践

### `cargo expand`

```bash
cargo install cargo-expand
cargo expand --bin my-app          # 显示宏展开后的代码
cargo expand --test my_test
```

排错神器。看不懂 macro 错误时直接看展开后的代码,问题一目了然。

### 最佳实践

1. **能用函数就别用宏**:宏不优先
2. **macro_rules! 先,proc macro 后**:能用 declarative 就别 procedural
3. **错误消息友好**:用 `syn::Error::new_spanned` 而不是 panic
4. **测试 macro 展开后的代码**:`trybuild` crate 让你写"这段代码应该编译失败"的测试
5. **文档示例**:macro 文档难写,但缺了人没法用

---

## 17.10 章末小结与习题

### 本章核心概念回顾

1. **宏 vs 函数**:宏在编译期操作语法树
2. **macro_rules!**:declarative 宏,pattern matching 风格
3. **Fragment specifiers**:expr / ty / ident / tt / ...
4. **Procedural macro 三种**:derive / attribute / function-like
5. **工具栈**:syn(parse)+ quote(generate)+ proc-macro2(common)
6. **`cargo expand`**:看展开后代码,排错神器
7. **优先级**:函数 > macro_rules > proc macro

### 习题

#### 习题 17.1(简单)

写一个 `debug_print!` 宏,用法 `debug_print!(x, y, z)` 打印每个变量的名字和值。

#### 习题 17.2(中等)

写一个 `vec_of_strings!` 宏,接受多个字符串字面量,返回 `Vec<String>`:

```rust
let v = vec_of_strings!["hello", "world", "rust"];
```

#### 习题 17.3(中等)

读 thiserror 的 source code(在 GitHub),理解 `#[derive(Error)]` 怎么生成 Display impl。

#### 习题 17.4(困难)

给 Onsager 设计一个 `#[derive(Validate)]` 宏:

```rust
#[derive(Validate)]
struct UserInput {
    #[validate(min_len = 1, max_len = 100)]
    name: String,
    #[validate(email)]
    email: String,
    #[validate(range(min = 0, max = 150))]
    age: u32,
}

let input: UserInput = ...;
input.validate()?;   // 自动生成的方法
```

#### 习题 17.5(开放)

回顾你写过的代码,有没有大量重复的样板?用 macro 重构一段,对比前后代码量和可读性。

---

### 下一章预告

Ch 18 是这本书最深的一章:**unsafe Rust**。Rustonomicon 速成,UB 列表、aliasing 规则、Send/Sync 手动 impl、Miri。准备好心智重置。

---

> **本章一句话总结**
>
> 宏是 Rust 的"元编程"工具,从简单的字面量生成到复杂的编译期代码生成都覆盖。慎用,但用对的地方,它能让你的代码省一个数量级的样板。
