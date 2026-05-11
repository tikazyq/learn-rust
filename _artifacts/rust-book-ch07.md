# 第 7 章 · Generics、Lifetime、Variance

> "Once you understand variance, you understand why Rust's type system is the way it is."

Ch 6 我们看了 trait。Ch 7 我们处理 trait 的双胞胎——**泛型与生命周期的进阶**。这一章会触及 Rust 类型系统最深的几个角落:monomorphization、variance、HRTB、GAT。读完你看 stdlib 几乎任何复杂签名都不再害怕。

读完这章你应该能:

1. 解释 Rust 泛型为什么没有 Go 泛型那种运行时开销
2. 看到 `for<'a>` 不再恐慌——你知道 HRTB 在解决什么问题
3. 判断一个类型在某个 lifetime 上是协变、逆变、还是不变
4. 看懂 stdlib 的 `Iterator::collect` 签名,以及 `FromIterator` 的工程意义
5. 知道 GAT 解决了什么过去做不到的事情

---

## 7.1 Monomorphization:Rust 泛型的运行时成本

### Go 泛型 vs Rust 泛型

Go 1.18 加了泛型。Go 的实现策略是 **dictionary passing + GC shape**——所有指针类型共享一份代码,所有相同大小的非指针类型共享一份代码。运行时通过字典查找方法。

代价:**调用泛型方法有运行时间接开销**,且编译器优化受限。

Rust 选了相反的路径:**monomorphization**(单态化)——编译器为每个具体类型生成一份独立的函数代码。

```rust
fn print<T: Display>(x: T) {
    println!("{}", x);
}

print(42);          // 生成 print::<i32>
print("hello");     // 生成 print::<&str>
print(3.14);        // 生成 print::<f64>
```

编译后是三份独立的代码,每份针对具体类型优化。结果:

- 调用零开销(就是普通函数调用)
- 可以内联
- 可以做类型特定的优化

代价:

- 编译时间长(每个具体类型都要生成代码)
- 二进制体积大
- 泛型函数本身不能被 dyn(dyn 需要 vtable,monomorphization 后没有"通用版本")

### 实际开销估算

```rust
fn add<T: std::ops::Add<Output = T>>(a: T, b: T) -> T {
    a + b
}

let _ = add(1i32, 2i32);
let _ = add(1.0f64, 2.0f64);
```

编译后大致等同于:

```rust
fn add_i32(a: i32, b: i32) -> i32 { a + b }
fn add_f64(a: f64, b: f64) -> f64 { a + b }
```

两份独立代码,各自直接对应 CPU 的整数加法/浮点加法指令。Zero overhead 不是修辞,是实际汇编。

### 工程含义

| 维度 | Monomorphization (Rust) | Dictionary passing (Go) | Type erasure (Java) |
|---|---|---|---|
| 运行时开销 | 零 | 有(字典查找) | 有(装箱/拆箱) |
| 编译时间 | 长 | 短 | 短 |
| 二进制大小 | 大 | 小 | 小 |
| 优化空间 | 高 | 中 | 低 |

Rust 选 mono 是因为它的设计哲学是"零成本抽象"——抽象不应该比手写慢。Go 选 dict 是因为它的设计哲学是"快编译"。两条路都对,看你的目标。

### 二进制膨胀如何缓解

如果你的泛型函数被几十种类型实例化,二进制会膨胀。常见缓解策略:**把泛型函数的"非泛型核心"抽出来**:

```rust
// 膨胀:整个函数都泛型
fn load<T: Read>(reader: T) -> Vec<u8> {
    let mut buf = Vec::new();
    reader.read_to_end(&mut buf).unwrap();
    process(&buf);   // 假设 process 很大
    buf
}

// 优化:只泛型外层,核心非泛型
fn load<T: Read>(mut reader: T) -> Vec<u8> {
    let mut buf = Vec::new();
    reader.read_to_end(&mut buf).unwrap();
    load_inner(&buf);
    buf
}

fn load_inner(buf: &[u8]) {
    process(buf);    // 这部分只编译一次
}
```

每个 T 只生成"读到 buf"这一小段重复代码,核心处理逻辑共享一份。这个模式 stdlib 大量使用——你看 `Vec::push` 的源码就有 `inner` 函数。

---

## 7.2 Where 子句:复杂约束的标准语法

简单约束直接写 `<T: Foo + Bar>`,复杂约束用 `where` 子句:

```rust
fn merge<I, J, T>(a: I, b: J) -> Vec<T>
where
    I: IntoIterator<Item = T>,
    J: IntoIterator<Item = T>,
    T: Ord,
{
    let mut result: Vec<T> = a.into_iter().chain(b.into_iter()).collect();
    result.sort();
    result
}
```

不用 `where`,签名会挤成一行:

```rust
fn merge<I: IntoIterator<Item = T>, J: IntoIterator<Item = T>, T: Ord>(a: I, b: J) -> Vec<T>
```

`where` 子句还能表达 `<` 语法表达不了的约束:

```rust
fn process<T>(x: T) where for<'a> &'a T: Display {
    // ...
}
```

这是 HRTB(下一节展开),`<` 语法不支持。

工程经验:**bound 多于 1-2 个就用 where 子句**,可读性好。stdlib 几乎所有复杂签名都用 where。

---

## 7.3 Variance:你不知道你需要这个,直到你需要

考虑这个问题:`&'static str` 能不能传给要 `&'a str` 的函数?

直觉:能。`'static` 比任何 `'a` 都"长",更长不就更安全吗?

```rust
fn print(s: &str) {           // 实际签名是 fn print<'a>(s: &'a str)
    println!("{}", s);
}

let s: &'static str = "hello";
print(s);                     // ✅ 编译通过
```

确实能。这是因为 `&'a T` 在 `'a` 上是 **协变(covariant)** 的——`&'static T` 是 `&'a T` 的"子类型",可以在任何要 `&'a T` 的地方使用。

### Variance 是什么?

**Variance** 描述类型构造器(`&_`、`Vec<_>`、`fn(_) -> _`)如何"传递"子类型关系。三种 variance:

| Variance | 含义 | 例子 |
|---|---|---|
| **Covariant**(协变) | `'long` 长 → `F<'long>` 是 `F<'short>` 的子类型 | `&'a T` 在 `'a` 上协变 |
| **Contravariant**(逆变) | `'long` 长 → `F<'long>` 是 `F<'short>` 的**父**类型 | `fn(&'a T)` 在 `'a` 上逆变 |
| **Invariant**(不变) | `'long` 长 ≠ 关系任何方向 | `&'a mut T` 在 `'a` 上不变 |

### 协变最常见

`&'a T` / `Box<T>` / `Vec<T>` / `Option<T>` 都对内部类型协变。"长生命周期可以传给短生命周期"是默认行为。

### 逆变很少见但重要

`fn(&'a T) -> ()`——接受 `&'a T` 的函数。

直觉:如果你有一个能处理 `&'static str` 的函数,你能不能用它处理 `&'a str`?

不能。处理 `&'static str` 意味着"假设输入活很久",拿一个短命的输入来用,可能在内部存到 `'static` 槽位,出问题。

反过来:如果你有一个能处理 `&'a str`(任意短生命周期)的函数,你能不能用它处理 `&'static str`?

能。能处理短的就能处理长的(用得短一些就行)。

所以 `fn(&'a T)` 在 `'a` 上是逆变——`fn(&'short T)` 是 `fn(&'long T)` 的子类型。

### 不变最容易踩坑

`&'a mut T` 在 `'a` 上不变。这就是为什么:

```rust
fn extend<'a>(v: &mut Vec<&'a str>, s: &'a str) {
    v.push(s);
}

let mut v: Vec<&'static str> = vec!["hello"];
let local = String::from("world");
// extend(&mut v, &local);  // ❌ 不能,&'a mut Vec<&'a str> 在 'a 上不变
```

如果 `&mut Vec<&'a str>` 协变,你就能传一个 `&'static str` 槽位给一个临时引用,然后局部变量销毁后 vec 里就有悬垂引用了。

不变性保护你免于此。代价是某些"看起来该工作"的代码不工作,但这是必要的。

### 工程含义

99% 的情况你不需要主动想 variance。但当你设计带 lifetime 的 struct,或者写涉及函数指针的代码,遇到诡异的编译错误,**检查 variance 是排查思路**。

stdlib 的 `Cell<T>` 在 T 上不变,`PhantomData<T>` 在 T 上协变,`fn(T)` 在 T 上逆变。这些设计决定都有原因,Rustonomicon 里有详细解释,Ch 18 我们会简单触及。

---

## 7.4 HRTB:`for<'a>` 在解决什么

考虑一个高阶函数:接受一个"对任意生命周期都能工作"的 closure。

```rust
fn apply<F>(f: F)
where
    F: Fn(&str) -> bool,
{
    let s1 = String::from("hello");
    let s2 = String::from("hi");
    f(&s1);
    f(&s2);
}
```

`f(&s1)` 和 `f(&s2)` 传入的 `&str` 生命周期不同。`F` 要能接受**任意**生命周期的 `&str`,不能只接受特定 `'a`。

这就是 HRTB(Higher-Ranked Trait Bound)——"对所有 'a 都满足这个 trait":

```rust
fn apply<F>(f: F)
where
    F: for<'a> Fn(&'a str) -> bool,
//     ^^^^^^^^^ 对任意 'a
{
    // ...
}
```

