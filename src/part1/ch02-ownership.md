# Ch 2 · Ownership 是工程纪律

> "The borrow checker is not your enemy. It is your colleague who reads every line of your code before you commit."

Ch 1 我们建立了一个判断:Rust 的核心差异是**多了"所有权"这个维度**。这一章我们正式打开这个维度。

读完这章,你应该能回答以下问题(不是背答案,是从工程动机出发推导出答案):

1. 为什么 Rust 要求你区分 stack 和 heap?Go 和 C# 是怎么把这件事藏起来的?
2. 为什么 `let s2 = s1` 在 `String` 类型上会让 `s1` 失效,在 `i32` 上不会?
3. 为什么 Rust 不需要 `defer`/`using`/`finally` 来释放资源?
4. 函数参数应该写 `T` 还是 `&T` 还是 `&mut T`?判断依据是什么?
5. 什么时候 `.clone()` 是对的,什么时候是"我没想清楚所有权"的代码味?

如果读完你还回答不上来,**回头再读一遍**。这章是后面所有内容的地基。

---

## 2.1 Stack 与 Heap:为什么 Rust 让你显式看见

### GC 语言把这件事藏在哪里

写 Go 代码的时候,你大概率不会问自己"这个变量在 stack 还是 heap"。

```go
// Go
func makeUser() *User {
    u := User{Name: "Marvin"}
    return &u  // 返回栈上变量的指针?Go 编译器会自动把它改成 heap allocation
}
```

Go 有一个叫 **escape analysis**(逃逸分析)的机制——编译器在你看不见的地方分析:这个变量的引用有没有"逃出"当前函数?如果逃出去了,自动放到 heap;否则放在 stack。

C# 的规则更简单粗暴:`class` 永远在 heap,`struct` 永远在 stack(除非作为 class 的字段被装箱)。但具体的内存布局对你不可见。

TS / JavaScript 更进一步:你完全不知道 V8 把你的对象放在哪里。引擎想优化就优化,你说了不算。

**这些语言为什么能藏起来?**

因为它们都有 GC。GC 接管了"内存什么时候释放"这个问题,所以"内存放在哪里"也变得无关紧要——反正不归你管。

### Rust 为什么不能藏

Rust 没有 GC。"什么时候释放"这件事必须有人决定。Rust 的选择是:**让你显式表达,编译器在编译期决定**。

为了让你能表达,Rust 需要你区分:

| 内存位置 | 特点 | Rust 中的体现 |
|---|---|---|
| **Stack** | 大小编译期已知,LIFO,函数返回自动清理 | `let x: i32 = 42`,`let arr: [u8; 16] = ...` |
| **Heap** | 大小运行时才知,显式分配/释放 | `Box<T>`,`Vec<T>`,`String` |

举例:

```rust
fn main() {
    // Stack: 大小编译期确定,8 字节
    let n: i64 = 42;

    // Stack: 大小编译期确定,16 字节(4 个 u32)
    let arr: [u32; 4] = [1, 2, 3, 4];

    // Heap: 大小运行时才知,String 在 stack 上有个 fat pointer (24 字节),
    // 实际字符数据在 heap 上
    let s: String = String::from("hello");

    // Heap: Vec 同理,stack 上是 fat pointer,数据在 heap 上
    let v: Vec<i32> = vec![1, 2, 3];
}
```

`String` 在内存里实际长这样:

```text
Stack 上的 String 结构体           Heap 上的真实字符数据
┌───────────────────┐            ┌──────────────────────┐
│ ptr: *mut u8 ─────┼──────────► │ 'h','e','l','l','o'  │
│ len: usize  = 5   │            └──────────────────────┘
│ cap: usize  = 5   │
└───────────────────┘
   (24 bytes on 64-bit)
```

这个布局有几个工程含义,值得记住:

1. **`String` 本身在 stack 上**,只占 24 字节(64 位机器)。它是个"瘦"的描述符。
2. **真正的字符数据在 heap 上**,长度运行时才知。
3. **`String` 离开作用域时,Rust 必须释放 heap 上那块内存**。这就是 ownership 解决的问题。

### 这一节的关键 takeaway

Go 用 escape analysis 自动决定 stack/heap;C# 用 class/struct 二分;Rust 让你**通过类型系统显式表达**——基本类型(`i32` / `bool` / `[T; N]`)在 stack 上,带堆分配的类型(`Box<T>` / `Vec<T>` / `String`)在 stack 上有描述符、heap 上有数据。

这个区分不是为了让你折腾,是为了下面要讲的 ownership 规则有意义。

---

## 2.2 Ownership 三条规则

Rust 的 ownership 有且只有三条规则,The Rust Book 原文:

> 1. Each value in Rust has an *owner*.
> 2. There can only be one owner at a time.
> 3. When the owner goes out of scope, the value will be dropped.

中文版:

1. **每个值都有一个"所有者"**。
2. **同一时刻只能有一个所有者**。
3. **所有者离开作用域时,值会被丢弃(drop)**。

这三条规则非常短,但它们一起解决了一组真实的工程问题。我们用反例展示。

### 这三条规则在拦截什么 bug?

#### Bug 1:Use-after-free

C 里典型的 use-after-free:

```c
char* get_greeting() {
    char buf[20];
    strcpy(buf, "hello");
    return buf;  // 返回栈上变量的指针,函数返回后这块内存被释放
}

int main() {
    char* p = get_greeting();
    printf("%s\n", p);  // 未定义行为,可能打印乱码,可能段错误,可能正确
}
```

