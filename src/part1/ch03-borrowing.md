# Ch 3 · Borrowing 与 Lifetime —— 编译器是结对程序员

> "Lifetimes are the most distinctive feature of Rust. They're also the most misunderstood."

Ch 2 我们说 ownership 是"每个值有一个 owner,owner 出作用域时 drop"。这一章我们处理一个直接派生的问题:**如果某个函数想暂时使用一个值,但不想接管所有权,怎么办?**

答案是 **borrowing(借用)**。但借用不是免费的——为了保证安全,Rust 引入了一组借用规则,和一个叫 **lifetime** 的概念。

读完这章,你应该能:

1. 说清楚 `&T` 和 `&mut T` 为什么必须互斥
2. 看到 `'a` 标注时不再恐慌——你知道它在告诉编译器什么
3. 读懂 Rust 编译器最常见的 5 种借用报错
4. 给一个函数签名,判断它的生命周期标注是否合理
5. 知道 `'static` 的真实含义,不再误用

---

## 3.1 为什么需要借用?

先看一个看似无害的需求。我们有一个大 `Vec<String>`,想写个函数计算其中字符串的总长度:

```rust
fn total_length(strs: Vec<String>) -> usize {
    strs.iter().map(|s| s.len()).sum()
}

fn main() {
    let v = vec![
        String::from("hello"),
        String::from("world"),
    ];
    let n = total_length(v);
    println!("{}", n);
    // println!("{:?}", v);  // ❌ v 已经被 move 进 total_length
}
```

这个签名 `fn total_length(strs: Vec<String>)` 有问题——它接管了所有权。调用一次就消费一次,调用方再也用不了 `v` 了。

但语义上,`total_length` **只是想读一下**,根本不需要拥有这个 Vec。这正是借用要解决的事情:

```rust
fn total_length(strs: &Vec<String>) -> usize {
    strs.iter().map(|s| s.len()).sum()
}

fn main() {
    let v = vec![
        String::from("hello"),
        String::from("world"),
    ];
    let n = total_length(&v);
    println!("{}", n);
    println!("{:?}", v);  // ✅ v 还能用
}
```

`&Vec<String>` 是一个**共享借用**——函数借一下看看,不影响所有权。

(回顾 Ch 2:这里更地道的写法是 `&[String]` 而不是 `&Vec<String>`。但本章为了讲清借用本身,我们暂时用后者(`&Vec<String>`)。)

### 借用 ≠ 指针

**重要心智迁移**:

如果你来自 Go 或 C,可能想把 `&T` 理解成"指针"。表面看是,但 Rust 的引用比 C 指针多一组**编译期约束**:

| 维度 | C 指针 `T*` | Rust 引用 `&T` / `&mut T` |
|---|---|---|
| 可以为 NULL | ✅ | ❌(永远指向有效值) |
| 可以悬垂(指向已释放内存) | ✅ | ❌(编译期保证不悬垂) |
| 可以同时存在多个写指针 | ✅ | ❌(`&mut T` 必须独占) |
| 可以从越界数组偏移 | ✅(undefined behavior) | ❌ |
| 编译期类型检查 | 弱 | 强 |

Rust 的引用是"加了护栏的指针"。在汇编层面,`&T` 就是一个指针;在源码层面,它带着一组编译期保证。

### 这一节的关键 takeaway

借用是 ownership 的补丁——让函数可以"暂时使用"一个值而不接管所有权。`&T` 是共享借用,`&mut T` 是独占借用。下面我们详细说这两个为什么必须互斥。

---

## 3.2 借用规则:Aliasing XOR Mutability

Rust 的借用规则,标准表述是:

> 在任意时刻,一个值要么:
> - 有任意多个共享借用 `&T`(可以读,不能写)
> - 或者有且仅有一个独占借用 `&mut T`(可以读写)
>
> 二者不能并存。

学术界把这条规则叫 **"Aliasing XOR Mutability"**——别名(多个引用指向同一个值)和可变性,二者只能取其一。

### 为什么这条规则存在?

不是 Rust 设计者的洁癖。这条规则解决三个真实的工程问题。

#### 问题 1:数据竞争(data race)

如果一个值可以被多个线程同时读写,就有 data race。data race 是 undefined behavior,可能产生任何错误结果。

```go
// Go 里的 data race(运行时才能检测)
var counter int = 0
go func() { counter++ }()
go func() { counter++ }()
// 两个 goroutine 同时写 counter,结果未定义
```

