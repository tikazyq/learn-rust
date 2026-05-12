# Ch 17 · 宏:声明宏与过程宏

> Rust 元编程的两套机制

**核心问题**:`macro_rules!` 和 proc-macro 分别能做什么?何时该用宏,何时该用泛型?

C# 有 source generator,Go 有 `go generate`,TS 有 decorator —— 都是元编程,各有局限。Rust 给你**两套**:声明宏(pattern-based syntax expansion)和过程宏(rustc 调你写的代码生成代码)。能力强,代价是**这是 Rust 最难学也最容易被滥用的特性**。

读完你应该能:

1. 写一个简单的 `macro_rules!`,理解 fragment specifier
2. 区分 declarative / proc-macro / derive / attribute 四种
3. 用 `syn + quote` 写一个 derive 宏
4. 用 `cargo expand` 看宏展开
5. 给"什么时候用宏 vs trait vs 普通函数"建立判断力

---

## 17.1 macro_rules! 基础

```rust
macro_rules! say_hi {
    () => {
        println!("hi");
    };
}

fn main() { say_hi!(); }
```

### Fragment specifiers

宏匹配靠 **fragment specifier** —— 告诉编译器"我期望这个位置是哪类语法节点":

| Specifier | 匹配 |
|---|---|
| `expr` | 表达式 |
| `ty` | 类型 |
| `ident` | 标识符 |
| `path` | 路径 (`std::collections::HashMap`) |
| `pat` | 模式 |
| `stmt` | 语句 |
| `block` | `{ ... }` |
| `item` | 项(fn / struct / impl ...) |
| `meta` | 属性 (`derive(Debug)`) |
| `tt` | token tree(最通用) |
| `literal` | 字面量 |
| `lifetime` | `'a` |
| `vis` | 可见性 (`pub`, `pub(crate)`) |

```rust,ignore
macro_rules! make_fn {
    ($name:ident, $ty:ty, $val:expr) => {
        fn $name() -> $ty { $val }
    };
}

make_fn!(forty_two, i32, 42);
make_fn!(greeting, &'static str, "hello");
```

---

## 17.2 重复模式

`$( ... )sep rep` 匹配重复:

- `*` —— 零次或多次
- `+` —— 一次或多次
- `?` —— 零次或一次
- `sep` —— 分隔符(可选)

```rust
macro_rules! my_vec {
    ( $( $x:expr ),* ) => {
        {
            let mut v = Vec::new();
            $( v.push($x); )*
            v
        }
    };
}

fn main() {
    let v: Vec<i32> = my_vec![1, 2, 3, 4];
    println!("{:?}", v);
}
```

读法:

- 匹配 `1, 2, 3, 4`:`$($x:expr),*` 把每个分别绑定到 `$x`
- 展开:`$( v.push($x); )*` 对每次匹配生成一个 push 语句

### 真正的 std::vec! 大致也是这样写的

只是更复杂(预分配 + 几种重载形式)。

---

## 17.3 卫生性(hygiene)

C 的宏臭名昭著——`#define SQUARE(x) x*x`,`SQUARE(1+2)` 展开成 `1+2*1+2` = 5。Rust 宏是**卫生的**:

- **token 不会污染**:宏内部的 `let tmp = ...` 跟外面同名的 `tmp` 不冲突
- **作用域正确**:宏展开后,变量解析仍按"宏定义处 + 调用处"的可见性,不会把内部名字暴露给外面

```rust,ignore
macro_rules! using_tmp {
    () => {
        let tmp = 100;
        println!("{}", tmp);
    };
}

fn main() {
    let tmp = 1;
    using_tmp!();
    println!("{}", tmp);   // 1,宏内部的 tmp 跟这里不冲突
}
```

(注意:`macro_rules!` 的卫生性主要对 ident 起作用,对 lifetime / type 较弱。复杂场景仍要小心命名。)

---

## 17.4 TT munching 模式

写复杂宏时常用的"递归 + 逐步消耗 token"技巧:

```rust,ignore
macro_rules! count {
    () => (0_usize);
    ($x:tt $($rest:tt)*) => (1_usize + count!($($rest)*));
}

fn main() {
    assert_eq!(count!(a b c d), 4);
}
```

每次匹配吃掉一个 token,递归调自己处理剩下的。

实战中你写这种宏的机会不多,但读社区库(`tokio::select!`、`serde_json::json!`)时会看到。

---

## 17.5 过程宏的三种形态

声明宏的限制:**只能做 token-level 的模式替换**。要解析 Rust AST、查类型、生成完整 impl —— 你需要过程宏。

| 形态 | 用法 | 例子 |
|---|---|---|
| `#[derive(MyTrait)]` | 给 struct/enum 自动 impl | `#[derive(Debug, Clone, Serialize)]` |
| `#[my_attr(args)]` | 任意 attribute | `#[tokio::main]`, `#[instrument]` |
| `my_macro!(...)` | 函数式 | `sqlx::query!(...)`, `html!(...)` |

过程宏是**独立 crate**,`cargo` 编译它**先于**调用它的 crate:

```toml
# Cargo.toml of the macro crate
[lib]
proc-macro = true

[dependencies]
syn = { version = "2", features = ["full"] }
quote = "1"
proc-macro2 = "1"
```

