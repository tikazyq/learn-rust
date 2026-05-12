# Ch 7 · 泛型与生命周期进阶

> Rust 类型系统的深水区

**核心问题**:为什么 Rust 类型系统能表达比 Go / C# 复杂得多的约束?为什么这些约束在工程上值得?

Part II 前三章你已经能写"够用的" Rust:struct、enum、trait、Result、错误处理。这一章是把"够用"推到"地道"——一旦看懂 monomorphization、HRTB、variance、GAT,你会发现自己读标准库、读 tokio、读 axum 时,90% 的"看不懂"瞬间变成"原来如此"。

读完你应该能:

1. 解释 monomorphization 的代价,知道什么时候该切到 `dyn Trait`
2. 用 `where` 写出比 `T: Trait` 复杂得多的约束
3. 看懂"`'a` is invariant over `T`"这种文档,并知道 PhantomData 是干嘛的
4. 在签名里写 `for<'a> Fn(&'a T)`,并解释为什么必须这样写
5. 区分 GAT 跟 associated type,知道 GAT 解决了哪类设计

---

## 7.1 Monomorphization:零成本抽象的真实代价

### 什么是 monomorphization

C++ template、Rust 泛型、C# unconstrained generic 的实现方式有一个共同名字:**单态化**。编译器把每个具体类型实例化一份代码。

```rust
fn largest<T: PartialOrd>(list: &[T]) -> &T {
    let mut largest = &list[0];
    for item in list {
        if item > largest { largest = item; }
    }
    largest
}

fn main() {
    let v_i32 = vec![1, 2, 3];
    let v_f64 = vec![1.0, 2.0, 3.0];
    largest(&v_i32);
    largest(&v_f64);
}
```

编译后,等价于:

```rust,ignore
fn largest_i32(list: &[i32]) -> &i32 { /* 内联 PartialOrd::gt for i32 */ }
fn largest_f64(list: &[f64]) -> &f64 { /* 内联 PartialOrd::gt for f64 */ }
```

调用是直接函数调用,没有虚表查找。这就是 Rust 所说的 "zero-cost":**运行时和手写一个类型的版本一样快**。

### 跟其他语言对比

| 语言 | 实现方式 | 运行时代价 | 编译时代价 |
|---|---|---|---|
| Go(generics, 1.18+) | GC shape stenciling | 接近 interface(轻微 boxing) | 中等 |
| Java / C#(reference type) | type erasure / shared code | virtual dispatch | 低 |
| C#(value type) | reified, per-type code | 零(同 Rust) | 中 |
| C++ template | 单态化 | 零 | 高 |
| Rust | 单态化 | 零 | 高 |

Rust 和 C++ 在同一阵营。**编译时间和二进制体积换运行时性能**。

### 代价 1:二进制膨胀

```rust,ignore
// 你以为这一个函数
fn parse_json<T: DeserializeOwned>(s: &str) -> Result<T> { ... }

// 实际编译出 10 份(每种被调用类型一份):
// parse_json::<User>
// parse_json::<Order>
// parse_json::<Settings>
// ...
```

一个被 serde 调用上百次的库,二进制体积涨几十 MB 是常态。这就是为什么 `ripgrep` release build 比 `grep` 大几倍。

### 代价 2:编译时间

每个实例化的版本要单独编译、内联、优化。`serde + tokio` 是 Rust 编译慢的两大主因。

工程对策:

1. **隔离泛型**:让 generic 函数只做"分发",真正的工作交给非 generic 的内层函数。

   ```rust,ignore
   pub fn load_config<P: AsRef<Path>>(path: P) -> Result<Config> {
       load_config_impl(path.as_ref()) // 内层是 &Path,非泛型
   }
   fn load_config_impl(path: &Path) -> Result<Config> { ... }
   ```

   外层只是"把 P 转成 &Path",编译开销极小;真正的逻辑只编一份。

2. **必要时切到 `dyn`**:当类型种类多、调用次数少,用 trait object 反而更划算。

