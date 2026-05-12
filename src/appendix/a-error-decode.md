# 附录 A · Rust 编译器报错读法手册

> 常见 50 种报错的解读模板

**核心问题**:如何高效读懂 Rust 编译器的报错?

Rust 编译器的错误信息是它给你最大的礼物之一——它常常**直接告诉你怎么修**。但前提是你能看懂格式。这附录是常见报错速查,每条都用同一个模板:

> **错误码 / 关键词** | 触发场景 | 典型修法

按主题分组,遇到对照查。

---

## A.1 借用检查错误(borrow checker)

### E0382 — `use of moved value`

```rust,ignore
let s = String::from("hi");
let _t = s;
println!("{}", s);   // ❌ moved
```

**修法**:`.clone()`、改成 `&s` 借用、或者重构所有权流。

### E0502 — `cannot borrow as mutable because also borrowed as immutable`

```rust,ignore
let mut v = vec![1, 2, 3];
let r = &v[0];
v.push(4);
println!("{}", r);   // ❌ &v 还活着
```

**修法**:缩小 `r` 的作用域,或先 push 再借用。

### E0499 — `cannot borrow as mutable more than once`

```rust,ignore
let mut v = vec![1, 2];
let a = &mut v;
let b = &mut v;   // ❌
```

**修法**:同一时刻只能有一个 `&mut`。让前一个 drop 后再借。

### E0596 — `cannot borrow as mutable`

```rust,ignore
let v = vec![1, 2];
v.push(3);   // ❌ v 不是 mut
```

**修法**:`let mut v = ...`

### E0507 — `cannot move out of borrowed content`

```rust,ignore
fn take_first(v: &Vec<String>) -> String { v[0] }   // ❌
```

**修法**:`v[0].clone()` 或改返回 `&String`。

### E0716 — `temporary value dropped while borrowed`

```rust,ignore
let r = &String::from("hi");
println!("{}", r);   // ❌ 临时 String 已 drop
```

**修法**:把 `String::from("hi")` 绑到一个 `let` 变量上。

### E0505 — `cannot move out of value because it is borrowed`

```rust,ignore
let v = vec![1, 2];
let r = &v;
drop(v);   // ❌ r 还借着
```

### "the trait `Sized` is not implemented for X"

签名里用了 `T` 但 T 可能是 `?Sized` 类型。**修法**:加 `T: Sized` 或 `?Sized` 显式。

---

## A.2 生命周期错误

### E0106 — `missing lifetime specifier`

```rust,ignore
fn first(s: &str, t: &str) -> &str { s }   // ❌
```

**修法**:`fn first<'a>(s: &'a str, t: &str) -> &'a str { s }`

### E0623 — `lifetime mismatch`

返回值生命周期跟参数对不上。逐个看每个 `'a` 推断的是哪个,缺哪条信息就显式加哪条。

### E0309 — `the parameter type T may not live long enough`

```rust,ignore
struct Holder<T> { val: &'static T }   // ❌ T 默认有 'static bound
```

**修法**:`struct Holder<T: 'static> { ... }`

### E0759 — `argument requires that 'a must outlive 'static`

通常因为想把借用的对象塞进 `'static` 容器(`Box<dyn Trait>` 默认是 `+ 'static`)。**修法**:换成 owned 类型,或显式加生命周期。

### "lifetime may not live long enough" 多见于闭包

闭包捕获了带短生命周期的引用,但被存进长寿命的容器。**修法**:`move` + clone 或重构。

### 异步函数里的 `borrowed value does not live long enough`

```rust,ignore
async fn bad(s: String) -> usize {
    let r = &s;
    tokio::time::sleep(_).await;
    r.len()   // 经常报 lifetime 问题
}
```

实际报错是 Future 跨 await 的"自引用"问题。**修法**:把借用放进 await 之前完成,或者放进 `let` 绑定别再跨 await 用。

---

## A.3 Trait 错误

### E0277 — `the trait bound X: Y is not satisfied`