---

## 17.6 syn + quote 工具链

`syn` 把 `TokenStream` 解析成 Rust AST;`quote` 把 AST / 代码片段拼回 `TokenStream`。

### 最小 derive 宏骨架

```rust,ignore
use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, DeriveInput};

#[proc_macro_derive(HelloWorld)]
pub fn hello_world(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;
    let expanded = quote! {
        impl HelloWorld for #name {
            fn hello() {
                println!("Hello from {}!", stringify!(#name));
            }
        }
    };
    expanded.into()
}
```

使用:

```rust,ignore
#[derive(HelloWorld)]
struct Pancakes;
fn main() { Pancakes::hello(); }
```

---

## 17.7 实战:写一个 derive Builder

目标:

```rust,ignore
#[derive(Builder)]
struct Request {
    url: String,
    method: String,
    timeout_ms: Option<u64>,
}

let r = Request::builder()
    .url("https://api.example.com".into())
    .method("POST".into())
    .timeout_ms(3000)
    .build()?;
```

### 实现

```rust,ignore
use proc_macro::TokenStream;
use quote::{format_ident, quote};
use syn::{parse_macro_input, Data, DeriveInput, Fields, Type};

#[proc_macro_derive(Builder)]
pub fn derive_builder(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;
    let builder_name = format_ident!("{}Builder", name);

    let fields = if let Data::Struct(s) = &input.data {
        if let Fields::Named(f) = &s.fields { &f.named } else { panic!("named fields required") }
    } else { panic!("struct required") };

    let field_names: Vec<_> = fields.iter().map(|f| &f.ident).collect();
    let field_types: Vec<_> = fields.iter().map(|f| &f.ty).collect();

    let optional_field_decl = field_types.iter().map(|ty| {
        quote!(Option<#ty>)
    });

    let setters = fields.iter().map(|f| {
        let n = &f.ident;
        let ty = &f.ty;
        quote!(pub fn #n(mut self, value: #ty) -> Self {
            self.#n = Some(value);
            self
        })
    });

    let build_fields = field_names.iter().map(|n| {
        quote!(#n: self.#n.ok_or(concat!("missing field: ", stringify!(#n)))?)
    });

    let expanded = quote! {
        #[derive(Default)]
        pub struct #builder_name {
            #( #field_names: #optional_field_decl, )*
        }
        impl #name {
            pub fn builder() -> #builder_name { #builder_name::default() }
        }
        impl #builder_name {
            #( #setters )*
            pub fn build(self) -> Result<#name, &'static str> {
                Ok(#name { #( #build_fields, )* })
            }
        }
    };
    expanded.into()
}
```

这是个简化版,真实的 [`derive_builder`](https://crates.io/crates/derive_builder) 还支持 `#[builder(...)]` attribute 控制行为(default value、setter rename、setter prefix 等)。

---

## 17.8 cargo expand

```bash
cargo install cargo-expand
cargo expand --bin myapp
cargo expand --lib path::to::module
```

**调试宏的最重要工具**。把所有宏(`println!`, `vec!`, `tokio::main`, `derive` ...)展开后给你看,你能精确知道编译器看到的代码。

第一次跑 `cargo expand` on 一个有 `#[tokio::main]` 的程序,会看到几十行的 runtime 构建代码——再也不觉得 async magical 了。

---

## 17.9 宏使用纪律

### 优先级:函数 > 泛型 > trait > 宏

| 想做的事 | 用什么 |
|---|---|
| 计算 | 函数 |
| 多类型支持 | 泛型 + trait bound |
| 不同行为切换 | trait + dyn / impl |
| 模式化的代码生成(boilerplate) | 宏 |
| 不规则语法 | 宏 |
| 编译时算 / 查 | 宏(或 const fn) |

### 何时用宏是合理的

- 真正的不规则语法(`println!("x = {}", x)` 这种)
- 大量样板代码(derive `Debug` / `Clone` / `Serialize`)
- 编译时校验(`sqlx::query!`)
- DSL(`html!`, `quote!`)

### 何时不该用宏

- 能用普通函数 / generic 表达
- 你"觉得" boilerplate 多但其实只有 2-3 处
- 写来"显得有意思"

社区有个段子:**Rust 工程师水平的反比指标 = 项目里宏的数量**。这话夸张但有道理:克制是美德。

---

## 习题

1. 写一个 `min!` 宏接受任意个表达式,返回最小值。
2. 写一个 `#[derive(Getters)]`,为每个字段生成 `fn field_name(&self) -> &FieldType`。
3. 用 `cargo expand` 看 `#[tokio::main] async fn main()` 展开后什么样,解释每一段做什么。
4. 找一个 `serde::Serialize` 实现的展开结果(用 `cargo expand`),挑一个 struct 看它生成的代码量。
5. 写一篇 200 字"我们项目要不要引入 proc-macro" 的内部 RFC,论证支持 / 反对的判断。

---

> **本章一句话总结**
>
> 宏是 Rust 的元编程武器,但它是最容易被滥用的特性。读得懂 + 必要时能写 + 大部分时间不写——这是合格 Rust 工程师的判断力。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
