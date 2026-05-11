# 第 4 章 · Struct、Enum、Pattern Matching —— 用类型表达领域

> "Make illegal states unrepresentable."
> — Yaron Minsky

Part I 我们处理了内存维度——所有权、借用、生命周期。Part II 我们换一个视角:**类型系统作为领域建模工具**。

读完这章你应该能:

1. 用 enum 替代 Go 的 `interface{}` + type switch 模式
2. 理解为什么 Rust 的 pattern matching 是穷尽性检查的——这等于编译器替你写测试
3. 设计 newtype 来避免"全是 String 和 u64"的类型贫血代码
4. 把一个状态机从"struct + status enum"风格,重构成"enum 即状态"风格

---

## 4.1 Struct 三种形式

Rust 的 struct 有三种形式,各有用途。

### 命名字段 struct(最常见)

```rust
struct User {
    name: String,
    email: String,
    active: bool,
}

let u = User {
    name: String::from("Marvin"),
    email: String::from("m@hp.com"),
    active: true,
};
```

跟 Go 的 struct、C# 的 record 用法相似。

### Tuple struct

```rust
struct Point(f64, f64);

let p = Point(1.0, 2.0);
println!("{} {}", p.0, p.1);
```

字段没有名字,通过 `.0` `.1` 访问。看起来鸡肋,但有一个关键用途——**newtype pattern**(下一节展开)。

### Unit struct

```rust
struct Marker;

let m = Marker;
```

完全没有字段,只有类型本身。用于 trait 标记、phantom type、空容器。看起来更鸡肋,但在 trait-heavy 代码里很有用。

### 字段更新语法

跟 TypeScript spread operator 类似:

```rust
let u1 = User {
    name: String::from("Marvin"),
    email: String::from("m@hp.com"),
    active: true,
};

let u2 = User {
    email: String::from("new@hp.com"),
    ..u1   // 其余字段从 u1 取
};

// 注意:u1 在这里被部分 move 了
// 因为 name 是 String(非 Copy),被 move 进 u2
// active 是 bool(Copy),u1.active 还能用
```

字段更新语法跟 ownership 交互的细节经常坑人。**如果一个非 Copy 字段被 move 走,整个原 struct 不能再当作整体使用**。

### 工程小贴士

- **公开字段 vs 私有字段**:Rust 的字段默认私有,需要 `pub` 才能外部访问。这跟 Go 的"首字母大写"、Java 的 `public` 是同一回事。
- **不要给所有字段都加 `pub`**:能私有就私有,通过方法暴露行为,这是封装。
- **构造方法用 `Self::new()` 或 builder**:不要让外部直接构造 struct,以便将来加校验逻辑。

---

## 4.2 Newtype Pattern:类型安全的代价是几个字符

Go/TS/Python 代码里,你经常看到这样的签名:

```go
func TransferMoney(from string, to string, amount int) error
```

`from` 和 `to` 都是 string——你能不能不小心传反?能。`amount` 是 int——你能不能传成时间戳?能。

类型系统帮不了你。

Rust 让你很便宜地修复这个问题:

```rust
struct UserId(u64);
struct AccountId(u64);
struct Cents(u64);

fn transfer_money(from: AccountId, to: AccountId, amount: Cents) -> Result<(), Error> { ... }
```

现在你**不能**把 `UserId` 传给要 `AccountId` 的位置。你**不能**把 `Cents` 当 `Seconds` 用。编译器在编译期拦下一类业务 bug。

代价:每个 newtype 多写 1 行。

### 为什么这值得

回想你过去的 bug:

- API 调用传错了参数顺序
- 单位混淆(秒 vs 毫秒,字节 vs 比特)
- 用户 ID 传成了 session ID

GC 语言里这类 bug 靠 code review、命名规范、文档。Rust 让类型系统帮你拦,**且基本零成本**——newtype 在运行时就是 inner type 本身,monomorphization 后的汇编一致。