GC 语言不会发生这个问题——GC 会保留被引用的内存。Rust 没有 GC,但通过 **规则 3**(owner 离开作用域 = drop),加上后面要讲的借用规则,在编译期就能拦下:

```rust,ignore
fn get_greeting() -> &str {  // 编译错误!
    let s = String::from("hello");
    &s  // s 即将被 drop,你怎么能返回它的引用?
}
```

编译器报:

```text
error[E0106]: missing lifetime specifier
  |
3 |   &s
  |   ^^ this returns a reference to data owned by the current function
```

#### Bug 2:Double-free

C++ 里的经典:

```cpp
class Buffer {
    char* data;
public:
    Buffer(int size) { data = new char[size]; }
    ~Buffer() { delete[] data; }
};

int main() {
    Buffer a(100);
    Buffer b = a;  // 默认 copy constructor 只复制了指针!
                   // a 和 b 都拥有同一块 heap 内存
}  // a 和 b 都析构,都 delete[] data,double-free,程序崩溃
```

Rust 通过**规则 2**(同一时刻只能有一个所有者)拦截:

```rust,ignore
fn main() {
    let s1 = String::from("hello");
    let s2 = s1;  // 所有权从 s1 转移到 s2
    println!("{}", s1);  // 编译错误!s1 已经不再拥有这个 String
}
```

编译器报:

```text
error[E0382]: borrow of moved value: `s1`
  |
3 |     let s2 = s1;
  |              -- value moved here
4 |     println!("{}", s1);
  |                    ^^ value borrowed here after move
```

#### Bug 3:资源泄漏

Java/C# 里的经典——文件、socket 之类的资源忘了关:

```csharp
public void ProcessFile(string path) {
    var file = File.OpenRead(path);
    // 忘了 Dispose,如果方法抛异常,文件不会被关
}
```

C# 用 `using` 解决,但要程序员主动写:

```csharp
public void ProcessFile(string path) {
    using var file = File.OpenRead(path);
    // 离开作用域自动 Dispose
}
```

Rust 通过**规则 3** + Drop trait,直接默认行为就是这样:

```rust
fn process_file(path: &str) -> std::io::Result<()> {
    let file = std::fs::File::open(path)?;
    // 用 file 做事
    Ok(())
    // file 离开作用域,自动调用 Drop,文件自动关闭
    // 不需要 using,不需要 defer,不需要 finally
}
```

### 三条规则的工程动机总结

| 规则 | 拦截的 bug | 类比 |
|---|---|---|
| #1 每个值有一个 owner | 野指针 | 每条狗有一个主人 |
| #2 同一时刻只能有一个 owner | double-free | 一条狗不能同时被两个主人完全拥有 |
| #3 owner 出作用域时 drop | 资源泄漏 | 主人离开时,狗也走了 |

这三条规则不是 Rust 设计者拍脑袋定的。**它们是为了不用 GC 也能保证内存安全所需要的最小约束**。少一条就有 bug。

---

## 2.3 Move 与 Copy:`let s2 = s1` 到底发生了什么

这是新手最迷惑的地方。同样一行代码 `let b = a`,在不同类型上行为不同:

```rust,ignore
// 案例 1:i32
let a: i32 = 42;
let b = a;
println!("{}", a);  // ✅ 正常打印 42

// 案例 2:String
let a: String = String::from("hello");
let b = a;
println!("{}", a);  // ❌ 编译错误:value borrowed here after move
```

为什么?

### Move 的本质

回顾 2.1 节的 String 内存布局:`String` 在 stack 上是 24 字节的描述符(ptr/len/cap),真实数据在 heap。

当你写 `let b = a`,Rust 默认做的是 **bitwise copy of stack content**——把 stack 上那 24 字节复制一份给 `b`。结果:

```text
执行 let b = a 之前:
   a: [ptr ─→ heap data, len=5, cap=5]

执行 let b = a 之后(如果允许同时使用):
   a: [ptr ─→ heap data, len=5, cap=5]
   b: [ptr ─→ same heap data, len=5, cap=5]
```

注意:**两个 stack 描述符都指向同一块 heap 内存**。如果允许 `a` 和 `b` 同时使用,`a` 离开作用域 drop 一次,`b` 离开作用域又 drop 一次——double-free。

Rust 的解决方案不是"深拷贝 heap 数据"(那是 `clone()` 做的事),而是**让 `a` 失效**。这就叫 **move**:

```text
执行 let b = a 之后(Rust 实际行为):
   a: [被标记为已 move,不能再使用]
   b: [ptr ─→ heap data, len=5, cap=5]
```

stack 上的 24 字节确实复制了一份,但编译器禁止你再用 `a`。这是个**编译期标记**,运行时没有任何额外开销——move 在汇编层面就是一次普通的内存复制,没有任何特殊处理。

### Copy 的本质

那为什么 `i32` 的 `let b = a` 之后 `a` 还能用?

因为 `i32` 实现了 `Copy` trait。`Copy` 是一个**marker trait**(空 trait,没有方法),它告诉编译器:"这个类型 bitwise copy 之后,原来的值依然有效,不需要 move 语义"。

判断标准:**类型的所有数据都在 stack 上,不持有任何 heap 资源或外部资源**。