### 代价 3:看不见的代码

你写 `T: Display + Debug + Clone + Send + Sync`,编译器要为每个具体 T 生成 4 个 trait 的实现链接。错误信息也会变冗长。

### 什么时候切到 `dyn Trait`

| 信号 | 偏好 |
|---|---|
| 类型集合在编译期是封闭的(已知 3-5 种) | enum 或 generic |
| 类型由运行时数据决定(plugin / config-driven) | `Box<dyn Trait>` |
| 调用次数极高(每秒百万级) | generic |
| 关心二进制体积或编译时间 | `dyn` |

经验:**生产代码默认 generic,二进制体积报警了再切 dyn**。

---

## 7.2 where 子句:比 `T: Trait` 表达力强一倍

### 基础

```rust,ignore
fn print_all<T>(items: &[T]) where T: Display {
    for item in items { println!("{}", item); }
}
```

跟 `<T: Display>` 等价。但 `where` 的真本事在复杂约束。

### 多重约束

```rust,ignore
fn process<T, U>(t: T, u: U) -> String
where
    T: Display + Clone + Send + 'static,
    U: AsRef<str> + Debug,
{
    format!("{:?} -> {}", u, t.clone())
}
```

行内 `<T: A + B + C, U: D + E>` 写起来挤,`where` 一行一约束,可读性碾压。

### 关联类型上的约束

```rust,ignore
fn collect_to_vec<I>(iter: I) -> Vec<I::Item>
where
    I: Iterator,
    I::Item: Clone + Send,   // 给关联类型加约束 —— 行内语法做不到
{
    iter.collect()
}
```

行内 `<I: Iterator<Item: Clone>>` 写不出来(`Item: Clone` 在行内是错误语法)。`where` 是唯一选择。

### 引用类型上的约束(HRTB 预告)

```rust,ignore
fn apply<F>(f: F)
where
    F: for<'a> Fn(&'a str) -> &'a str,  // 见 7.4
{ /* ... */ }
```

### 条件实现(blanket impl with constraint)

```rust,ignore
impl<T> Display for Wrapper<T>
where
    T: Display + Sized,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "Wrapper({})", self.0)
    }
}
```

`Wrapper<T>` 只有在 T 实现 Display 时才有 Display。这是标准库到处在用的模式(`Option<T>: Display where T: Display`)。

### 实战:看懂 std::iter::Iterator::collect

```rust,ignore
fn collect<B: FromIterator<Self::Item>>(self) -> B
where
    Self: Sized,
```

读法:

- `Self: Sized` —— self 不能是 trait object
- `B: FromIterator<Self::Item>` —— 目标容器要能从 self 的 Item 流构造
- 返回值的类型由调用方通过 `::<B>` 决定 —— 这就是 `let v: Vec<_> = iter.collect()` 那个 Vec 注解的来源

Rust 把"如何收集"完全外包给 `FromIterator` trait。Go 里你得为 Vec、HashSet、HashMap 各写一套 `Collect`。

---

## 7.3 Variance:协变 / 逆变 / 不变

### 直觉:子类型替换

Rust 没有继承,但有"子类型"概念——**lifetime 之间存在子类型关系**:`'static <: 'a`(`'static` 是任何 `'a` 的子类型,因为 `'static` 活得更长,什么场合都能用)。

Variance 回答的问题:**`F<'a>` 与 `F<'b>` 之间的子类型关系怎么传递?**

| 名字 | 含义 | 例子 |
|---|---|---|
| 协变 covariant | `'a <: 'b` 推出 `F<'a> <: F<'b>` | `&'a T` over `'a` |
| 逆变 contravariant | `'a <: 'b` 推出 `F<'b> <: F<'a>` | `fn(&'a T)` over `'a` |
| 不变 invariant | 两个方向都不传递 | `&'a mut T` over `'a` |

### 为什么 `&'a T` 是协变的

```rust,ignore
fn print(s: &'short str) { println!("{}", s); }

let long: &'static str = "hi";   // 'static <: 'short
print(long); // OK
```