### 实战:Stiglab 的 ID 设计

假设你的 Stiglab 有这些 ID:

```rust
pub struct SessionId(pub u64);
pub struct NodeId(pub u64);
pub struct TaskId(pub u64);
pub struct AgentId(pub u64);
```

签名层面:

```rust
fn dispatch_task(session: SessionId, task: TaskId, target: NodeId) { ... }
```

参数顺序写错,编译器立刻报错。比对照文档省心多了。

### 加点料:让 newtype 更好用

光是 `struct SessionId(u64)` 用起来啰嗦——构造、访问、Display 都麻烦。常见做法:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionId(pub u64);

impl SessionId {
    pub fn new(id: u64) -> Self {
        SessionId(id)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

impl std::fmt::Display for SessionId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "session-{}", self.0)
    }
}
```

`#[derive(...)]` 是 Rust 的"自动实现 trait"语法。Ch 6 详讲。

---

## 4.3 Enum:不是 C 的 enum,是 sum type

C 里的 enum 是 named constant 的集合:

```c
enum Color { RED, GREEN, BLUE };
```

Rust 的 enum 远超过这个。它是 **sum type**——可以是 A、可以是 B、可以是 C,**每个 variant 还可以携带不同类型的数据**。

```rust
enum Message {
    Quit,                         // 无数据
    Move { x: i32, y: i32 },      // 命名字段
    Write(String),                // tuple 字段
    ChangeColor(i32, i32, i32),   // tuple 字段
}
```

每个 variant 形态可以不同——这是 C/Java enum 完全做不到的。

### Enum 的 sizeof

`Message` 在内存里多大?

答案:**所有 variant 中最大的那个 + 1 字节(tag)**(实际有对齐)。Rust 的 enum 是 tagged union——一个 tag 表示当前是哪个 variant,后面是实际数据。

举例,如果 `Move { x: i32, y: i32 }` 是 8 字节,`String` 是 24 字节,`(i32, i32, i32)` 是 12 字节,那么 `Message` 大概是 24 + 几字节 tag + 对齐。

### Pattern Matching:enum 的另一半

光定义 enum 没用,关键在于消费它:

```rust
fn process(msg: Message) {
    match msg {
        Message::Quit => println!("quit"),
        Message::Move { x, y } => println!("move to {}, {}", x, y),
        Message::Write(s) => println!("write: {}", s),
        Message::ChangeColor(r, g, b) => println!("color: {} {} {}", r, g, b),
    }
}
```

`match` 必须**穷尽**所有 variant。如果你少写一个,编译器报错:

```
error[E0004]: non-exhaustive patterns: `ChangeColor(_, _, _)` not covered
```

这是 Rust 类型系统的核心承诺之一——**不可能漏处理 case**。Go 用 `interface{}` + type switch 时,你忘加一个 case,编译器不报错;Java 用 sealed class + switch,有些情况能检查,但语法笨。Rust 这事儿是默认行为。

### 工程价值:让非法状态不可表达

Yaron Minsky 那句名言:**make illegal states unrepresentable**。Rust enum 是这句话的工具。

考虑一个网络请求的状态:

```go
// Go 风格:struct + 一堆字段
type Request struct {
    Status string  // "pending", "loading", "success", "error"
    Data   []byte  // 只在 success 时有效
    Error  error   // 只在 error 时有效
}
```

非法状态:`Status = "success"` 但 `Data == nil`?`Status = "error"` 但 `Error == nil`?`Status = "pending"` 但 `Data != nil`?这些都"可以表示",运行时靠你小心维护不变量。

```rust
// Rust 风格:enum 强制每个状态只携带它需要的数据
enum Request {
    Pending,
    Loading,
    Success(Vec<u8>),
    Error(String),
}
```

