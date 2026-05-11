# 第 6 章 · Trait —— 比 interface 多了什么

> "Traits are the closest thing Rust has to inheritance, and they're nothing like inheritance."

Go 有 interface,C# 有 interface,TS 有 interface。三种 interface 各不一样,但都是"一组方法签名的集合"。Rust 的 trait 远超过这个——它有 associated types、有 blanket impl、有 marker trait、有 object safety 规则、有静态/动态分发的明确区分。

这章是 Part II 的核心,也是这本书技术密度最高的章节之一。读完你应该能:

1. 解释 Rust trait 跟 Go interface、C# interface、Haskell typeclass 的根本差异
2. 选择正确的 trait 设计:associated type vs generic parameter
3. 判断一个 trait 能不能做 trait object,以及对象安全规则的工程含义
4. 选择 `dyn Trait` vs `impl Trait` vs `T: Trait`
5. 给 Onsager 的 Artifact 模型设计一组合理的 trait

---

## 6.1 从 Go interface 到 Rust trait

### Go interface

```go
type Reader interface {
    Read(p []byte) (n int, err error)
}

type FileReader struct { ... }

func (f *FileReader) Read(p []byte) (n int, err error) { ... }

// FileReader 自动实现了 Reader,因为它有匹配的方法签名
// 这是 structural typing —— "看起来像鸭子"
```

Go interface 是 structural——任何带匹配方法的类型自动满足 interface,不需要显式声明。

### Rust trait

```rust
trait Reader {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, Error>;
}

struct FileReader { ... }

impl Reader for FileReader {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, Error> { ... }
}
```

Rust 是 nominal——必须**显式 `impl Trait for Type`** 才算实现。光是有匹配方法的类型不算实现 trait。

### 这个差异为什么重要?

Go structural typing 的好处:解耦灵活,你可以为已有类型隐式满足新 interface。

代价:**意图不清晰**。FileReader 实现 Reader 是巧合还是设计?Go 不区分。

Rust 的选择:**实现是设计决定,不是巧合**。`impl Reader for FileReader` 这一行明确表达"我就是要让 FileReader 当 Reader 用"。代价是写多一行,收益是意图明确。

更深一点:Rust 允许你**为已有类型实现你定义的 trait**,这是 Go interface 做不到的:

```rust
// 你定义的 trait
trait MyDescribe {
    fn describe(&self) -> String;
}

// 实现给 std 的 String
impl MyDescribe for String {
    fn describe(&self) -> String {
        format!("a string of length {}", self.len())
    }
}

// 现在 String 有 describe 方法了
let s = String::from("hello");
println!("{}", s.describe());
```

这就是著名的 **"orphan rule"** 的灵活面——你可以扩展任何类型(在你自己的 crate 里)。但有限制:你不能既给已有类型又实现已有 trait(那需要 newtype 包装)。

### 跟其他语言一句话对比

| 语言 | 接口风格 | 显式/隐式 | 给已有类型加方法 |
|---|---|---|---|
| Go | interface(structural) | 隐式 | ❌ |
| C# / Java | interface(nominal) | 显式 | ❌(需要 extension methods,有限) |
| TS | interface(structural) | 隐式 | ❌(类型层面可,运行时不可) |
| Haskell | typeclass | 显式 | ✅(trait 的精神祖先) |
| Rust | trait | 显式 | ✅ |

Rust trait 的近亲是 Haskell typeclass,不是 Java interface。这是理解 trait 的关键。

---

## 6.2 Trait 的几个核心特性

### Default methods

trait 可以提供方法的默认实现:

```rust
trait Greet {
    fn name(&self) -> &str;

    fn hello(&self) -> String {
        format!("Hello, {}!", self.name())
    }
}

struct User { name: String }

impl Greet for User {
    fn name(&self) -> &str { &self.name }
    // hello 不需要实现,用默认的
}
```

`User` 只实现 `name`,自动获得 `hello`。这跟 C# interface default method、Java default method 类似。

### Supertraits:trait 之间的依赖

```rust
trait Animal {
    fn name(&self) -> &str;
}

trait Pet: Animal {                    // Pet 必须先是 Animal
    fn owner_name(&self) -> &str;
}
```

任何实现 `Pet` 的类型必须先实现 `Animal`。这是组合,不是继承——Rust 没有继承,但 supertrait 表达"这个 trait 假设那个 trait 已经有了"。

### Associated types

这是 Rust 区别于 Go interface 的关键特性。

考虑 Iterator trait(Rust 标准库):