| 类型 | 是 Copy 吗? | 为什么 |
|---|---|---|
| `i32` / `i64` / `u8` / `f64` / `bool` / `char` | ✅ | 完全在 stack,无外部资源 |
| `(i32, i32)` / `[u8; 16]` | ✅ | tuple/array 全是 Copy 类型,自身也是 Copy |
| `&T`(共享引用) | ✅ | 引用本身只是个指针,复制指针没问题 |
| `String` | ❌ | 持有 heap 内存,bitwise copy 会导致 double-free |
| `Vec<T>` | ❌ | 同上 |
| `Box<T>` | ❌ | 同上,持有独占的 heap 分配 |
| `&mut T`(可变引用) | ❌ | 可变引用必须独占,不能复制 |
| 你自己的 struct(默认) | ❌ | 默认不实现 Copy,需要显式 `#[derive(Copy, Clone)]` |

### 实操:让自定义 struct 变成 Copy

```rust,ignore
// 默认行为:不是 Copy
#[derive(Debug)]
struct Point {
    x: f64,
    y: f64,
}

fn main() {
    let p1 = Point { x: 1.0, y: 2.0 };
    let p2 = p1;  // move
    println!("{:?}", p1);  // ❌ 编译错误
}
```

```rust
// 显式标注 Copy
#[derive(Debug, Copy, Clone)]
struct Point {
    x: f64,
    y: f64,
}

fn main() {
    let p1 = Point { x: 1.0, y: 2.0 };
    let p2 = p1;  // copy
    println!("{:?}", p1);  // ✅ 正常工作
}
```

注意 `Copy` 必须和 `Clone` 一起 derive,因为 `Copy` 在 trait 层面要求 `Clone`(Copy 是 Clone 的一个特例:bitwise clone 即可)。

**工程建议**:不要无脑给所有 struct 加 `Copy`。如果你的 struct 将来可能加一个 `String` 字段(比如加个 `name`),那 `Copy` 就得拿掉,所有用过 move-after-use 模式的代码都得改。`Copy` 是对外承诺,加了就难撤回。

### Move 在函数调用边界的体现

Move 不只发生在 `let b = a`,函数调用也是 move 时刻:

```rust,ignore
fn take_string(s: String) {
    println!("{}", s);
}  // s 在这里被 drop

fn main() {
    let s = String::from("hello");
    take_string(s);  // s 被 move 进函数
    println!("{}", s);  // ❌ 编译错误:s 已经被 move
}
```

这就是为什么 Rust 的函数签名要小心写——`fn take_string(s: String)` 是"我要拿走这个 String",`fn take_string(s: &String)` 是"我借一下,看完还你"。后面 2.5 节详谈。

### 这一节的关键 takeaway

`let b = a` 的行为取决于 `a` 的类型:

- 如果是 `Copy` 类型(`i32`, `bool`, `&T`, 全 Copy 字段的 struct):复制,`a` 仍可用
- 如果是非 `Copy` 类型(`String`, `Vec`, `Box`):move,`a` 失效

判断依据:**有没有 heap/外部资源**。有就 move,没有就 copy。

---

## 2.4 Drop trait:RAII 是默认行为

C++ 老兵看到 RAII 不会陌生。GC 语言出身的工程师可能要重新校准——Rust 的 RAII 比 C++ 还彻底,因为它是**语言默认行为**而不是程序员的纪律。

### 什么是 Drop

每个非 Copy 类型在离开作用域时,都会自动调用 `Drop::drop()` 方法。stdlib 里所有持有外部资源的类型都实现了 Drop:

| 类型 | drop 时做什么 |
|---|---|
| `String` / `Vec<T>` / `Box<T>` | 释放 heap 内存 |
| `File` | 关闭文件句柄 |
| `TcpStream` / `UdpSocket` | 关闭 socket |
| `MutexGuard<'_, T>` | 释放锁 |
| `Rc<T>` / `Arc<T>` | 引用计数减 1,到 0 时 drop 内部值 |

### 跟其他语言对比

| 语言 | 资源清理机制 | 谁负责调用 |
|---|---|---|
| C | 手动 `free` / `close` | 程序员(经常忘) |
| C++ | RAII(析构函数) | 编译器(C++ 的发明) |
| Java | `finally` block 或 try-with-resources | 程序员(不写就漏) |
| Go | `defer` | 程序员(不写就漏) |
| C# | `using` / `IDisposable` | 程序员(不写就漏) |
| Python | `with` / `__exit__` | 程序员(不写就漏) |
| **Rust** | **Drop trait** | **编译器(默认行为)** |

注意 Rust 这一行:**默认行为**。你不需要写 `defer`,不需要写 `using`,不需要写 `with`。资源清理是免费的副产品。

### 实操对比

**Go 版本**:

```go
func processFile(path string) error {
    file, err := os.Open(path)
    if err != nil {
        return err
    }
    defer file.Close()  // 必须写,不写就漏

    // ... 处理文件 ...
    return nil
}
```

**Rust 版本**:

```rust
fn process_file(path: &str) -> std::io::Result<()> {
    let file = std::fs::File::open(path)?;
    // ... 处理文件 ...
    Ok(())
    // file 在这里离开作用域,Drop::drop 被自动调用,文件被关闭
}
```

Rust 版本短一行,但更重要的是**你不可能忘**。

### 自定义 Drop