非法状态在类型层面不存在。`Request::Success` 必须带数据,不能没有;`Request::Pending` 不能带数据。代码读起来也清楚——每个 variant 名字告诉你状态、它的数据告诉你这个状态需要什么。

### Option 和 Result 都是 enum

Rust 没有 null,没有 exception——它们都被 enum 替代:

```rust
enum Option<T> {
    Some(T),
    None,
}

enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

你已经在用它们了。重要的是认识到:**它们没有特殊性**。stdlib 里这俩 enum 跟你自己定义的 enum 完全等价。这是 Rust 一个重要的设计哲学——**核心 abstractions 不是语言关键字,而是用语言基本构造块自己定义出来的**。

---

## 4.4 Match 进阶:模式的全部形态

`match` 不只是"枚举各 variant"。模式语法很丰富,值得熟练。

### 字面量与范围

```rust
let x = 5;
match x {
    1 => println!("one"),
    2 | 3 | 5 | 7 => println!("prime"),
    1..=10 => println!("1 to 10"),
    _ => println!("other"),
}
```

### 解构 struct

```rust
struct Point { x: i32, y: i32 }

let p = Point { x: 0, y: 7 };
match p {
    Point { x: 0, y: 0 } => println!("origin"),
    Point { x: 0, y } => println!("on y-axis at {}", y),
    Point { x, y: 0 } => println!("on x-axis at {}", x),
    Point { x, y } => println!("at ({}, {})", x, y),
}
```

### 解构 enum 嵌套

```rust
enum Shape {
    Circle(Point, f64),
    Rectangle(Point, Point),
}

match shape {
    Shape::Circle(Point { x: 0, y: 0 }, r) => println!("circle at origin, r={}", r),
    Shape::Circle(_, r) => println!("circle, r={}", r),
    Shape::Rectangle(p1, p2) => println!("rect {:?} to {:?}", p1, p2),
}
```

### 守卫(guard)

```rust
let n = 5;
match n {
    x if x < 0 => println!("negative"),
    0 => println!("zero"),
    x if x % 2 == 0 => println!("positive even"),
    _ => println!("positive odd"),
}
```

### 绑定(@ pattern)

```rust
let x = 5;
match x {
    n @ 1..=5 => println!("got {} in range", n),
    n @ 6..=10 => println!("got {} in upper range", n),
    _ => println!("out of range"),
}
```

### `if let` / `while let`:轻量 match

如果你只关心一个 variant,full match 显得啰嗦:

```rust
// 啰嗦版本
match config {
    Some(c) => println!("{}", c),
    None => (),
}

// 轻量版本
if let Some(c) = config {
    println!("{}", c);
}
```

`while let` 同理:

```rust
let mut stack = vec![1, 2, 3];
while let Some(x) = stack.pop() {
    println!("{}", x);
}
```

### `let-else`:错误分支提前 return

Rust 1.65 引入,极好用:

```rust
fn process(input: Option<String>) {
    let Some(s) = input else {
        println!("no input");
        return;
    };
    // 这里 s 是 String
    println!("got: {}", s);
}
```

跟 Swift 的 `guard let`、Go 早期的"tons of `if x == nil`"相比,Rust 这个语法既明确又简洁。

---

## 4.5 实战:重设计 Stiglab Session 状态机

把 4.1-4.4 串起来,我们做一个具体的设计练习。

### 起点:Go 风格的状态机

Stiglab 的一个 Session 可能有这样的 Go 风格设计:

```go
type SessionStatus string

const (
    StatusCreated  SessionStatus = "created"
    StatusRunning  SessionStatus = "running"
    StatusFailed   SessionStatus = "failed"
    StatusFinished SessionStatus = "finished"
)

type Session struct {
    ID        SessionId
    Status    SessionStatus
    StartedAt *time.Time      // 只在 Running/Finished 时有
    Result    *Result         // 只在 Finished 时有
    Error     error           // 只在 Failed 时有
}
```

这套设计的问题:
- `StartedAt = nil` 但 `Status = Running` 是非法状态,但能表示
- `Result != nil` 但 `Status = Created` 是非法状态,但能表示
- 维护这些不变量靠程序员小心,且要在每个分支检查

### Rust 风格:enum 即状态

```rust
use std::time::Instant;

