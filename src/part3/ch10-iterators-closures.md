# Ch 10 · Iterator 与闭包

> Rust 函数式编程的两大支柱

**核心问题**:为什么 Rust 的 iterator 是真正的零成本抽象?三种 Fn trait 到底有什么差别?

Go 没有 iterator(`range` 是语法糖),也没有真正的闭包(`func` 字面量是 closure 但所有权语义模糊)。C# 的 LINQ 漂亮但有装箱 / 委托调用开销。Rust 的 iterator 链是**编译器把链路展开成等价的 for 循环**——抽象层数任意多,运行时为零。

读完你应该能:

1. 看到 `iter.filter(...).map(...).collect()` 不再担心性能
2. 解释 `Fn` / `FnMut` / `FnOnce` 各自的捕获和调用语义
3. 知道什么时候必须 `move closure`
4. 写出比 Go 同等代码更短同时更快的数据处理逻辑
5. 看懂为什么 `Vec::iter()`、`Vec::into_iter()`、`Vec::iter_mut()` 是三个不同的方法

---

## 10.1 Iterator trait 的真实定义

```rust,ignore
pub trait Iterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
    // ... 70+ 个 default method
}
```

整个 Iterator 体系只有 **`next()` 一个必须实现的方法**。其他都是基于 `next` 的 default impl。

### 手写一个 Iterator

```rust
struct Counter { count: u32 }

impl Iterator for Counter {
    type Item = u32;
    fn next(&mut self) -> Option<u32> {
        if self.count < 5 {
            self.count += 1;
            Some(self.count)
        } else {
            None
        }
    }
}

fn main() {
    let sum: u32 = Counter { count: 0 }
        .map(|x| x * 2)
        .filter(|x| x % 3 != 0)
        .sum();
    println!("{}", sum);   // 2 + 4 + 8 + 10 = 24
}
```

写一遍 `next`,自动得到 `map` / `filter` / `sum` 等所有方法。

### 三种 iter 方法

```rust,ignore
let v = vec![1, 2, 3];

for x in v.iter()      { /* x: &i32     —— 借用,v 还在 */ }
for x in v.iter_mut()  { /* x: &mut i32 —— 可变借用 */ }
for x in v.into_iter() { /* x: i32      —— 拿走所有权,v 消失 */ }
```

**这是 Go / C# 不直接对应的设计**。Go `for _, x := range v` 永远是 copy + index,没法表达"我要 move 走"或"我要可变借用"。Rust 用类型区分三种意图。

### 懒求值的工程意义

```rust
let v: Vec<i32> = (1..1_000_000)
    .map(|x| x * 2)
    .filter(|&x| x % 3 == 0)
    .take(5)
    .collect();
```

不要被 `1..1_000_000` 吓到——iterator 是**懒的**,`take(5)` 一遇上 5 个就停。Go 等价代码要写一个带 break 的 for 循环;Rust 的链式调用既短又一样快。

---

## 10.2 Iterator adapter 全家桶

最常用的 ~20 个:

```rust
let nums = vec![1, 2, 3, 4, 5];

// 变换
let doubled: Vec<_> = nums.iter().map(|x| x * 2).collect();

// 过滤
let evens: Vec<_> = nums.iter().filter(|&&x| x % 2 == 0).collect();

// 折叠
let sum: i32 = nums.iter().sum();
let product: i32 = nums.iter().product();
let max = nums.iter().max();
let fold = nums.iter().fold(0, |acc, &x| acc + x * x);

// 配对
let with_index: Vec<(usize, i32)> = nums.iter().copied().enumerate().collect();
let zipped: Vec<(i32, char)> = nums.iter().copied().zip("abcde".chars()).collect();

// 切片
let chunks: Vec<Vec<i32>> = nums.chunks(2).map(|c| c.to_vec()).collect();
let windows: Vec<Vec<i32>> = nums.windows(2).map(|w| w.to_vec()).collect();

// 串接
let concat: Vec<i32> = vec![1,2].into_iter().chain(vec![3,4]).collect();
let flat: Vec<i32> = vec![vec![1,2], vec![3]].into_iter().flatten().collect();
let mapped_flat: Vec<i32> = vec![1,2,3].iter().flat_map(|&x| vec![x, x * 10]).collect();

// 短路
let any_neg = nums.iter().any(|&x| x < 0);     // bool
let all_pos = nums.iter().all(|&x| x > 0);     // bool
let first_big = nums.iter().find(|&&x| x > 3); // Option<&i32>

// 状态机
let running_sum: Vec<i32> = nums.iter()
    .scan(0, |acc, &x| { *acc += x; Some(*acc) })
    .collect();   // [1, 3, 6, 10, 15]
```