```rust
trait Iterator {
    type Item;                        // 关联类型
    fn next(&mut self) -> Option<Self::Item>;
}
```

`Item` 是个**类型成员**,跟方法是平级的。每个实现者指定自己的 `Item`:

```rust
struct Counter { count: u32 }

impl Iterator for Counter {
    type Item = u32;
    fn next(&mut self) -> Option<u32> {
        self.count += 1;
        if self.count < 6 { Some(self.count) } else { None }
    }
}
```

Counter 把 `Item` 设成 `u32`。

### Associated type vs Generic parameter:为什么不用泛型?

为什么不写成:

```rust
trait Iterator<T> {
    fn next(&mut self) -> Option<T>;
}
```

理论上等价,工程上有差异。

**关键差异**:一个类型可以**实现**`Iterator<T>` 多次(对不同 T),但只能**实现** `Iterator`(关联类型版本)一次。

```rust
// 如果 Iterator 是泛型版本
impl Iterator<u32> for Counter { ... }
impl Iterator<i32> for Counter { ... }      // 也合法
impl Iterator<String> for Counter { ... }   // 也合法

let c: Counter = ...;
let x = c.next();  // x 是什么类型?编译器不知道,需要你指定
```

调用方每次得 disambiguate。

**关联类型版本**:

```rust
impl Iterator for Counter {
    type Item = u32;  // 一次定下来
    ...
}

let c: Counter = ...;
let x = c.next();  // x 是 Option<u32>,编译器自动推导
```

调用方不需要指定。这是为什么 stdlib 用关联类型——大部分 trait 概念上"对一个类型只有一种意义"(一个 Counter 迭代出来就是 u32,没有歧义)。

**判断准则**:

| 场景 | 用关联类型 | 用泛型参数 |
|---|---|---|
| 类型实现 trait 时,关联的类型是唯一的 | ✅ | ❌ |
| 类型可能对多种"参数"实现 trait | ❌ | ✅ |
| 调用方需要选择"用哪个版本" | ❌ | ✅ |
| 调用方不应该关心"有哪些版本" | ✅ | ❌ |

例子:`Iterator::Item` 用关联类型(一个迭代器只产生一种类型);`From<T>` 用泛型参数(一个类型可以 From 多种来源)。

---

## 6.3 Blanket impl:Rust 的杀手锏

```rust
// stdlib 里的代码(简化)
impl<T: Display> ToString for T {
    fn to_string(&self) -> String { ... }
}
```

这是 **blanket impl**——为"所有满足某条件的类型"实现 trait。

含义:**任何实现了 `Display` 的类型,自动获得 `to_string()` 方法**。

实操你已经在用:

```rust
let n = 42;
let s = n.to_string();  // i32 实现了 Display,所以自动有 to_string()
```

i32 没有显式 `impl ToString`,它是通过 blanket impl 获得的。

### Blanket impl 的工程力量

举例,Onsager 你想让"所有实现 `Serialize` 的类型自动获得一个 `to_json()` 方法":

```rust
trait ToJson {
    fn to_json(&self) -> Result<String, serde_json::Error>;
}

impl<T: serde::Serialize> ToJson for T {
    fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }
}
```

现在所有 Serialize 类型自动有 `to_json()`。**一行代码扩展整个生态**。

这种力量 Go interface 完全做不到——Go 的方法实现必须在类型定义所在的 package。Rust 的 orphan rule 限制(你只能给"你的类型"实现"任何 trait",或给"任何类型"实现"你的 trait")在保留封装的同时打开了这种扩展空间。

---

## 6.4 静态分发 vs 动态分发:`impl Trait` / `T: Trait` / `dyn Trait`

到目前为止,trait 是用来"约束类型必须有某些方法"。现在我们看怎么**消费**这种约束——三种语法,语义不同。

### 写法 1:`T: Trait`(泛型 + trait bound)

```rust
fn print_hello<T: Greet>(g: &T) {
    println!("{}", g.hello());
}
```

或等价的 where 子句:

```rust
fn print_hello<T>(g: &T) where T: Greet {
    println!("{}", g.hello());
}
```

或简写(自 Rust 1.26):

```rust
fn print_hello(g: &impl Greet) {
    println!("{}", g.hello());
}
```

这是**静态分发**——编译器为每个具体的 T 生成独立的函数实例(monomorphization)。`print_hello(&user)` 和 `print_hello(&dog)` 是两个不同的函数版本。

成本:编译期代码膨胀(每个用法生成一份)。
收益:零运行时开销,内联优化都能进。

### 写法 2:`impl Trait` 作返回类型