`&'static str` 可以当 `&'short str` 用,因为它"活得更久"。这就是协变。

### 为什么 `&'a mut T` 是不变的

```rust,ignore
fn swap<'a>(a: &'a mut &'a str, b: &'a mut &'a str) { ... }

let mut long: &'static str = "hello";
let short = String::from("world");
let mut short_ref: &str = &short;
// 如果 &'a mut 是协变的:
swap(&mut long, &mut short_ref);
// long 现在指向 short,但 short 在外层 scope 结束后会 drop
// 之后访问 long ⇒ use-after-free
```

`&mut` 既被读又被写,既要协变又要逆变,结果只能不变。这是 Rust 唯一的"不变" reference。

### PhantomData:告诉编译器我"逻辑上"持有 T

```rust
use std::marker::PhantomData;

struct MyBox<T> {
    ptr: *const T,
    _marker: PhantomData<T>,
}
```

裸指针 `*const T` 不参与 drop check 和 variance 推断。`PhantomData<T>` 是给编译器看的:"这个结构体在所有权语义上拥有一个 T",让 variance / drop check / Send / Sync 推断正确工作。

PhantomData 的几种"味道":

| 写法 | 语义 |
|---|---|
| `PhantomData<T>` | 拥有 T,对 T 协变 |
| `PhantomData<&'a T>` | 借用 T,对 'a/T 协变 |
| `PhantomData<*mut T>` | 不变,且不是 Send/Sync |
| `PhantomData<fn() -> T>` | 协变,且 Send + Sync |

写 unsafe 容器时,选错 PhantomData 是经典 unsoundness 来源(参见 18 章)。

---

## 7.4 HRTB:Higher-Ranked Trait Bounds

### 动机

写一个高阶函数,它的参数是一个能处理"**任意 lifetime** 的 `&str`"的闭包:

```rust,ignore
fn apply<F>(f: F)
where
    F: for<'a> Fn(&'a str) -> &'a str,
{
    let s1 = String::from("hello");
    println!("{}", f(&s1));
    let s2 = String::from("world");
    println!("{}", f(&s2));
}
```

`for<'a>` 读作 "for any lifetime 'a"——F 必须对**所有**可能的 `'a` 都成立,而不是某个具体的 `'a`。

### 跟普通 lifetime 的差别

```rust,ignore
// 错的写法:'a 是函数签名里的 lifetime 参数
fn apply<'a, F>(f: F)
where F: Fn(&'a str) -> &'a str,
{ /* ... */ }
// 这里 'a 在调用 apply 时就被确定了,不能用不同 lifetime 的两个 String 调 f
```

```rust,ignore
// 对的写法:'a 由 HRTB 量化,调用 f 时每次新定
fn apply<F>(f: F)
where F: for<'a> Fn(&'a str) -> &'a str,
{ /* ... */ }
```

### 为什么大部分时候不用写

编译器对 `Fn(&T) -> &T` 这种 trait bound 默认就按 HRTB 推断。**只有当你想显式写、或编译器推不出来时**,才手写 `for<'a>`。常见场景:trait object `Box<dyn for<'a> Fn(&'a str)>`,或 serde 自定义 deserializer。

---

## 7.5 GATs:Generic Associated Types

### 普通 associated type 的局限

```rust
trait Iterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
}
```

`Item` 是固定类型——`Iterator for Vec<String>` 的 Item 永远是 `String`(或 `&String`,看实现)。但有一类 iterator 想做不到:**返回的元素借用了 self**。

经典反例 —— "lending iterator":

```rust,ignore
trait LendingIterator {
    type Item<'a> where Self: 'a;   // ← GAT
    fn next<'a>(&'a mut self) -> Option<Self::Item<'a>>;
}
```

每次调用 `next`,Item 的 lifetime 跟当次的 `&mut self` 绑定。这就是 GAT 解决的问题——**关联类型本身带参数**。