实际上 `Fn(&str) -> bool` 编译器自动展开成 `for<'a> Fn(&'a str) -> bool`——这是 lifetime elision 的一部分。你写的简短版本编译器加了 `for<'a>`。

### 什么时候需要显式写 `for<'a>`?

- 函数返回 `impl Fn` 时,你想约束接受任意生命周期的输入
- 复杂 trait bound,elision 推不出来
- 给 trait 加 lifetime 约束

例子:

```rust
fn make_validator<F>() -> impl Fn(&str) -> bool
where
    F: for<'a> Fn(&'a str) -> bool,
{
    // ...
}
```

工程经验:**绝大多数代码不需要写 `for<'a>`,elision 帮你**。看到它出现,通常是签名涉及高阶函数或复杂 trait bound。

---

## 7.5 GAT:Generic Associated Types

GAT 是 Rust 1.65(2022年底)稳定的特性。它解决一个旧问题:**关联类型本身需要带泛型参数**。

### 问题:lending iterator 为什么过去做不到

考虑你想写一个"借用迭代器"——每个 `next()` 返回内部缓冲区的一段引用:

```rust
trait LendingIterator {
    type Item<'a>     // ❌ 1.65 之前不能写
        where Self: 'a;
    fn next<'a>(&'a mut self) -> Option<Self::Item<'a>>;
}
```

每次 next 返回的引用生命周期跟 self 的借用相关。这种"关联类型本身有生命周期参数"的需求,老的关联类型表达不出来。

stdlib 的 `Iterator::Item` 是 `type Item;`——固定类型,没有 lifetime 参数。所以 `Vec<T>::iter()` 返回的迭代器 `Item = &'a T`,这里 `'a` 是从外部 lifetime 推断的,但这个迭代器一旦创建,Item 就固定下来。

### GAT 后

```rust
trait LendingIterator {
    type Item<'a> where Self: 'a;
    fn next<'a>(&'a mut self) -> Option<Self::Item<'a>>;
}

struct WindowsMut<'data, T> {
    slice: &'data mut [T],
    size: usize,
}

impl<'data, T> LendingIterator for WindowsMut<'data, T> {
    type Item<'a> = &'a mut [T] where Self: 'a;
    fn next<'a>(&'a mut self) -> Option<Self::Item<'a>> {
        if self.slice.len() < self.size {
            None
        } else {
            let (head, _) = self.slice.split_at_mut(self.size);
            // 实际实现复杂一些,这里简化
            Some(head)
        }
    }
}
```

`WindowsMut` 是 "可变窗口迭代器"——每次 next 返回一个 `&mut [T]`,生命周期跟当次 next 调用绑定。这种模式过去要么用 unsafe,要么用宏,要么放弃。GAT 后是干净的安全 Rust。

### GAT 的工程意义

GAT 让 Rust 类型系统接近 Haskell 的表达力。具体启用的设计:

- **lending iterator**:借用迭代,零拷贝
- **streaming iterator**:跟 lending 类似
- **higher-kinded type 的近似**:虽然不是完整 HKT,但能表达很多 HKT 场景

绝大部分应用代码不需要直接用 GAT。但当你设计库 API,尤其是迭代器、parser、reactor 这类与生命周期深度交互的抽象,GAT 是工具箱里的重要工具。

---

## 7.6 实战:看懂 `Iterator::collect`

Iterator 的 `collect` 是 Rust 最强大也最难懂的方法之一。我们用本章工具拆解它。

### 它的签名

```rust
trait Iterator {
    type Item;
    fn collect<B: FromIterator<Self::Item>>(self) -> B
    where
        Self: Sized,
    {
        FromIterator::from_iter(self)
    }
}
```

读法:

- `B` 是泛型参数,代表"我要收集到什么容器"
- `B: FromIterator<Self::Item>` 是 bound,B 必须能"从迭代器构造"
- `Self::Item` 是这个迭代器产生的元素类型

调用:

```rust
let v: Vec<i32> = (1..=5).collect();
//      ^^^^^^^^ 这里指定 B = Vec<i32>
```

或用 turbofish:

```rust
let v = (1..=5).collect::<Vec<i32>>();
```

### `FromIterator` 是什么

```rust
trait FromIterator<A>: Sized {
    fn from_iter<T>(iter: T) -> Self
    where
        T: IntoIterator<Item = A>;
}
```

任何能"从一组元素构造自己"的类型实现 `FromIterator`。`Vec<T>` 实现了 `FromIterator<T>`,`HashMap<K, V>` 实现了 `FromIterator<(K, V)>`,`String` 实现了 `FromIterator<char>`。

所以:

```rust
let v: Vec<i32> = (1..=5).collect();
let s: String = vec!['h', 'i'].into_iter().collect();
let m: HashMap<i32, String> = vec![(1, "a".into())].into_iter().collect();
```