pub struct SessionId(pub u64);

pub enum SessionState {
    Created {
        config: SessionConfig,
    },
    Running {
        config: SessionConfig,
        started_at: Instant,
    },
    Finished {
        config: SessionConfig,
        started_at: Instant,
        finished_at: Instant,
        result: SessionResult,
    },
    Failed {
        config: SessionConfig,
        started_at: Option<Instant>,  // 可能在 Created 阶段就失败
        error: SessionError,
    },
}

pub struct Session {
    pub id: SessionId,
    pub state: SessionState,
}
```

每个 variant 携带且只携带它需要的字段。`Running` 必须有 `started_at`,`Finished` 必须有 result——非法状态在类型层面消失。

### 状态转换函数

状态转换写成 method:

```rust
impl Session {
    pub fn start(self) -> Result<Self, Self> {
        match self.state {
            SessionState::Created { config } => Ok(Session {
                id: self.id,
                state: SessionState::Running {
                    config,
                    started_at: Instant::now(),
                },
            }),
            other => Err(Session { id: self.id, state: other }),
            // 不在 Created 状态,无法 start,返回原样
        }
    }

    pub fn finish(self, result: SessionResult) -> Result<Self, Self> {
        match self.state {
            SessionState::Running { config, started_at } => Ok(Session {
                id: self.id,
                state: SessionState::Finished {
                    config,
                    started_at,
                    finished_at: Instant::now(),
                    result,
                },
            }),
            other => Err(Session { id: self.id, state: other }),
        }
    }

    pub fn fail(self, error: SessionError) -> Self {
        let started_at = match &self.state {
            SessionState::Running { started_at, .. } => Some(*started_at),
            _ => None,
        };
        let config = match self.state {
            SessionState::Created { config }
            | SessionState::Running { config, .. } => config,
            SessionState::Finished { config, .. }
            | SessionState::Failed { config, .. } => config,
        };
        Session {
            id: self.id,
            state: SessionState::Failed {
                config,
                started_at,
                error,
            },
        }
    }
}
```

注意 `fn start(self) -> Result<Self, Self>` 这个签名:

- 接收 `self`(by value,接管所有权)
- 返回 `Result<Self, Self>`——成功就是新状态的 Session,失败就是原 Session

这是 Rust 的"状态机 by ownership"风格——**旧状态被消费,新状态被产生**。你不可能"忘了更新 status",因为旧的 Session 被 move 走了。

### 进一步:用 typestate pattern 让状态错误编译期消失

更激进的设计:每个状态是不同的类型,转换函数只在特定类型上存在。

```rust
pub struct CreatedSession {
    pub id: SessionId,
    pub config: SessionConfig,
}

pub struct RunningSession {
    pub id: SessionId,
    pub config: SessionConfig,
    pub started_at: Instant,
}

pub struct FinishedSession {
    pub id: SessionId,
    pub config: SessionConfig,
    pub started_at: Instant,
    pub finished_at: Instant,
    pub result: SessionResult,
}

impl CreatedSession {
    pub fn start(self) -> RunningSession {
        RunningSession {
            id: self.id,
            config: self.config,
            started_at: Instant::now(),
        }
    }
}