你也可以给自己的类型实现 Drop。常见场景:打印调试信息、释放外部资源、解除注册。

```rust
struct Connection {
    id: u32,
}

impl Drop for Connection {
    fn drop(&mut self) {
        println!("Connection {} closed", self.id);
        // 真实代码里可能做:发送 disconnect 包、从连接池移除、记日志、etc.
    }
}

fn main() {
    let c1 = Connection { id: 1 };
    {
        let c2 = Connection { id: 2 };
        // c2 在这个内层作用域结束时 drop
    }
    println!("After inner scope");
    // c1 在 main 结束时 drop
}
```

输出:

```text
Connection 2 closed
After inner scope
Connection 1 closed
```

### Drop 的几个工程细节

#### 1. Drop 顺序是 LIFO(后进先出)

```rust,ignore
fn main() {
    let a = Connection { id: 1 };
    let b = Connection { id: 2 };
    let c = Connection { id: 3 };
}
// 输出:
// Connection 3 closed
// Connection 2 closed
// Connection 1 closed
```

这跟 C++ 析构、Go defer 的顺序一致。

#### 2. struct 的字段 drop 顺序是定义顺序

```rust,ignore
struct Outer {
    a: Connection,  // 字段 a 先 drop
    b: Connection,  // 字段 b 后 drop?不对,看下面
}
```

实际上 struct 字段是**按定义顺序**(top-down)drop 的,不是反向。这跟 LIFO 不一致,容易踩坑。如果两个字段有 drop 顺序依赖,要小心。

#### 3. 你不能手动调用 `drop()` 方法

```rust,ignore
let c = Connection { id: 1 };
c.drop();  // ❌ 编译错误:explicit use of destructor method
```

但你可以用 `std::mem::drop` 函数提前 drop:

```rust,ignore
let c = Connection { id: 1 };
drop(c);  // ✅ c 在这里被 drop
println!("After drop");
```

`drop` 函数的源码很简单——它就是空函数,把参数 move 进来,函数返回时参数离开作用域,触发 Drop:

```rust
pub fn drop<T>(_x: T) {}
```

#### 4. panic 时 Drop 仍然被调用(默认配置下)

Rust 默认是 "unwinding panic"——panic 时栈展开,所有局部变量的 Drop 被调用。这跟 C++ 的异常机制类似。

如果你配置 `panic = "abort"`(常见于嵌入式或追求最小二进制大小的场景),那 panic 直接终止程序,Drop 不被调用。

### 这一节的关键 takeaway

RAII 在 Rust 里不是模式,是语言默认。你不需要写 `defer`、`using`、`finally`。每次你看到资源类型(`File`、`MutexGuard`、`TcpStream`),你应该相信"它会被自动清理",并把注意力放在它的所有权应该流到哪里。

---

## 2.5 函数边界:by value、by ref、by mut ref

到目前为止我们讨论了一个值在一个函数内的所有权。函数调用是所有权流动的关键时刻——你的 API 设计很大程度上是在回答"谁拥有这个值"。

Rust 函数参数有三种主要形式:

```rust,ignore
fn take_ownership(s: String) { /* ... */ }       // by value: 接管所有权
fn borrow(s: &String) { /* ... */ }              // by ref: 共享借用
fn borrow_mut(s: &mut String) { /* ... */ }      // by mut ref: 独占借用
```

借用细节我们 Ch 3 详讲,这里先建立"什么时候用哪种"的工程直觉。

### 场景化对照表

| 场景 | 选哪种 | 例子 |
|---|---|---|
| 函数需要"消费"或转换这个值 | `T` (by value) | `fn build_thing(config: Config) -> Thing` |
| 函数只需要读 | `&T` | `fn print_user(u: &User)` |
| 函数需要修改 | `&mut T` | `fn add_item(list: &mut Vec<Item>, item: Item)` |
| 函数只需要看一段字符串 | `&str`(不是 `&String`) | `fn count_chars(s: &str) -> usize` |
| 函数只需要看一段切片 | `&[T]`(不是 `&Vec<T>`) | `fn sum(v: &[i32]) -> i32` |
| 函数需要存这个值到长期容器 | `T` 或 `Arc<T>` | `fn register(handler: Arc<Handler>)` |

最后两条很重要——下一节展开。

### 反模式:不要写 `&String` / `&Vec<T>`

新手经常写:

```rust
fn count_chars(s: &String) -> usize {
    s.chars().count()
}

fn sum(v: &Vec<i32>) -> i32 {
    v.iter().sum()
}
```

这是反模式。正确写法:

```rust
fn count_chars(s: &str) -> usize {
    s.chars().count()
}

fn sum(v: &[i32]) -> i32 {
    v.iter().sum()
}
```

为什么?因为 `&str` 比 `&String` 更通用——`String` 可以自动转 `&str`(deref coercion),但反过来不行。同理 `&[T]` 比 `&Vec<T>` 更通用。

举例,有了 `fn sum(v: &[i32])`,这些都能传:

```rust,ignore
let v: Vec<i32> = vec![1, 2, 3];
sum(&v);              // Vec 自动转 &[i32]

let arr: [i32; 3] = [1, 2, 3];
sum(&arr);            // 数组也能转

let slice: &[i32] = &[1, 2, 3];
sum(slice);           // 直接 slice

// 如果签名是 fn sum(v: &Vec<i32>),后两种都不能传
```