```rust
fn make_greeter() -> impl Greet {
    User { name: "Marvin".into() }
}
```

意思是"我返回某个实现 Greet 的类型,具体是什么不告诉调用方"。编译器知道是 User,但调用方代码里把它当 `impl Greet` 用。

工程意义:**隐藏实现类型,暴露 trait 契约**。如果你将来改返回 Dog 而不是 User,调用方代码不用改(只要他们只用 Greet 的方法)。

限制:函数所有 return path 必须返回**同一个**具体类型。下面这段不行:

```rust
fn make_greeter(use_dog: bool) -> impl Greet {
    if use_dog {
        Dog { ... }  // ❌ 不同 return path 不能返回不同类型
    } else {
        User { ... }
    }
}
```

要解决这个,需要 dyn Trait。

### 写法 3:`dyn Trait`(trait object,动态分发)

```rust
fn print_hello(g: &dyn Greet) {
    println!("{}", g.hello());
}
```

`&dyn Greet` 是个 **fat pointer**——两个指针:一个指向数据,一个指向 vtable(虚函数表)。调用 `g.hello()` 时通过 vtable 查找。

```
&dyn Greet 的内存布局:
┌──────────────┬──────────────┐
│ data ptr     │ vtable ptr   │
└──────┬───────┴──────┬───────┘
       │              │
       ▼              ▼
   ┌──────┐      ┌──────────────────┐
   │ User │      │ vtable           │
   │ data │      │  - hello: fn ptr │
   └──────┘      │  - drop: fn ptr  │
                 └──────────────────┘
```

成本:每次 method 调用一次 vtable 查找(无法内联)。
收益:可以异构存储——`Vec<Box<dyn Greet>>` 可以同时装 User 和 Dog。

```rust
let greeters: Vec<Box<dyn Greet>> = vec![
    Box::new(User { ... }),
    Box::new(Dog { ... }),
];
for g in &greeters {
    println!("{}", g.hello());
}
```

`Vec<Box<dyn Greet>>` 跟 Java 的 `List<Greet>` 语义最接近——都是异构集合,都用虚函数表。

### 三种写法对比

| 写法 | 分发 | 成本 | 适用 |
|---|---|---|---|
| `T: Trait` 或 `impl Trait`(参数位置) | 静态 | 编译期膨胀 | 高性能、可内联 |
| `impl Trait`(返回位置) | 静态 | 同上 + 类型擦除 | 隐藏实现类型 |
| `dyn Trait` | 动态 | 一次 vtable 查找/调用 | 异构集合、动态多态 |

工程经验:**默认写 `impl Trait`,需要异构集合时用 `dyn Trait`**。

---

## 6.5 Object Safety:为什么有些 trait 不能 dyn

不是所有 trait 都能做 trait object。下面这段不能编译:

```rust
trait Cloneable {
    fn clone_me(&self) -> Self;  // 返回 Self
}

let x: Box<dyn Cloneable> = ...;  // ❌ trait Cloneable is not object-safe
```

原因:`fn clone_me(&self) -> Self`——返回类型是 `Self`。但 `dyn Cloneable` 已经擦除了具体类型,编译器不知道返回什么大小的对象。

Rust 的 **object safety rules**(对象安全规则)一句话:

> trait 可以做 trait object,当且仅当它的方法都不"使用 Self"在 vtable 不能处理的位置。

具体规则(简化):
1. 方法不能返回 `Self`(原因如上)
2. 方法不能有泛型参数(`fn foo<T>(&self, x: T)` 不行——vtable 装不下无穷多版本)
3. 方法的第一个参数必须是 receiver(`self` / `&self` / `&mut self` / `Box<Self>` 等)
4. 没有关联常量
5. ...

详细规则见 The Rust Reference,但直觉是:**vtable 必须能装下所有方法的具体地址,任何"依赖具体类型"的东西都不行**。

### 工程含义

设计 trait 时如果想保留 dyn 选项,避免:
- 返回 Self(改成 `Box<dyn Self>` 或具体类型)
- 泛型方法(改成 trait 自身的关联类型,或拆成两个 trait)

例子:

```rust
// ❌ 不能 dyn 的设计
trait Animal {
    fn duplicate(&self) -> Self;
    fn play_with<T: Toy>(&self, toy: T);
}

// ✅ 能 dyn 的设计
trait Animal {
    fn duplicate(&self) -> Box<dyn Animal>;
    fn play_with(&self, toy: &dyn Toy);
}
```