同一个 `collect()` 方法,目标类型不同,行为不同——这是泛型 + trait 的力量。

### `Result<Vec<T>, E>` 的魔法

最妙的用法:

```rust
let strs = vec!["1", "2", "3"];
let nums: Result<Vec<i32>, _> = strs.iter().map(|s| s.parse::<i32>()).collect();
```

`map` 返回 `Iterator<Item = Result<i32, ParseIntError>>`。`collect` 居然能把它转成 `Result<Vec<i32>, ParseIntError>`!

原理:stdlib 给 `Result` 实现了一个特殊的 `FromIterator`——当迭代器的 Item 是 `Result<T, E>`,如果全部 Ok,collect 出 `Ok(Vec<T>)`;遇到第一个 Err,短路返回 Err。

```rust
impl<A, E, V: FromIterator<A>> FromIterator<Result<A, E>> for Result<V, E> {
    fn from_iter<I: IntoIterator<Item = Result<A, E>>>(iter: I) -> Result<V, E> {
        // 遍历迭代器,遇到 Err 立即返回,全 Ok 时调用 V 的 from_iter
    }
}
```

这个 blanket impl 让一个看似具体的需求("收集 Result 列表,失败时短路")用通用机制优雅解决。

### 读懂这段代码

```rust
let users: Result<Vec<User>, _> = ids
    .iter()
    .map(|id| db.load_user(*id))
    .collect();
```

读法:对每个 id 调 load_user(返回 `Result<User, DbError>`),收集所有结果。如果全成功,`users = Ok(Vec<User>)`;如果某个失败,`users = Err(那个错误)`,后续 ids 不再处理。

这就是 Rust 类型系统给你的——一段表达力极强的代码,用通用工具拼出来。

---

## 7.7 章末小结与习题

### 本章核心概念回顾

1. **Monomorphization**:Rust 泛型零运行时开销,代价是编译时间和二进制大小
2. **Where 子句**:复杂约束的标准写法,可读性好,能表达 `<` 写不了的约束
3. **Variance**:协变 / 逆变 / 不变,决定子类型关系如何传递。99% 时候不用主动想,但偶尔关键
4. **HRTB**:`for<'a>` 表达"对所有生命周期"的约束,elision 帮你写绝大多数
5. **GAT**:关联类型可以有自己的泛型参数,启用 lending iterator 等模式
6. **`collect` + `FromIterator`**:Rust 泛型表达力的活样本,`Result<Vec<T>, E>` 的短路收集是惊艳的设计

### 习题

#### 习题 7.1(简单)

把下面签名改写成 where 子句风格:

```rust
fn merge<I: IntoIterator<Item = T>, J: IntoIterator<Item = T>, T: Ord + Clone>(
    a: I, b: J
) -> Vec<T> { ... }
```

#### 习题 7.2(中等)

下面代码不能编译,从 variance 角度解释为什么:

```rust
fn store<'a>(target: &mut &'a str, source: &'a str) {
    *target = source;
}

fn main() {
    let mut target: &'static str = "default";
    {
        let local = String::from("local");
        store(&mut target, &local);  // ❌
    }
    println!("{}", target);
}
```

#### 习题 7.3(中等)

读懂下面 stdlib 签名,解释每一部分:

```rust
impl<K, V, S> HashMap<K, V, S>
where
    K: Eq + Hash,
    S: BuildHasher,
{
    pub fn iter(&self) -> Iter<'_, K, V> { ... }
}
```

特别解释:`'_`、`BuildHasher` 各是什么。

#### 习题 7.4(困难)

实现一个泛型函数 `partition`:

```rust
fn partition<I, T, F>(iter: I, pred: F) -> (Vec<T>, Vec<T>)
where
    I: ???,
    F: ???,
{
    // 把 iter 中满足 pred 的放第一个 Vec,其余放第二个
}
```

填完 trait bounds。要求接受 `Vec<T>`、`HashSet<T>`、`Range<T>` 等任何能迭代的输入。

#### 习题 7.5(开放)

去 stdlib 文档里找一个让你看不懂的复杂签名(`Iterator::flat_map`、`Result::map_err`、`Future::then` 都是好候选)。把它的每一部分拆开解释。

如果遇到 `for<'a>` 或 GAT,试着用本章工具理解它在解决什么。

---

### 下一章预告

Ch 8 我们离开类型系统,进入**内存与资源管理**。智能指针——Box、Rc、Arc、Cow——是 Rust 工程代码里到处出现的工具,它们的语义差异决定你的代码是不是地道。

---

> **本章一句话总结**
>
> Rust 的类型系统深度可以让你一辈子学不完。但 monomorphization、variance、HRTB、GAT 这四个概念覆盖了 80% 的复杂场景。看见复杂签名时,知道它属于哪个概念,你就能拆解它。