工程经验:**写函数签名时,选择能接受最广输入的类型**。`&str` > `&String`,`&[T]` > `&Vec<T>`,`impl AsRef<Path>` > `&PathBuf`。

### 实操对比:同一段逻辑的三种签名

任务:把一个用户列表中的某个用户的 email 改成大写。

**版本 A:by value(接管所有权)**

```rust
struct User {
    name: String,
    email: String,
}

fn uppercase_email(mut user: User) -> User {
    user.email = user.email.to_uppercase();
    user
}

fn main() {
    let u = User { name: "Marvin".into(), email: "m@hp.com".into() };
    let u = uppercase_email(u);
    println!("{}", u.email);  // M@HP.COM
}
```

**适用场景**:函数式风格、不可变更新、链式调用。代价:每次调用都 move,如果 caller 还要原值就得 clone。

**版本 B:by mut ref(原地修改)**

```rust
struct User {
    name: String,
    email: String,
}

fn uppercase_email(user: &mut User) {
    user.email = user.email.to_uppercase();
}

fn main() {
    let mut u = User { name: "Marvin".into(), email: "m@hp.com".into() };
    uppercase_email(&mut u);
    println!("{}", u.email);  // M@HP.COM
}
```

**适用场景**:命令式风格、原地修改、不需要返回新值。这是大多数 Rust 工程代码的选择。

**版本 C:by ref(只读 + 返回新值)**

```rust
struct User {
    name: String,
    email: String,
}

fn uppercase_email(user: &User) -> String {
    user.email.to_uppercase()
}

fn main() {
    let u = User { name: "Marvin".into(), email: "m@hp.com".into() };
    let upper = uppercase_email(&u);
    println!("{}", upper);  // M@HP.COM
    println!("{}", u.email);  // m@hp.com,原值未改
}
```

**适用场景**:只需要派生信息,不修改原值。

### 选择指南

```text
我需要这个值做什么?
│
├─ 我要接管它,以后不还(比如存进容器、转换成别的类型)
│  └─ 用 T (by value)
│
├─ 我要修改它,改完还给 caller
│  └─ 用 &mut T
│
└─ 我只是看一眼
   ├─ 是字符串? → &str
   ├─ 是数组? → &[T]
   ├─ 是 Path? → impl AsRef<Path>
   └─ 其他 → &T
```

### 这一节的关键 takeaway

函数签名是 Rust 工程师的主要设计工具。选 `T` / `&T` / `&mut T` 等于在回答"调用方在这次调用之后还需要这个值吗?需要修改吗?"。这个习惯一旦养成,你写出的 API 会有清晰的契约。

---

## 2.6 反例对比:同一段逻辑在 Go / C / Rust

讲了这么多概念,我们用一个具体场景三语言对照,体会"责任放在哪里"的差异。

**任务**:写一个函数,接受一个字符串列表,过滤出长度大于 3 的,返回一个新列表。

### Go 版本

```go
func filterLong(strs []string) []string {
    result := []string{}
    for _, s := range strs {
        if len(s) > 3 {
            result = append(result, s)
        }
    }
    return result
}

func main() {
    input := []string{"hi", "hello", "hey", "world"}
    output := filterLong(input)
    fmt.Println(output)
    fmt.Println(input)  // input 仍可用
}
```

**责任分布**:
- 内存:GC 全包
- 并发安全:程序员自觉
- 资源清理:GC

**容易出错的地方**:几乎不会出错,因为 GC 兜底。

### C 版本

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char** filter_long(const char** strs, int n, int* out_n) {
    char** result = malloc(sizeof(char*) * n);
    int count = 0;
    for (int i = 0; i < n; i++) {
        if (strlen(strs[i]) > 3) {
            // 这里要不要 strdup?调用方期望什么?
            result[count++] = strdup(strs[i]);
        }
    }
    *out_n = count;
    return result;
}

int main() {
    const char* input[] = {"hi", "hello", "hey", "world"};
    int out_n;
    char** output = filter_long(input, 4, &out_n);
    for (int i = 0; i < out_n; i++) {
        printf("%s\n", output[i]);
        free(output[i]);  // 必须 free 每个 strdup 的字符串
    }
    free(output);  // 还要 free 数组本身
    return 0;
}
```

**责任分布**:
- 内存:程序员
- 并发安全:程序员
- 资源清理:程序员

**容易出错的地方**(数一下):
1. `malloc` 没检查返回值
2. `strdup` 失败也没检查
3. 调用方忘了 free → 内存泄漏
4. 调用方 free 了一次又 free 了一次 → double-free,崩溃
5. 调用方在 free 之后又访问 → use-after-free
6. 函数文档里没说清楚 caller 是不是要 free,容易传错

实际工程里,C 项目大量精力在管这些。Linux kernel、SQLite、PostgreSQL 都有详细的内存管理约定文档。

### Rust 版本

```rust,ignore
fn filter_long(strs: Vec<String>) -> Vec<String> {
    strs.into_iter()
        .filter(|s| s.len() > 3)
        .collect()
}