Rust 的借用规则在编译期就拦住:你不可能同时持有两个 `&mut counter`。要跨线程共享可变状态,必须用 `Mutex` 或 `Atomic`,把同步显式化。

#### 问题 2:迭代失效(iterator invalidation)

C++ 经典 bug:

```cpp
std::vector<int> v = {1, 2, 3};
for (auto it = v.begin(); it != v.end(); ++it) {
    if (*it == 2) {
        v.push_back(4);  // 可能触发 vector 扩容,it 失效
    }
    // 下一次循环用 it,可能崩溃
}
```

Rust 的借用规则直接拦掉这种代码:

```rust,ignore
let mut v = vec![1, 2, 3];
for x in v.iter() {     // 这里有一个 &v 借用
    if *x == 2 {
        v.push(4);      // ❌ 错误:cannot borrow v as mutable because it is also borrowed as immutable
    }
}
```

`v.iter()` 持有 `&v`,在 `for` 循环内一直存活;`v.push(4)` 需要 `&mut v`,违反规则,编译期拦下。

#### 问题 3:别名优化(aliasing-based optimization)

现代 CPU 的优化假设"如果两个指针类型不同,它们指向的内存不重叠"。C 编译器有 `restrict` 关键字让你声明"这个指针没有别名,放心优化"。但程序员经常用错,产生 undefined behavior。

Rust 的借用规则等于天然的 `restrict`:`&mut T` 保证整个值在那段时间只通过这一个引用访问,编译器可以激进优化。

### 借用规则的实际形态

#### 多个共享借用 OK

```rust
let s = String::from("hello");
let r1 = &s;
let r2 = &s;
let r3 = &s;
println!("{} {} {}", r1, r2, r3);  // ✅ 都是只读
```

#### 一个独占借用 OK

```rust
let mut s = String::from("hello");
let r = &mut s;
r.push_str(" world");
println!("{}", r);  // ✅
```

#### 共享 + 共享 OK,共享 + 独占 NO

```rust,ignore
let mut s = String::from("hello");
let r1 = &s;        // 共享借用
let r2 = &mut s;    // ❌ 错误:cannot borrow as mutable because it is also borrowed as immutable
println!("{} {}", r1, r2);
```

#### 独占 + 独占 NO

```rust,ignore
let mut s = String::from("hello");
let r1 = &mut s;
let r2 = &mut s;    // ❌ 错误:cannot borrow as mutable more than once
println!("{} {}", r1, r2);
```

### NLL:借用提前结束

早期 Rust 的借用作用域是"词法作用域"——借用一直活到所在的 `{}` 结束。这导致很多本应合法的代码被拒绝。Rust 2018 引入 **NLL(Non-Lexical Lifetimes)**,借用的实际作用域是"最后一次使用之后立刻结束"。

```rust
let mut s = String::from("hello");
let r1 = &s;
let r2 = &s;
println!("{} {}", r1, r2);  // r1, r2 在此最后使用
                            // NLL 后:r1, r2 的借用在此结束

let r3 = &mut s;            // ✅ 现在可以独占借用
r3.push_str(" world");
println!("{}", r3);
```

如果没有 NLL,这段代码会被拒绝(`r1`/`r2` 的借用被认为活到 `}` 结束)。NLL 之后这是合法代码。

工程含义:**Rust 编译器比你想的聪明**。很多"借用冲突"其实可以靠重排代码顺序解决,而不是放弃 borrow 改成 clone。

### 这一节的关键 takeaway

借用规则不是约束,是定理——它让一大类并发 bug、迭代失效、别名问题在编译期就消失。你接受了这条规则,获得的是 fearless concurrency 和零成本优化。

---

## 3.3 Lifetime:`'a` 在标注什么?

到现在为止,我们写的借用都是 `&T` / `&mut T`,没有 `'a`。但 Rust 标准库里到处是这样的签名:

```rust,ignore
fn longest<'a>(x: &'a str, y: &'a str) -> &'a str { /* ... */ }
```

这个 `'a` 是什么?

### Lifetime 是关于"引用何时失效"的标注

简单事实:**任何引用都有一个有效区间**——从引用创建,到引用最后一次使用。这个区间就叫这个引用的 lifetime。

编译器的工作是检查:**引用使用时,被引用的值是否还活着**?

考虑这段代码:

```rust,ignore
fn main() {
    let r;
    {
        let x = 5;
        r = &x;
    }  // x 在这里 drop
    println!("{}", r);  // ❌ r 引用了一个已被 drop 的值
}
```