impl RunningSession {
    pub fn finish(self, result: SessionResult) -> FinishedSession {
        FinishedSession {
            id: self.id,
            config: self.config,
            started_at: self.started_at,
            finished_at: Instant::now(),
            result,
        }
    }
}
```

现在你**根本不能**对一个 `FinishedSession` 调用 `start()`——那个方法不存在于这个类型上。整个状态机的合法转换在类型层面写死。

### 两种风格的权衡

| 维度 | enum 状态机 | Typestate(类型即状态) |
|---|---|---|
| 表达力 | 高 | 极高 |
| 容器友好(放进 `Vec<_>`) | ✅ 一个类型搞定 | ❌ 需要 enum 包装或 trait object |
| 状态转换错误处理 | 运行时 Result | 编译期(根本不存在) |
| 适用场景 | 多状态可流动 | 强约束工作流 |

工程经验:**业务状态机用 enum 风格**(灵活、好序列化、好放容器);**关键安全约束用 typestate**(编译期保证不可越权)。Stiglab 的 Session 用 enum 合适,因为你需要把它存到数据库、通过 API 暴露、放到 `Vec<Session>` 里。

---

## 4.6 章末小结与习题

### 本章核心概念回顾

1. **Struct 三种形态**:命名字段、tuple struct、unit struct,各有用途
2. **Newtype pattern**:用 `struct UserId(u64)` 这类便宜手法换类型安全,运行时零开销
3. **Enum 是 sum type**:每个 variant 可以携带不同形态的数据,跟 C 的 enum 是两个东西
4. **Pattern matching 穷尽性检查**:编译器替你写测试,不可能漏 case
5. **`if let` / `while let` / `let-else`**:轻量 match,代码更简洁
6. **状态机用 enum 表达**:让非法状态在类型层面消失;关键约束用 typestate 进一步固化

### 习题

#### 习题 4.1(简单)

把下面 Go 风格的 struct 重写成 Rust enum,让非法状态不可表达:

```go
type ApiResponse struct {
    Success bool
    Data    []byte  // 只在 Success=true 时有
    Error   string  // 只在 Success=false 时有
    Code    int     // 只在 Success=false 时有
}
```

#### 习题 4.2(中等)

实现一个 `Mailbox` enum,代表邮箱可能的状态:

- 空
- 有 N 封未读邮件(N > 0)
- 满了(超过容量,带容量数字)

写一个函数 `summary(mb: &Mailbox) -> String`,返回一句描述。要求 match 必须穷尽。

#### 习题 4.3(中等)

给一个二叉树定义:

```rust
enum Tree {
    Leaf,
    Node(i32, Box<Tree>, Box<Tree>),
}
```

(注意 `Box<Tree>` 是必要的——否则 Tree 大小无法确定,Ch 8 详讲。)

实现:
- `fn count_leaves(t: &Tree) -> usize`
- `fn max_depth(t: &Tree) -> usize`
- `fn contains(t: &Tree, target: i32) -> bool`

全部用 match,不用 if-else 链。

#### 习题 4.4(困难,工程)

回到 4.5 节的 Session 状态机。如果加一个新状态 `Paused`(只能从 `Running` 转入,可以恢复到 `Running`),你的 enum 怎么改?转换函数怎么改?

更进一步:如果用 typestate 风格,`Paused` 是不是成了第三个独立 type?多了哪些转换 method?

写下你的设计,跟同事 review 时讨论。

#### 习题 4.5(开放)

回顾你过去三个月写过的 Go/TS 代码。找一个 "struct + status enum" 风格的状态机。试着重新设计成 Rust enum 风格——每个 variant 只带它需要的数据。

问自己:重新设计之后,有多少处运行时 nil-check 可以删掉?

---

### 下一章预告

Ch 5 我们处理一个直接相关的话题:**错误处理**。

`Result<T, E>` 也是 enum,你已经见过了。但工程上的错误处理远不止"用 Result 包一下就完了"——`thiserror` vs `anyhow` 的分工、错误层次设计、`?` 操作符的解糖、何时 panic、错误的可观察性,这些一起决定你的 Rust 代码在生产环境的可维护性。

---

> **本章一句话总结**
>
> 类型系统不是"类型注解",是设计工具。enum + pattern matching 让你把领域规则编码进类型,编译器替你检查不变量。