fn main() {
    let input = vec![
        String::from("hi"),
        String::from("hello"),
        String::from("hey"),
        String::from("world"),
    ];
    let output = filter_long(input);
    println!("{:?}", output);
    // println!("{:?}", input);  // ❌ 编译错误:input 已被 move
}
```

**责任分布**:
- 内存:编译器
- 并发安全:编译器(下章详讲)
- 资源清理:编译器(via Drop)

**容易出错的地方**:几乎没有。如果你写错了——比如想要在调用 `filter_long` 之后还用 `input`——编译器会立刻告诉你,你有几个明确的修复选项:

```rust
// 选项 1:接受 borrow,只读不消费
fn filter_long(strs: &[String]) -> Vec<String> {
    strs.iter()
        .filter(|s| s.len() > 3)
        .cloned()  // 因为返回 Vec<String> 而不是 Vec<&String>,需要 clone
        .collect()
}

// 选项 2:返回引用,零拷贝
fn filter_long_ref<'a>(strs: &'a [String]) -> Vec<&'a String> {
    strs.iter()
        .filter(|s| s.len() > 3)
        .collect()
}
```

### 三语言对比表

| 维度 | C | Go | Rust |
|---|---|---|---|
| 代码长度 | 长 | 短 | 短 |
| 内存安全 | 程序员负责 | GC 负责 | 编译器负责 |
| 调用方需要看文档才知道是否要释放 | ✅ | ❌ | ❌(类型签名告诉你) |
| 改一处 API 改动会引发的 cascade | 大(文档、调用方、内存协议) | 小 | 中(类型签名变化,编译器列出所有需要改的地方) |
| 运行时开销 | 无 | GC | 无 |
| 重构信心 | 低 | 中 | 高 |

最后一行是隐性收益:**Rust 重构信心高**。你改了一个函数签名,编译器会列出所有影响的地方,你逐个改完代码就能编译,编译过了就大概率能跑。Go 改了 interface 不会立刻报错(只在调用点才报),C 更糟糕(可能完全不报)。

### 这一节的关键 takeaway

Rust 的代价(学习曲线陡)和收益(编译期保证、零运行时开销、重构信心)是一对耦合的事情。你接受了显式所有权这个负担,换来一组别的语言要么放弃要么靠纪律维持的保证。

---

## 2.7 `.clone()` 的工程判断

新手常用 `.clone()` 绕过借用检查。Ch 1 我们说这是 Week 2-3 的"危险时刻"。这一节给你一个具体的判断流程。

### `.clone()` 在做什么

`Clone::clone()` 是显式的、可能开销大的复制。对 `String` 来说,clone 会:

1. 在 heap 上分配新的内存
2. 把原 String 的字符数据复制过去
3. 返回一个新的 String,持有这块新内存

```rust
let s1 = String::from("hello");
let s2 = s1.clone();  // 分配新 heap 内存,复制 5 个字节
// 现在 s1 和 s2 各自拥有自己的 heap 内存
```

成本:一次 heap 分配 + 一次 memcpy。对小 String 来说是几十纳秒,对大 String 或 `Vec<HashMap<...>>` 这种深层结构,可能是毫秒级。

### 何时 clone 是对的

✅ **当你确实需要两份独立的数据**

```rust,ignore
fn save_to_two_places(data: String) {
    db1.save(data.clone());  // db1 拿一份
    db2.save(data);          // db2 拿原始
}
```

两个数据库各持一份,这是真实需要,clone 合理。

✅ **当 clone 成本可忽略**

```rust
let id: u64 = 42;
let id2 = id.clone();  // 无所谓,u64 是 Copy 类型,clone == copy
```

(对 Copy 类型,你也可以不写 clone,编译器自动 copy。但写了不影响,可读性而已。)

✅ **当你 clone 的是 `Arc<T>` / `Rc<T>` 这种引用计数类型**

```rust,ignore
let shared = Arc::new(big_data);
let s1 = shared.clone();  // 只是引用计数 +1,极其便宜
let s2 = shared.clone();
```

`Arc::clone` 不复制 heap 数据,只把原子引用计数 +1。这是 Rust 共享所有权的标准模式。

### 何时 clone 是逃避

❌ **借用检查器报错你直接 clone**

```rust,ignore
fn process(data: &Vec<String>) -> String {
    let copy = data.clone();  // 不需要!
    copy.iter().filter(|s| !s.is_empty()).next().cloned().unwrap_or_default()
    // 应该直接用 data:
    // data.iter().filter(|s| !s.is_empty()).next().cloned().unwrap_or_default()
}
```

❌ **函数返回引用太麻烦,改成 owned + clone**

```rust
// 如果你写成这样
fn first_word(s: &String) -> String {
    s.split_whitespace().next().unwrap_or("").to_string()
    // 这里 to_string() 是不必要的 clone
}

// 应该写成
fn first_word_better(s: &str) -> &str {
    s.split_whitespace().next().unwrap_or("")
}
```

❌ **存到 struct 字段时无脑 clone**

```rust,ignore
struct Service {
    config: Config,
}

impl Service {
    fn new(config: &Config) -> Self {
        Service { config: config.clone() }  // 真的需要复制?
        // 也许应该是 Service { config: Arc<Config> }
    }
}
```

### 决策流程图

```text
我想 clone 这个值,先停一下,问自己:

┌─────────────────────────────────────────────────────────┐
│ 1. 我真的需要两份独立的数据吗?                          │
│    (一份会被修改,另一份不能被影响)                    │
└─────────┬───────────────────────────────┬───────────────┘
          │ 是                            │ 否
          ▼                               ▼
       clone 合理                    继续问问题 ↓
                                              