编译器报:

```text
error[E0597]: `x` does not live long enough
  |
4 |         r = &x;
  |             ^^ borrowed value does not live long enough
5 |     }
  |     - `x` dropped here while still borrowed
6 |     println!("{}", r);
  |                    - borrow later used here
```

编译器的推理:`r` 的使用要求 `x` 还活着,但 `x` 在更内层的作用域结束就 drop 了。冲突。

### 单个函数内,编译器自动推导

上面的例子,编译器**自己**就能推导出生命周期。你不用写 `'a`。

那 `'a` 什么时候必须写?

### `'a` 在跨函数边界时显现

考虑这个函数:

```rust
fn first_word(s: &str) -> &str {
    let bytes = s.as_bytes();
    for (i, &b) in bytes.iter().enumerate() {
        if b == b' ' {
            return &s[..i];
        }
    }
    s
}
```

返回值 `&str` 是从参数 `s` 派生出来的——它指向 `s` 内部的一段。**返回的引用必须活得不久于 `s`**,否则就是悬垂引用。

但编译器看到这个签名时不知道这个事实。它怎么知道返回的 `&str` 应该跟 `s` 关联,而不是凭空冒出来的?

答案是:**生命周期标注**。完整签名应该是:

```rust,ignore
fn first_word<'a>(s: &'a str) -> &'a str { /* ... */ }
```

读法:"对于任意生命周期 `'a`,这个函数接受一个生命期为 `'a` 的 `&str`,返回一个生命期同为 `'a` 的 `&str`。"

这个签名告诉调用方:**返回的引用不能比 `s` 活得久**。

### Lifetime elision:大多数情况你不用写

但你刚才看到 `first_word` 的版本里,我们写的是 `fn first_word(s: &str) -> &str`,没写 `'a`,也能编译。

这是 Rust 的 **lifetime elision rules**(生命周期省略规则)在帮你。规则有三条:

1. 每个引用参数有它自己的 lifetime
2. 如果只有一个输入 lifetime,所有输出 lifetime 都跟它一致
3. 如果有多个输入 lifetime,但其中一个是 `&self` 或 `&mut self`,所有输出 lifetime 跟 `self` 一致

`first_word(s: &str) -> &str` 满足规则 2,自动推导成 `<'a>(s: &'a str) -> &'a str`。

什么时候规则覆盖不到、必须手动写?

### 必须手动写 `'a` 的场景

#### 多个引用参数,返回值跟其中一个绑定

```rust,ignore
fn longest(x: &str, y: &str) -> &str {
    if x.len() > y.len() { x } else { y }
}
```

编译器拒绝:**返回值应该跟 x 还是 y 的 lifetime 绑定?** 编译器不知道。

显式标注:

```rust
fn longest<'a>(x: &'a str, y: &'a str) -> &'a str {
    if x.len() > y.len() { x } else { y }
}
```

`'a` 是 x 和 y 中**较短**的那个 lifetime——编译器取交集。返回值不会比 x 或 y 中任何一个活得久。

#### struct 含引用字段

```rust
struct Excerpt<'a> {
    part: &'a str,
}
```

含引用的 struct 必须标注 lifetime。意思是"这个 Excerpt 不能比 part 引用的字符串活得久"。

#### 返回值需要不同于输入的 lifetime

少见,但存在:

```rust
fn longest_with_announcement<'a, 'b>(
    x: &'a str,
    y: &'a str,
    ann: &'b str,
) -> &'a str {
    println!("Announcement! {}", ann);
    if x.len() > y.len() { x } else { y }
}
```

这里 `ann` 的生命周期跟 x/y 无关,所以用了不同的 `'b`。

### 实操:看一个 lifetime 错误并修复

```rust,ignore
fn longest_owned(x: &str, y: &str) -> &str {  // 缺 lifetime
    if x.len() > y.len() { x } else { y }
}
```

编译器报:

```text
error[E0106]: missing lifetime specifier
  |
1 | fn longest_owned(x: &str, y: &str) -> &str {
  |                     ----     ----     ^ expected named lifetime parameter
  = help: this function's return type contains a borrowed value, but the signature does not
          say whether it is borrowed from `x` or `y`
help: consider introducing a named lifetime parameter
  |
1 | fn longest_owned<'a>(x: &'a str, y: &'a str) -> &'a str {
  |                 ++++     ++          ++          ++
```