如果你设计的 trait 不需要 dyn(比如它就是给泛型 bound 用的),不用管 object safety,该用 Self 就用 Self。`Iterator` 就有 `fn collect<B: FromIterator<Self::Item>>`,这就不能 dyn(stdlib 提供 `&mut dyn Iterator<Item = T>` 的子集是 object-safe 的——这是经过精心设计的)。

---

## 6.6 Marker Traits:不带方法的 trait

有些 trait 没有方法,只用作"类型标记":

```rust
pub trait Send { }
pub trait Sync { }
pub trait Copy: Clone { }
pub trait Sized { }
```

这些 trait 不实现任何行为,但编译器靠它们做关键判断。

### `Send` / `Sync`:并发安全的根基

- `T: Send`:T 的所有权可以转移到另一个线程
- `T: Sync`:`&T` 可以被多个线程共享

大部分类型自动实现这两个(编译器自动推导)。手动 `unsafe impl Send for MyType` 是危险操作,Ch 11 详讲。

工程意义:**线程 spawn 函数有 `T: Send + 'static` 约束,违反就编译期拦下**。

### `Copy`:bitwise 复制后原值仍可用

Ch 2 讲过。`Copy` 是 marker trait,告诉编译器"这个类型 move 时按 copy 处理"。

### `Sized`:编译期已知大小

默认所有泛型参数都隐含 `T: Sized`。这是为什么写 `dyn Trait` 时通常要 `Box<dyn Trait>`——`dyn Trait` 是 unsized 的(`!Sized`),不能直接放在 stack。

如果你想接受 unsized 类型,显式 opt out:

```rust
fn print<T: ?Sized + Debug>(x: &T) {  // ?Sized 表示不要求 Sized
    println!("{:?}", x);
}
```

---

## 6.7 实战:为 Onsager Artifact 模型设计 trait

回到工程。Onsager 的 Forge 是 artifact 生命周期管理器,artifact 有多种类型(spec / code / test / doc),每种有不同的处理方式。

### 起点:大 enum

可能的初版设计:

```rust
pub enum Artifact {
    Spec(SpecArtifact),
    Code(CodeArtifact),
    Test(TestArtifact),
    Doc(DocArtifact),
}

impl Artifact {
    pub fn id(&self) -> ArtifactId {
        match self {
            Artifact::Spec(a) => a.id,
            Artifact::Code(a) => a.id,
            Artifact::Test(a) => a.id,
            Artifact::Doc(a) => a.id,
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        match self {
            Artifact::Spec(a) => a.validate(),
            Artifact::Code(a) => a.validate(),
            Artifact::Test(a) => a.validate(),
            Artifact::Doc(a) => a.validate(),
        }
    }
    // ... 每个方法都要 match 一次
}
```

每加一个方法,要写一次 match。每加一个 variant,要改所有方法。**这是 Rust 里"用 enum 替代 dynamic dispatch"的代价**。

### 重设计:trait

```rust
pub trait Artifact {
    fn id(&self) -> ArtifactId;
    fn kind(&self) -> ArtifactKind;
    fn validate(&self) -> Result<(), ValidationError>;
    fn dependencies(&self) -> &[ArtifactId];
}

pub struct SpecArtifact { ... }
impl Artifact for SpecArtifact {
    fn id(&self) -> ArtifactId { self.id }
    fn kind(&self) -> ArtifactKind { ArtifactKind::Spec }
    fn validate(&self) -> Result<(), ValidationError> { /* spec validation */ }
    fn dependencies(&self) -> &[ArtifactId] { &self.deps }
}

// CodeArtifact, TestArtifact, DocArtifact 类似
```

加新 artifact 类型:`impl Artifact for ProseArtifact`,不需要改任何已有代码。

### enum 还是 trait:工程权衡

| 场景 | 选 enum | 选 trait |
|---|---|---|
| variant 集合稳定,行为多变 | ✅ | |
| variant 集合多变,行为稳定 | | ✅ |
| 需要序列化(serde) | ✅(enum 直接 derive) | ❌(trait object 序列化复杂) |
| 需要异构集合 | ✅(`Vec<Artifact>`) | ✅(`Vec<Box<dyn Artifact>>`) |
| 需要外部扩展(用户自己加新 variant) | ❌ | ✅ |
| 性能极敏感(避免 vtable 查找) | ✅ | △(用静态分发可以,但失去异构能力) |

**Onsager 的 Artifact**:variant 集合可能扩展(将来加新 artifact 类型),但行为相对固定(每个 artifact 都要 id/validate/deps)。**trait 更合适**。

### 进一步:trait 组合

Forge 不只关心 Artifact 通用接口。还有些专门的 trait:

```rust
pub trait Validatable {
    fn validate(&self) -> Result<(), ValidationError>;
}

pub trait Renderable {
    fn render(&self) -> String;
}

pub trait Persistable {
    fn save(&self, path: &Path) -> std::io::Result<()>;
    fn load(path: &Path) -> std::io::Result<Self> where Self: Sized;
}

pub trait Artifact: Validatable + Persistable {
    fn id(&self) -> ArtifactId;
    fn kind(&self) -> ArtifactKind;
}
```

Artifact 是组合 trait——任何实现 Artifact 的类型都自动是 Validatable + Persistable。但反过来,只是 Renderable 的类型不自动是 Artifact。

这是 Rust 的 **trait 组合优于继承**——你可以拼装多个小 trait,让类型按需获得能力。比 Java 的"单继承 + 多 interface"灵活。

---

## 6.8 章末小结与习题

### 本章核心概念回顾

1. **Trait 是 nominal**:必须显式 `impl Trait for Type`,跟 Go structural typing 不同
2. **Default methods + supertraits**:trait 可以有默认实现,可以依赖其他 trait
3. **Associated types vs generic parameters**:类型层面"唯一"的关系用 associated type,"多对多"用 generic parameter
4. **Blanket impl**:为"所有满足条件的类型"实现 trait,Rust 杀手锏
5. **三种 trait 消费方式**:`T: Trait`(静态、最常用)、`impl Trait`(类型擦除)、`dyn Trait`(动态、异构集合)
6. **Object safety**:不是所有 trait 能 dyn,设计时考虑"是否需要保留 dyn 选项"
7. **Marker traits**:`Send` / `Sync` / `Copy` / `Sized` 没方法,但是编译器关键决策依据
8. **enum vs trait**:variant 稳定+行为多变用 enum,variant 扩展+行为稳定用 trait

### 习题

#### 习题 6.1(简单)

为下面 trait 写一个实现:

```rust
trait Describable {
    fn describe(&self) -> String;
}

struct Movie {
    title: String,
    year: u32,
}

// 给 Movie 实现 Describable,describe 返回 "Movie: {title} ({year})"
```

#### 习题 6.2(中等)

设计一个 `Storage` trait,可以保存和读取键值:

```rust
trait Storage {
    type Key;
    type Value;
    fn get(&self, key: &Self::Key) -> Option<&Self::Value>;
    fn set(&mut self, key: Self::Key, value: Self::Value);
}
```

为 `HashMap<String, String>` 和 `Vec<(u32, User)>` 各实现一次 Storage,注意 `Self::Key` 不同。

#### 习题 6.3(中等)

判断下面 trait 哪些是 object-safe(能 dyn),哪些不是,为什么:

```rust
trait A {
    fn foo(&self);
}

trait B {
    fn foo(&self) -> Self;
}

trait C {
    fn foo<T>(&self, x: T);
}

trait D {
    fn foo(&self, x: &dyn std::fmt::Debug);
}

trait E {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
}
```

#### 习题 6.4(困难,工程)

回到 Onsager。设计一组 trait 来表达 Forge 的 artifact 生命周期 hooks:

- 每个 artifact 有"创建"、"修改"、"删除"三个生命周期事件
- 不同类型的 artifact 对每个事件有不同处理(spec 触发 lint,code 触发 compile,doc 触发 render)
- Forge 应该可以注册多个 hooks,顺序触发

要求:
- 用 trait + 静态分发 vs 用 trait object,对比两种设计
- 哪种适合 Onsager 的实际场景?为什么?

#### 习题 6.5(开放)

回顾你写的 Go interface 或 C# interface。挑一个,试着用 Rust trait 重新设计:

- 哪些 method 该是 default method?
- 是否应该用 supertrait 拆分关注点?
- 该用 associated type 还是 generic parameter?
- 是否需要保留 object safety?

不需要敲代码。设计本身的练习更有价值。

---

### 下一章预告

Ch 7 处理 trait 的双胞胎:**泛型与生命周期的进阶**。

我们会讲 monomorphization 的实际成本、where 子句的复杂用法、variance(协变/逆变)、HRTB(higher-ranked trait bounds)、GAT(generic associated types)。这些是 Rust 类型系统最深的部分,读懂之后你能看懂 stdlib 里几乎任何 trait 设计。

---

> **本章一句话总结**
>
> Trait 不是 interface 的复刻。它是 Haskell typeclass 的近亲,带着 nominal typing、associated types、blanket impl、object safety 等一组特性,共同构成 Rust 抽象表达力的基础。