┌─────────────────────────────────────────────────────────┐
│ 2. 我能不能用 borrow (&T) 替代?                         │
└─────────┬───────────────────────────────┬───────────────┘
          │ 可以                          │ 不行
          ▼                               ▼
       用 &T                         继续问问题 ↓
                                              
┌─────────────────────────────────────────────────────────┐
│ 3. 我是不是想"多个地方共享所有权"?                      │
└─────────┬───────────────────────────────┬───────────────┘
          │ 是                            │ 否
          ▼                               ▼
       用 Arc<T> / Rc<T>            继续问问题 ↓
                                              
┌─────────────────────────────────────────────────────────┐
│ 4. 这个 clone 是不是只是为了过编译?                     │
└─────────┬───────────────────────────────┬───────────────┘
          │ 是(警告!)                  │ 否
          ▼                               ▼
       回去重新设计所有权流动           clone 可以接受
```

### 经验法则

1. **小项目早期可以 clone 多一点**——Rust 的 clone 性能也比你想的快,过早优化是大坑。
2. **代码 review 时,看到 clone 多问一句"为什么"**——大部分情况下能消除。
3. **profile 时如果发现热点是 clone,认真重构所有权流动**——这是真问题,不是风格偏好。
4. **`Arc` 不是 `clone` 的替代品**——它是"我真的需要共享所有权"的明确表达。看到 `Arc<T>` 满天飞,要审视架构。

### 这一节的关键 takeaway

`.clone()` 不是错的,但每次写之前停 5 秒,走一遍上面的决策流程。这个习惯养成后,你会自然写出更地道的 Rust 代码,你的 mental model 会真正建立起来。

---

## 2.8 实战:四种方式实现 group-by-length

这一节我们用一个具体任务,展示同一个问题的四种不同所有权策略,让你看到工程权衡。

**任务**:把一个 `Vec<String>` 按字符串长度分组,返回 `HashMap<usize, Vec<???>>`。

`???` 处的类型选择,本身就是一次所有权设计。

### 方案 A:消费 owned,返回 owned

```rust
use std::collections::HashMap;

fn group_by_length_a(strs: Vec<String>) -> HashMap<usize, Vec<String>> {
    let mut result: HashMap<usize, Vec<String>> = HashMap::new();
    for s in strs {  // for 循环消费 strs
        let len = s.len();
        result.entry(len).or_insert_with(Vec::new).push(s);
    }
    result
}

fn main() {
    let input = vec![
        String::from("a"),
        String::from("bb"),
        String::from("cc"),
        String::from("ddd"),
    ];
    let groups = group_by_length_a(input);
    // input 在这里已经不能用了
    println!("{:?}", groups);
}
```

**特性**:
- 函数接管 `strs`,调用方失去所有权
- 返回的 `HashMap` 完全拥有所有 String
- **零 clone**——String 从输入容器移动到输出容器
- 适合"调用方不再需要 input"的场景

### 方案 B:借用 input,返回 borrow(零拷贝)

```rust
use std::collections::HashMap;

fn group_by_length_b<'a>(strs: &'a [String]) -> HashMap<usize, Vec<&'a String>> {
    let mut result: HashMap<usize, Vec<&'a String>> = HashMap::new();
    for s in strs {
        result.entry(s.len()).or_insert_with(Vec::new).push(s);
    }
    result
}

fn main() {
    let input = vec![
        String::from("a"),
        String::from("bb"),
        String::from("cc"),
    ];
    let groups = group_by_length_b(&input);
    println!("{:?}", groups);
    println!("{:?}", input);  // input 还能用
}
```

**特性**:
- 函数借用 `strs`,不消费
- 返回的 HashMap 持有 input 中 String 的引用
- **零拷贝**——既不消费也不复制
- 代价:返回值的生命周期受限于 input,不能跨函数边界长期持有

### 方案 C:借用 input,clone 出 owned

```rust
use std::collections::HashMap;

fn group_by_length_c(strs: &[String]) -> HashMap<usize, Vec<String>> {
    let mut result: HashMap<usize, Vec<String>> = HashMap::new();
    for s in strs {
        result.entry(s.len()).or_insert_with(Vec::new).push(s.clone());
    }
    result
}
```

**特性**:
- 函数借用 input,但返回值持有自己的副本
- 有 clone 开销,但返回值生命周期独立
- 调用方两边都拿得住
- 这是"懒得想"的折中方案,工程里最常见

### 方案 D:用 Arc 共享所有权

```rust
use std::collections::HashMap;
use std::sync::Arc;

fn group_by_length_d(strs: Vec<Arc<String>>) -> HashMap<usize, Vec<Arc<String>>> {
    let mut result: HashMap<usize, Vec<Arc<String>>> = HashMap::new();
    for s in strs {
        let len = s.len();
        result.entry(len).or_insert_with(Vec::new).push(s);
    }
    result
}