### `collect()` 的多形态

`collect()` 是泛型,目标容器靠 turbofish 或类型注解决定:

```rust,ignore
let v: Vec<i32> = iter.collect();
let s: HashSet<i32> = iter.collect();
let m: HashMap<String, i32> = iter.collect();   // 需要 iter 元素是 (K, V) tuple
let s: String = chars_iter.collect();
let r: Result<Vec<i32>, Error> = iter_of_results.collect();   // 神奇的 Result collect
```

最后一个最妙:`Iterator<Item = Result<T, E>>` 可以 collect 成 `Result<Vec<T>, E>`,遇到第一个 Err 就停止。

---

## 10.3 Iterator 是零成本抽象的证据

```rust
pub fn sum_squares(v: &[i32]) -> i32 {
    v.iter().map(|x| x * x).sum()
}
```

`cargo asm sum_squares --rust` 或 godbolt 看汇编:出来是 ~10 条循环指令,跟手写 for 循环**完全一样**。没有 `Box<dyn Fn>`,没有虚表查找,没有 `Vec` 临时分配。

### 为什么?

每个 adapter(`map`, `filter`)是一个泛型 struct,它的 `next()` 是 inline 的。链 N 层 adapter,编译器看到的是一个 N 层嵌套的结构体,inline 完了等价于一个 for 循环。

### Go / C# 类比

| 语言 | "filter + map + reduce" 链 |
|---|---|
| Go | 三个独立 for 循环,中间产生中间 slice |
| C# (LINQ) | 委托调用 + 装箱(IEnumerable<T> 是 reference type) |
| Rust | 一个 for 循环,无中间分配 |

这就是 Rust 写出现代风格代码同时不输 C 性能的底气。

---

## 10.4 Fn / FnMut / FnOnce:三种 closure trait

闭包不是一种类型,而是一组类型(每个闭包是匿名 struct)。这三个 trait 描述"能调用几次、能不能修改捕获、能不能消耗捕获"。

| trait | 调用签名 | 含义 |
|---|---|---|
| `Fn` | `&self` | 调用任意次,不修改捕获 |
| `FnMut` | `&mut self` | 调用任意次,会修改捕获 |
| `FnOnce` | `self` | 只能调一次(消耗捕获) |

**包含关系**:`Fn: FnMut: FnOnce`(实现 `Fn` 自动实现 `FnMut` 和 `FnOnce`)。

### 实例

```rust
fn main() {
    let s = String::from("hello");

    // Fn:只读引用
    let print = || println!("{}", s);
    print();
    print();   // 可以反复调

    // FnMut:可变引用
    let mut v = vec![1, 2, 3];
    let mut push = |x| v.push(x);
    push(4);
    push(5);

    // FnOnce:拿走所有权
    let take = move || { let _owned = s; };   // s 被 move 进闭包
    take();
    // take();   // ❌ 第二次调编译错,s 已经被消耗
}
```

### 编译器怎么决定

编译器看闭包对捕获变量的使用方式,**选择最弱(最宽松)的 trait**:

- 只读访问 → 实现 `Fn` + `FnMut` + `FnOnce`
- 修改 → 实现 `FnMut` + `FnOnce`
- move 走 → 实现 `FnOnce`

### 收 closure 的函数签名

```rust,ignore
fn run_once<F: FnOnce()>(f: F)          { f(); }
fn run_repeated<F: FnMut()>(mut f: F)   { f(); f(); }
fn run_concurrent<F: Fn() + Sync>(f: F) { /* 多线程调 */ }
```

**API 设计**:接受最宽松的 trait。如果只调一次,写 `FnOnce`,这样调用方可以传 move closure;如果要调多次,写 `FnMut`;只有需要多线程同时调时才写 `Fn + Sync`。

---

## 10.5 `move` closure 与所有权

```rust
let s = String::from("hello");
let f = move || println!("{}", s);
// s 已经 move 进闭包,这里不能再用 s
f();
```

`move` 关键字**强制闭包获取捕获变量的所有权**。常见场景:

1. **把闭包送到另一个线程**(必须 move,因为线程之间所有权要清晰)

   ```rust
   use std::thread;
   let v = vec![1, 2, 3];
   thread::spawn(move || println!("{:?}", v));   // 必须 move
   ```

2. **闭包逃出局部作用域**(返回 closure / 存到 struct)

   ```rust,ignore
   fn make_adder(x: i32) -> impl Fn(i32) -> i32 {
       move |y| x + y   // 必须 move,否则 x 出函数就 drop
   }
   ```

3. **async block 进 spawn**

   ```rust,ignore
   let data = expensive_computation();
   tokio::spawn(async move {
       process(data).await;   // 必须 move,async block 要拥有 data
   });
   ```

`move` 不改变闭包实现哪个 trait,只改变**捕获方式**(by ref → by value)。

---

## 10.6 实战:用 iterator 链替代命令式循环

### Go 风格

```go
var result []User
for _, u := range users {
    if u.Active && u.Age >= 18 {
        result = append(result, User{
            ID:   u.ID,
            Name: strings.ToUpper(u.Name),
        })
    }
}
```

### Rust 直译

```rust,ignore
let mut result: Vec<User> = Vec::new();
for u in &users {
    if u.active && u.age >= 18 {
        result.push(User { id: u.id, name: u.name.to_uppercase() });
    }
}
```

### Rust 地道写法

```rust,ignore
let result: Vec<User> = users.iter()
    .filter(|u| u.active && u.age >= 18)
    .map(|u| User { id: u.id, name: u.name.to_uppercase() })
    .collect();
```

短一半,意图更清晰,性能完全一样(可能因为 `collect` 能预分配反而更快)。

### 但不要强迫症地链式

复杂逻辑、需要中间变量、需要日志 —— for 循环可读性更好。`iterator chain` 的优势是**简单变换**,复杂逻辑 for 循环不丢人。

---

## 习题

1. 把你手头一段 Go 的 "filter + transform + reduce" 代码翻成 Rust iterator chain。对比可读性。
2. 实现 `struct Fib`,impl Iterator,产生 Fibonacci 数列。用 `take(10)` 取前 10 个。
3. 写一个函数 `fn group_by<I, K, F>(iter: I, f: F) -> HashMap<K, Vec<I::Item>>`,签名应该怎么写?
4. 用 `flat_map` 把 `Vec<Vec<i32>>` 摊平,跟 `into_iter().flatten()` 对比。
5. 写一个 closure adapter:`fn retry<F, T, E>(f: F) -> Result<T, E> where F: FnMut() -> Result<T, E>`,重试 3 次。讨论为什么用 `FnMut` 而不是 `Fn` 或 `FnOnce`。

---

> **本章一句话总结**
>
> Iterator 是 Rust 把函数式抽象做成零成本的关键设计。掌握它,你能写出比 Go 更简洁同时同样快的代码——这是 Rust 给"GC 语言出身工程师"最直接的奖励。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