最常见报错。它会告诉你:T 类型 / 这个表达式需要 Y trait,但 X 没实现。

```rust,ignore
fn f<T: Display>(x: T) {}
struct S;
f(S);   // ❌ S: Display 没满足
```

**修法**:给 S `impl Display`,或换成实现了 Display 的类型,或在 generic 上放宽约束。

### E0599 — `method not found`

```rust,ignore
let v: Vec<i32> = vec![];
v.contains_key(&1);   // ❌ Vec 没有 contains_key
```

90% 是用错方法,10% 是漏 import(`use std::io::Read` 等)——这种情况编译器一般会**主动建议** `use ...`。

### E0119 — `conflicting implementations`

两个 impl 适用于同一类型 → 违反孤儿规则 / coherence。**修法**:换 newtype 包装。

### E0277 + `cannot be sent between threads safely`

`Send` 报错。检查链上哪个类型不是 Send(`Rc<T>` / `RefCell<T>` / 裸指针)。

### `dyn Trait` 报错 "is not object safe"

trait 有 `Self: Sized` 方法、`fn foo<T>()` generic 方法、或返回 `Self`。**修法**:把方法标 `where Self: Sized`(它就不进 vtable),或重设计 trait。

---

## A.4 泛型错误

### E0107 — `wrong number of generic arguments`

```rust,ignore
let v: Vec<i32, String> = vec![];   // ❌ Vec 只接受一个 T
```

### E0282 — `type annotations needed`

```rust,ignore
let v = vec![];   // ❌ vec 是什么类型?
```

**修法**:`let v: Vec<i32> = vec![]` 或 `vec![1, 2]`。

### E0283 — `type annotations needed` 但带 trait

```rust,ignore
let n = "1".parse()?;   // ❌ parse 成什么?
```

**修法**:turbofish `"1".parse::<i32>()?` 或 `let n: i32 = "1".parse()?`。

### "expected X, found Y"

类型不匹配。仔细对比签名 vs 实际值,常见就是漏了 `&`、`*`、`.clone()`、`.to_owned()`、`.as_str()`。

### "cannot infer type for type parameter T"

类型推断卡住。**修法**:在调用处加 turbofish 或注解。

---

## A.5 宏错误

### `macro_rules` 里 `no rules expected this token`

模式匹配失败。检查 fragment specifier 和分隔符。

### `recursion limit reached while expanding`

宏 / serde 嵌套太深。**修法**:`#![recursion_limit = "256"]` 加到 crate root。

### `proc-macro derive panicked`

derive macro 内部 panic 了。看 panic 信息(通常是 syn 解析错误),或用 `cargo expand` 看展开。

### `cannot find macro X! in this scope`

漏 import。`use foo::bar;` 不导出 macro,要用 `#[macro_use] extern crate foo;` 或 `use foo::baz!;`(Rust 2018+)。

### `error: format argument must be a string literal`

```rust,ignore
let s = "hi {}";
println!(s, 1);   // ❌
```

`println!` 的第一个参数必须是字面量。**修法**:用 `print!("{}", format!(s, 1))` 或者改 string literal。

### `unstable feature used` 在 stable rustc 上

某些宏或 API 需要 nightly。**修法**:换 stable 版的等价、或者切 nightly。

### `the trait `Display` is not implemented` 在 `println!("{}", x)`

实现 `Display`,或在调试场景用 `{:?}` 配 `Debug`。

---

## 习题 / 实战练习

1. 故意写 10 段触发上述错误的代码,把编译器输出贴在每一项下面,对比模板。
2. 找最近一次你卡过的 Rust 编译错误,按这个模板写一段"日志"——下次更快定位。
3. 培养一个习惯:**先把整段编译器输出读完再 google**——80% 时间编译器自己已经给了 fix suggestion。

---

> **本章一句话总结**
>
> Rust 编译器的报错信息是它给你最大的礼物。学会读它,胜过看十本教程——其他语言的 runtime 错误,Rust 让你在 cargo check 里就看见。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