fn main() {
    let input: Vec<Arc<String>> = vec![
        Arc::new(String::from("a")),
        Arc::new(String::from("bb")),
        Arc::new(String::from("cc")),
    ];
    let groups = group_by_length_d(input.clone());  // clone 是 Arc clone,只是 +1 引用计数
    println!("{:?}", groups);
    println!("{:?}", input);  // 还能用,因为 Arc clone
}
```

**特性**:
- 用 Arc 表达"多处共享所有权"
- `input.clone()` 是 Arc clone,极便宜(原子加 1)
- 适合多线程或需要 input 在多个地方长期持有的场景
- 代价:每次访问要解引用一层,失去一些零成本性

### 四方案对比

| 方案 | 内存开销 | 输入是否还能用 | 输出生命周期 | 工程场景 |
|---|---|---|---|---|
| A: owned in/owned out | 零 clone(move) | ❌ | 独立 | 调用方不再需要 input |
| B: borrow in/borrow out | 零拷贝 | ✅ | 受限于 input | 临时分组,不跨边界 |
| C: borrow in/owned out | clone 开销 | ✅ | 独立 | 默认折中,优先选这个 |
| D: Arc shared | Arc clone(便宜) | ✅(共享) | 共享 | 多处长期持有 |

### 这告诉你什么

**同一个任务有 4 种合理实现**,每种都对应一组不同的工程假设。Rust 强迫你**显式**做这个选择,Go 和 C# 帮你藏起来了(Go 全是 reference,C# 全是 reference,你不需要选)。

这是 Rust 学习曲线陡的根本原因,也是它工程价值的来源。**多了一个维度的设计自由,代价是多了一个维度的设计负担**。

工程经验:**先写方案 C(borrow in / owned out)**。等 profile 出问题了再改成 A 或 D。方案 B 适合内部辅助函数,不太适合 API 边界。

---

## 2.9 章末小结与习题

### 本章核心概念回顾

1. **Stack vs Heap**:Rust 让你显式区分,因为没有 GC 帮你藏。`String`/`Vec`/`Box` 在 stack 有描述符,heap 有数据。
2. **Ownership 三规则**:每个值有 owner、同时只有一个 owner、owner 离开作用域时 drop。这三条是无 GC 内存安全的最小约束。
3. **Move vs Copy**:取决于类型有没有 heap/外部资源。`Copy` 是 marker trait,`String` 不实现是因为 bitwise copy 会 double-free。
4. **Drop 是默认 RAII**:不用 `defer` / `using`,资源清理是免费的副产品。
5. **函数签名的三种形式**:`T` / `&T` / `&mut T` 各自对应"接管 / 只读 / 可写"的契约。设计 API 时优先用更通用的类型(`&str` 而不是 `&String`)。
6. **`.clone()` 的判断流程**:每次 clone 之前问 4 个问题——真需要两份?能不能 borrow?是不是要共享(Arc)?是不是为了过编译?
7. **同一任务的多种所有权策略**:四方案对比,优先用 borrow-in/owned-out,profile 后再优化。

### 习题

#### 习题 2.1(简单)

下面这段代码会报错,请只改一行让它编译:

```rust,ignore
fn main() {
    let s1 = String::from("hello");
    let s2 = s1;
    println!("{} {}", s1, s2);
}
```

**思考**:你有两种修复方案,各自对应什么所有权策略?

#### 习题 2.2(中等)

实现一个函数 `concat_all`,签名如下,无 `.clone()`,无 `unsafe`:

```rust,ignore
fn concat_all(strs: ???) -> String {
    // 把所有 String 拼接成一个,返回新 String
}
```

`???` 由你决定,要求:
- 调用方在调用之后**不能**再使用 input(强制移交所有权)
- 函数内部不调用 `clone()`

#### 习题 2.3(中等)

实现一个函数 `longest_string`,接受一个 String 列表,返回最长的那个。要求:
- 调用方在调用之后**仍然能**使用 input
- 函数返回的不是 owned String 而是借用
- 函数签名你自己决定

提示:这个函数的签名会用到 lifetime annotation。Ch 3 详讲,这里你可以先靠编译器报错猜签名。

#### 习题 2.4(困难,工程)

设想以下场景:

> 一个 Session 持有大量配置(`SessionConfig`)。这个配置被多个组件读取:scheduler 用来决定调度、reporter 用来输出日志、metrics collector 用来打 tag。

请用本章知识设计三种方案,并写出权衡:

- 方案 A:每个组件持有 `SessionConfig` 的 owned copy
- 方案 B:每个组件持有 `&SessionConfig`
- 方案 C:每个组件持有 `Arc<SessionConfig>`

在什么场景下你会选哪个?**写下你的判断**,在你后面真的接触这块代码时回头看自己的判断准不准。

#### 习题 2.5(开放)

回顾你最近三个月写的某段 Go 或 TS 代码。试着把它"翻译"成 Rust——只翻译数据流和所有权,不要纠结语法。问自己:

- 这段代码在 Go 里靠 GC 隐藏了什么?
- 用 Rust 写需要做哪些显式选择?
- 这些选择是负担还是清晰?

这个练习不需要敲代码,只需要思考。**思考本身比代码更重要**。

---

### 下一章预告

Ch 3 我们进入 borrowing 与 lifetime。你会看到 ownership 三规则的扩展形式:

- 共享借用 `&T` vs 独占借用 `&mut T` 为什么互斥?
- Lifetime `'a` 标注到底在标注什么?
- 编译器是怎么检查"引用不能比被引用的对象活得久"这件事的?
- `'static` 是什么,什么时候真的需要它?

读完那一章,你就能看懂 Rust 编译器最常见的报错——而看懂报错是 Rust 流畅期的开始。

---

> **本章一句话总结**
>
> Ownership 不是 Rust 强加给你的负担,是 Rust 把"内存安全的承诺"从程序员的脑子里搬到了编译器的检查里。学会用编译器思考,而不是跟它对抗。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