Rust 的报错带着修复建议,**直接照着改就行**。这是 Rust 编译器的一个温柔——错误消息是设计过的,不是抛出去就完事。

### 这一节的关键 takeaway

`'a` 不是"我手动管理生命周期",是"我告诉编译器引用之间的关系"。绝大多数情况编译器自己推导。需要手动写 `'a` 的场景就那么几种,见多了就熟了。

---

## 3.4 `'static` Lifetime:不是"永远活着"

`'static` 是个特殊 lifetime,意思字面看是"静态的、永远活着"。但工程上有两个含义,经常混淆。

### 含义 1:`&'static T` —— 引用本身指向永久数据

```rust
let s: &'static str = "hello world";  // 字符串字面量是 'static
```

字符串字面量被嵌入二进制,程序运行期间一直存在,所以它们的引用是 `'static`。

```rust
static GREETING: &str = "hello";  // 也是 'static
```

`static` 关键字定义的全局变量,引用类型也是 `'static`。

### 含义 2:`T: 'static` —— 类型不持有任何短于 'static 的引用

这个更微妙。`T: 'static` 是一个 **trait bound**(其实是 lifetime bound),表示"类型 T 不持有任何借用,或者持有的所有借用都是 `'static` 的"。

哪些类型满足 `T: 'static`?

| 类型 | 是 `'static` 吗? | 为什么 |
|---|---|---|
| `i32` / `bool` | ✅ | 没有引用 |
| `String` | ✅ | 持有 owned heap 数据,没有借用 |
| `Vec<i32>` | ✅ | 同上 |
| `&'static str` | ✅ | 持有的引用本身是 'static |
| `&'a str`(其中 `'a` 不是 `'static`) | ❌ | 持有非 'static 引用 |
| `Box<dyn Trait>` | ❌(可能) | 取决于 trait object 的生命周期 |
| `Box<dyn Trait + 'static>` | ✅ | 显式标注 |

为什么这个区别重要?**因为线程边界要求 `T: 'static`**:

```rust,ignore
fn spawn_task<T: Send + 'static>(t: T) { /* ... */ }
```

`std::thread::spawn` 和 `tokio::spawn` 都要求传入的 closure 是 `'static`——因为线程可能比当前函数活得久,closure 内部不能引用任何短期的栈变量。

```rust
fn main() {
    let s = String::from("hello");
    std::thread::spawn(move || {
        println!("{}", s);  // ✅ s 被 move 进 closure,closure 是 'static
    });

    let s2 = String::from("world");
    let r = &s2;
    // std::thread::spawn(|| {
    //     println!("{}", r);  // ❌ closure 持有 &s2,不是 'static
    // });
}
```

### 误用警告

新手看到编译器要求 `'static`,经常的反应是"那我把所有东西都标 `'static` 不就行了"。

错。

`'static` 是限制,不是好东西。代码里 `'static` 越多,你的程序就越没法做"作用域共享"——所有跨边界的数据都得是 owned 或全局的。

正确做法:**默认不写 `'static`,只在必须的地方写**(主要是 thread/task spawn)。

### 这一节的关键 takeaway

`'static` 字面是"永远活着",工程上是"不持有任何短期借用"。它经常出现在线程边界,但不要滥用——能用更短的 lifetime 就别用 `'static`。

---

## 3.5 Rust 借用错误的 5 种典型模式

借用检查器报错看起来神秘,实际上 90% 的报错可以归为 5 类。看清模式后,debug 就快了。

### 模式 1:"cannot borrow X as mutable because it is also borrowed as immutable"

```rust,ignore
let mut v = vec![1, 2, 3];
let first = &v[0];     // 共享借用
v.push(4);             // ❌ 要 &mut v,冲突
println!("{}", first);
```

**根本原因**:你在持有共享借用时尝试可变操作。

**修复方向**:
- 重排顺序:在 `first` 最后一次使用之后再 push
- clone:`let first = v[0].clone()`(对 Copy 类型直接 `let first = v[0]`)
- 限制 first 作用域:`{ let first = &v[0]; println!("{}", first); }` 然后 push

### 模式 2:"X does not live long enough"

```rust,ignore
let r;
{
    let x = 5;
    r = &x;
}
println!("{}", r);
```

**根本原因**:你引用了一个比引用本身活得短的值。

**修复方向**:
- 把被引用的值移到外层作用域
- 改成 owned(把 `&x` 改成 `x.clone()`,如果 x 不是 Copy)
- 重新审视设计——可能你压根不需要长生命周期的引用