### 一个具体例子:WindowsMut

要做一个 iterator,每次给出一个对内部 buffer 的可变窗口:

```rust,ignore
struct WindowsMut<'b, T> { buf: &'b mut [T], size: usize, pos: usize }

impl<'b, T> LendingIterator for WindowsMut<'b, T> {
    type Item<'a> = &'a mut [T] where Self: 'a;
    fn next<'a>(&'a mut self) -> Option<Self::Item<'a>> {
        if self.pos + self.size > self.buf.len() { return None; }
        let window = &mut self.buf[self.pos..self.pos + self.size];
        self.pos += 1;
        Some(window)
    }
}
```

普通 `Iterator` 做不到——因为 `type Item` 没法引用 `'a`(self 的 lifetime)。

### 工程意义

- async trait(`async fn` in trait)在底层就靠 GAT 把"返回的 Future"参数化到 self 的 lifetime。
- 任何"借用 self 的迭代"——database cursor、parser 状态机、stream chunking——GAT 都能让 API 自然。

### 注意

GAT 在 1.65 稳定,但表达力仍在演进。复杂签名容易触发"未实现"或推断失败。**用,但不要炫**——库作者要懂,业务代码 90% 用不到。

---

## 7.6 实战:设计一个借用 self 的 Iterator

业务:解析日志文件,每次返回一个 `&str` 切片(指向内部 buffer,避免分配)。

### 朴素 Iterator(行不通)

```rust,ignore
struct LogParser<R: BufRead> { reader: R, buf: String }

impl<R: BufRead> Iterator for LogParser<R> {
    type Item = &str;   // ❌ 没法写 lifetime
    fn next(&mut self) -> Option<&str> { /* ... */ }
}
```

`Iterator::Item` 没法跟 `&mut self` 共享 lifetime,编译器拒绝。

### 用 LendingIterator(GAT)

```rust,ignore
trait LendingIterator {
    type Item<'a> where Self: 'a;
    fn next(&mut self) -> Option<Self::Item<'_>>;
}

struct LogParser<R: BufRead> { reader: R, buf: String }

impl<R: BufRead> LendingIterator for LogParser<R> {
    type Item<'a> = &'a str where Self: 'a;
    fn next(&mut self) -> Option<&'_ str> {
        self.buf.clear();
        match self.reader.read_line(&mut self.buf) {
            Ok(0) | Err(_) => None,
            Ok(_) => Some(self.buf.trim_end()),
        }
    }
}
```

代价:不能用 `for x in parser` 语法糖,也不能直接 `.collect()`。LendingIterator 是更弱的接口,换来 zero-copy。

### 替代方案:返回 owned `String`

```rust,ignore
impl<R: BufRead> Iterator for LogParser<R> {
    type Item = String;
    fn next(&mut self) -> Option<String> { /* 每行分配一个 String */ }
}
```

简单、能 collect、支持 `for` 循环;代价是每行一次分配。

**工程判断**:90% 业务场景用 owned `String`,剩下 10% 性能敏感才上 GAT。**先简单再优化**。

---

## 习题

1. 给 Ch 6 你设计的 `Storage` trait 加一个 GAT 版本的"按 key 借出 entry"方法,签名是什么?
2. `Cow<'a, str>` 在 `'a` 上是协变、逆变、还是不变?为什么?
3. 写一个函数 `fn apply<F: ?>(f: F)`,它的 F 是"对任意类型 T 都能调用的闭包"。能写吗?为什么 Rust 不支持类型层面的 HRTB?
4. 用 `cargo expand` 看 `serde_json::from_str::<MyStruct>` 编译后展开成什么。
5. 设计:一个 plugin 系统,运行时从 `.so` 加载实现。该用 generic 还是 `dyn`?给出选择和论据。

---

> **本章一句话总结**
>
> 类型系统的高级特性不是炫技,是表达力的延伸——你越能用类型表达约束,运行时 bug 越少。但每用一项,都要问一句"业务真的需要这个表达力吗?"

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