### 模式 3:"cannot move out of borrowed content"

```rust,ignore
fn take_first(v: &Vec<String>) -> String {
    v[0]                // ❌ v 是借用,不能从中 move 出来
}
```

**根本原因**:你借了别人的东西,但想拿走其中一部分。借的就是借的,不能拆。

**修复方向**:
- clone:`v[0].clone()`
- 返回引用而非 owned:`&v[0]`,签名改成 `fn take_first<'a>(v: &'a Vec<String>) -> &'a String`
- 改成接管所有权:`fn take_first(mut v: Vec<String>) -> String`

### 模式 4:"borrowed value does not live long enough"(返回引用类)

```rust,ignore
fn first_char_ref() -> &str {
    let s = String::from("hello");
    &s                  // ❌ s 即将被 drop
}
```

**根本原因**:你想返回一个指向函数内局部变量的引用。函数返回时局部变量 drop,引用会悬垂。

**修复方向**:
- 返回 owned:`fn first_word_owned() -> String` 然后 `s.chars().next().unwrap().to_string()`
- 接受输入并返回输入的子借用:`fn first_char(s: &str) -> &str`

### 模式 5:"closure may outlive borrowed value"

```rust,ignore
fn main() {
    let s = String::from("hello");
    let f = || println!("{}", s);  // closure 借用了 s
    drop(s);                       // ❌ 不能 drop,closure 还要用
    f();
}
```

更常见在 thread 场景:

```rust,ignore
fn main() {
    let s = String::from("hello");
    std::thread::spawn(|| {        // ❌ closure 借用 s,但 thread 可能比 main 活得久
        println!("{}", s);
    });
}
```

**修复方向**:
- 用 `move` 关键字:`std::thread::spawn(move || { ... })`,closure 接管所有权
- 用 `Arc<T>` 跨线程共享所有权

### 编译器报错的"读法"

Rust 的报错信息有固定格式:

```text
error[E0XXX]: <短描述>
  --> file.rs:line:col
   |
N  | <错误代码行>
   | <下划线指出问题位置>
N+1| <相关上下文>
   = help: <修复建议>
   = note: <补充说明>
```

读报错的顺序:
1. **先看 `help:` 那行**——通常直接告诉你怎么改
2. 看下划线位置,理解编译器认为问题在哪
3. 看 `note:`,补充信息
4. **最后**才看错误码 `E0XXX`(如果还需要,可以 `rustc --explain E0XXX` 查详细解释)

工程经验:**Rust 报错是设计资产,不是噪音**。花时间读懂它们,几周后你大部分错误一眼就能定位。

---

## 3.6 实战:实现一个不 clone 的字符串切分迭代器

把这章的概念串起来,我们做个练习:实现一个返回字符串切片的 word iterator。

### 需求

```rust,ignore
let s = String::from("hello world rust");
let mut iter = WordIter::new(&s);

assert_eq!(iter.next(), Some("hello"));
assert_eq!(iter.next(), Some("world"));
assert_eq!(iter.next(), Some("rust"));
assert_eq!(iter.next(), None);
```

要求:**不 clone,不 copy 字符串**。每个 `next()` 返回的是 `&str`,指向原 `s` 的某段。

### 实现

```rust
struct WordIter<'a> {
    remaining: &'a str,
}

impl<'a> WordIter<'a> {
    fn new(s: &'a str) -> Self {
        WordIter { remaining: s.trim_start() }
    }
}

impl<'a> Iterator for WordIter<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        if self.remaining.is_empty() {
            return None;
        }
        match self.remaining.find(char::is_whitespace) {
            Some(i) => {
                let word = &self.remaining[..i];
                self.remaining = self.remaining[i..].trim_start();
                Some(word)
            }
            None => {
                let word = self.remaining;
                self.remaining = "";
                Some(word)
            }
        }
    }
}

fn main() {
    let s = String::from("hello world rust");
    let mut iter = WordIter::new(&s);

    while let Some(word) = iter.next() {
        println!("{}", word);
    }
}
```

### 解读

这个例子用到本章每一个概念:

1. **struct 含引用字段**:`WordIter<'a>` 必须有 lifetime 参数,因为 `remaining: &'a str` 是借用
2. **`new(s: &'a str)` -> `Self`**:输入借用的 lifetime 跟 struct 的 lifetime 一致
3. **`Iterator::Item = &'a str`**:每次 next 返回的也是 `'a` 生命周期的引用
4. **`fn next(&mut self) -> Option<&'a str>`**:返回的引用跟 self 内部的 `remaining` 来自同一个 `'a`,即原始字符串

整个迭代器**没有任何 clone 或分配**,纯指针运算。这就是 Rust 零成本抽象的真容——一个看似复杂的迭代器,编译后跟手写的字符串扫描循环性能一致。

### 对比:如果用 owned

如果你不会 lifetime,可能会写成:

```rust
struct WordIterOwned {
    words: Vec<String>,
    index: usize,
}

impl WordIterOwned {
    fn new(s: &str) -> Self {
        let words = s.split_whitespace().map(|w| w.to_string()).collect();
        WordIterOwned { words, index: 0 }
    }
}

impl Iterator for WordIterOwned {
    type Item = String;
    fn next(&mut self) -> Option<String> {
        if self.index >= self.words.len() { return None; }
        let w = self.words[self.index].clone();
        self.index += 1;
        Some(w)
    }
}
```

能跑,但每个单词 clone 两次(构造时 to_string,next 时 clone)。100 个单词就是 200 次 heap 分配。借用版本是 0 次。

这就是为什么"会用 lifetime"是工程进阶——它让你能写出真正零成本的代码。

---

## 3.7 章末小结与习题

### 本章核心概念回顾

1. **借用 `&T` / `&mut T`**:让函数暂时使用值而不接管所有权
2. **借用规则(Aliasing XOR Mutability)**:任意时刻要么多个共享借用,要么一个独占借用
3. **NLL**:借用作用域在最后一次使用后立刻结束,不必等到 `}`
4. **Lifetime `'a`**:不是手动管理生命周期,是给编译器看的引用关系标注
5. **Lifetime elision**:大多数情况编译器自动推导,你不用写
6. **`'static` 的两个含义**:`&'static T` 是引用指向永久数据;`T: 'static` 是类型不持有非 'static 借用
7. **5 种典型借用错误**:认得出模式,debug 就快
8. **零成本迭代器**:用 lifetime 设计返回引用的 Iterator,无 clone 无分配

### 习题

#### 习题 3.1(简单)

下面代码有借用错误,用三种不同方式修复:

```rust,ignore
fn main() {
    let mut v = vec![1, 2, 3];
    let first = &v[0];
    v.push(4);
    println!("{}", first);
}
```

提示:三种方向是 (1) 重排顺序、(2) 改成 Copy、(3) 限制借用作用域

#### 习题 3.2(中等)

写一个函数,签名:

```rust,ignore
fn find_pair<'a>(v: &'a [i32], target: i32) -> Option<(&'a i32, &'a i32)>;
```

返回 v 中两个元素的引用,使它们的和等于 target。如果找不到,返回 None。要求不 clone、不 copy。

#### 习题 3.3(中等)

下面代码有问题,**只看签名能不能判断出问题**:

```rust,ignore
fn dangle<'a>() -> &'a str {
    let s = String::from("hello");
    &s
}
```

为什么编译器拒绝?如果我们硬要返回一个 `&str`,有什么合法的方法?

#### 习题 3.4(困难)

实现 `LineIter`,类似 3.6 节的 `WordIter`,但按换行符切分。要求:

```rust,ignore
let s = "line1\nline2\nline3";
let mut iter = LineIter::new(s);
assert_eq!(iter.next(), Some("line1"));
assert_eq!(iter.next(), Some("line2"));
assert_eq!(iter.next(), Some("line3"));
assert_eq!(iter.next(), None);
```

注意空行、末尾换行符等边界情况。

#### 习题 3.5(开放)

找一段你写的或读过的 Rust 代码,标出每个 `&` 引用的 lifetime 来源:它从哪里借来,什么时候失效?

如果某个引用让你看不懂,把它改写成 owned + clone 看看,问自己:这个 clone 是必要的吗?

---

### 下一章预告

Ch 4 我们离开"内存"这个维度,进入"类型设计"。Rust 的 `enum` 不是 C 那种 enum,是真正的 sum type。配合 pattern matching,你能写出比 Go 简洁得多的领域模型代码。

我们会用一个具体例子贯穿:**重新设计一个 Session 状态机**,从你熟悉的"struct + status 字段"风格,变成 Rust 风格的"enum 即状态机"。

---

> **本章一句话总结**
>
> 借用检查器不是路障,是结对程序员。它在你提交代码之前,把一类并发 bug、迭代失效、悬垂引用的问题都筛掉了。学会读它的报错,是学会 Rust 的关键转折。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
