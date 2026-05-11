# 第 10 章 · 闭包与 Iterator

> "Iterator is Rust's most successful abstraction. It's also the deepest."

C# 的 LINQ 让人爱不释手,Java 的 Stream 也不错,Go 没有 map/filter 让人崩溃。Rust 的 Iterator 是这条路的极致——表达力跟 LINQ 持平,性能跟手写 for 循环一致。

读完这章你应该能:

1. 区分闭包的三种 trait(Fn / FnMut / FnOnce),知道什么时候自动派生哪种
2. 流畅使用 iterator adapter chain,知道每个 adapter 的语义
3. 实现自定义 Iterator,让你的类型免费获得整套 adapter
4. 理解 Rust 的零成本抽象在 iterator 上是怎么做到的

---

## 10.1 闭包与三种 Fn trait

Rust 的闭包是匿名函数 + 捕获环境变量:

```rust
let x = 5;
let add_x = |n| n + x;          // 捕获 x
let result = add_x(10);          // 15
```

但闭包跟普通函数有个差异:**怎么捕获 x**?三种方式:

| 捕获方式 | 实现的 trait | 含义 |
|---|---|---|
| 借用 `&x` | `Fn` | 闭包只读环境,可以多次调用 |
| 可变借用 `&mut x` | `FnMut` | 闭包可修改环境,可以多次调用 |
| Move `x` | `FnOnce` | 闭包消费环境(只能调用一次,或多次但消费的只是 captured 值的副本) |

编译器**自动**推断使用哪种——根据闭包内部对 x 的使用方式。

```rust
let s = String::from("hello");

// 只是打印,只需借用
let print_s = || println!("{}", s);          // Fn

// 修改 captured 变量,需要可变借用
let mut count = 0;
let mut inc = || count += 1;                 // FnMut

// move 进闭包(用 move 关键字强制)
let take_s = move || println!("{}", s);      // 仍然是 Fn(只读),但 s 被 move 进来了
```

`move` 关键字强制闭包接管捕获变量的所有权。常用于跨 thread/task 边界。

### 三种 trait 的层级

```
FnOnce  (调用消费 self)
   ▲
   │
  FnMut  (调用需要 &mut self)
   ▲
   │
   Fn    (调用只需要 &self)
```

`Fn: FnMut: FnOnce`——`Fn` 比 `FnMut` 严格,`FnMut` 比 `FnOnce` 严格。**Fn 闭包可以被当作 FnMut 或 FnOnce 用,反之不行**。

### 在函数签名里接受闭包

```rust
fn call_fn<F: Fn()>(f: F) { f(); }
fn call_fn_mut<F: FnMut()>(mut f: F) { f(); }
fn call_fn_once<F: FnOnce()>(f: F) { f(); }
```

工程经验:**接受闭包参数时,选择能接受最广的 trait**。

- 不需要修改环境也不消费 → `Fn`
- 需要修改环境但不消费 → `FnMut`
- 消费环境(只调用一次) → `FnOnce`

如果你写 `F: Fn`,FnMut 闭包就传不进来。从严到宽的选择会限制 caller。但太宽也不好——`FnOnce` 不能在你函数里多次调用。

### `impl Fn` vs `dyn Fn`

```rust
// 静态分发,内联好,但函数签名暴露闭包内部
fn make_adder(x: i32) -> impl Fn(i32) -> i32 {
    move |n| n + x
}

// 动态分发,允许返回不同的闭包类型
fn make_op(op: &str) -> Box<dyn Fn(i32, i32) -> i32> {
    match op {
        "+" => Box::new(|a, b| a + b),
        "-" => Box::new(|a, b| a - b),
        _ => Box::new(|a, b| 0),
    }
}
```

工程经验:默认 `impl Fn`(性能好),需要异构闭包时才用 `Box<dyn Fn>`。

---

## 10.2 Iterator trait:一个 next 方法,全套 adapter

Rust 的 Iterator 是个 trait:

```rust
pub trait Iterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
    // ... 80+ 个 default method(map / filter / fold / ...)
}
```

你只需实现 `next`,就免费获得 80+ 个 adapter。

### 一个简单的自定义 Iterator

```rust
struct Counter { current: u32, max: u32 }

impl Counter {
    fn new(max: u32) -> Self { Counter { current: 0, max } }
}

impl Iterator for Counter {
    type Item = u32;
    fn next(&mut self) -> Option<u32> {
        if self.current < self.max {
            self.current += 1;
            Some(self.current)
        } else {
            None
        }
    }
}

fn main() {
    let c = Counter::new(5);
    let sum: u32 = c.map(|x| x * 2).filter(|&x| x > 3).sum();
    println!("{}", sum);  // 2+4+6+8+10 中 >3 的:4+6+8+10 = 28
}
```

`map`、`filter`、`sum` 都来自 Iterator trait 的默认实现。你只写了 next。

---

## 10.3 Iterator Adapter 全家桶

按用途分类:

### 转换(transform)

| Adapter | 作用 | 例子 |
|---|---|---|
| `map(f)` | 每个元素应用 f | `[1,2,3].iter().map(|x| x*2)` → `[2,4,6]` |
| `filter(p)` | 保留 p 为 true 的 | `[1,2,3,4].iter().filter(|&&x| x % 2 == 0)` → `[2,4]` |
| `filter_map(f)` | 同时 filter + map,f 返回 Option | `["1","a","2"].iter().filter_map(|s| s.parse::<i32>().ok())` → `[1,2]` |
| `flat_map(f)` | f 返回 iterator,扁平化 | `[1,2].iter().flat_map(|&x| vec![x, x*10])` → `[1,10,2,20]` |
| `take(n)` | 取前 n 个 | `(1..).take(5)` → `[1,2,3,4,5]` |
| `skip(n)` | 跳过前 n 个 | `(1..10).skip(3)` → `[4,5,6,7,8,9]` |
| `take_while(p)` | 取直到 p 为 false | `[1,2,3,10,4].iter().take_while(|&&x| x<5)` → `[1,2,3]` |
| `skip_while(p)` | 跳过直到 p 为 false | `[1,2,10,3].iter().skip_while(|&&x| x<5)` → `[10,3]` |
| `chain(other)` | 串联两个 iter | `[1,2].iter().chain([3,4].iter())` → `[1,2,3,4]` |
| `zip(other)` | 配对 | `[1,2,3].iter().zip(["a","b","c"].iter())` → `[(1,"a"),(2,"b"),(3,"c")]` |
| `enumerate()` | 加索引 | `["a","b"].iter().enumerate()` → `[(0,"a"),(1,"b")]` |
| `rev()` | 反转(双端 iter) | `[1,2,3].iter().rev()` → `[3,2,1]` |
| `cycle()` | 无限循环 | `[1,2].iter().cycle().take(5)` → `[1,2,1,2,1]` |

### 消费(consumer)

| Adapter | 作用 | 例子 |
|---|---|---|
| `collect::<C>()` | 收集到容器 C | `iter.collect::<Vec<_>>()` |
| `sum()` / `product()` | 求和/求积 | `(1..=4).sum()` → 10 |
| `count()` | 计数 | `iter.count()` |
| `min()` / `max()` | 最小/最大 | `[3,1,2].iter().max()` → `Some(&3)` |
| `find(p)` | 找第一个满足 p 的 | `[1,2,3].iter().find(|&&x| x>1)` → `Some(&2)` |
| `position(p)` | 找第一个满足 p 的 index | `[1,2,3].iter().position(|&x| x==2)` → `Some(1)` |
| `any(p)` / `all(p)` | 存在/全部满足 | `[1,2,3].iter().any(|&x| x>2)` → `true` |
| `fold(init, f)` | reduce | `[1,2,3].iter().fold(0, |acc, &x| acc+x)` → 6 |
| `reduce(f)` | fold 但用第一个元素做 init | `[1,2,3].into_iter().reduce(|a,b| a+b)` → `Some(6)` |
| `for_each(f)` | 副作用 | `iter.for_each(|x| println!("{}",x))` |

### 边遍历边观察

| Adapter | 作用 | 例子 |
|---|---|---|
| `inspect(f)` | 不改变流,顺便执行 f(debug 神器) | `iter.inspect(|x| println!("{:?}",x)).collect()` |
| `peekable()` | 加 peek() 方法(不消费看下一个) | `iter.peekable()` |

### 错误处理

`collect::<Result<Vec<_>, _>>()` 是经典的"短路收集"——Ch 7 讲过。还有:

```rust
let result: Result<Vec<i32>, _> = strs.iter().map(|s| s.parse()).collect();
// 全部 Ok 时是 Ok(Vec),任意一个 Err 时短路返回 Err
```

---

## 10.4 Iterator 的零成本秘密

为什么 iterator chain 跟手写 for 循环一样快?

### Lazy evaluation

`map` / `filter` / `take` 这些 adapter 都不立即执行——它们返回一个新 Iterator,只有终结操作(collect/sum/for_each 等)才驱动执行。

```rust
let it = vec![1, 2, 3].iter().map(|x| {
    println!("mapping {}", x);
    x * 2
});
// 这里什么都没打印 —— map 是 lazy 的

let v: Vec<_> = it.collect();
// 现在才打印:mapping 1, mapping 2, mapping 3
```

### 单态化 + inline = 编译后等同手写循环

```rust
let sum: i32 = (1..=1000).map(|x| x * 2).filter(|&x| x % 3 == 0).sum();
```

编译器做的事:
1. Monomorphize 每个 adapter 到具体类型
2. 内联所有 adapter 的 next 方法
3. 整个 chain 被融合成一个循环

最终汇编大致等同于:

```rust
let mut sum = 0;
for i in 1..=1000 {
    let x = i * 2;
    if x % 3 == 0 {
        sum += x;
    }
}
```

这是 Rust 零成本抽象的活样本——表达力跟 LINQ 一样,性能跟手写循环一样。

### 但是,有些场景 iterator 还是慢一点

- 复杂控制流(break / continue 多重嵌套)用 for 更清晰
- 需要双重索引(同时访问 i 和 i+1)用 windows / chunks 或手写
- 调试 closure 比调试 for 麻烦

工程经验:**默认 iterator chain,可读性差或必要时改 for**。性能不是大多数场景的决定因素。

---

## 10.5 实战:把一段 Crawlab 处理逻辑改成 iterator

设想 Crawlab 有一段任务处理代码,Go 风格:

```go
func process(tasks []Task) []Result {
    results := []Result{}
    for _, t := range tasks {
        if t.Status != "pending" {
            continue
        }
        if t.Priority < 5 {
            continue
        }
        r, err := run(t)
        if err != nil {
            continue  // 默默跳过失败
        }
        results = append(results, r)
        if len(results) >= 100 {
            break
        }
    }
    return results
}
```

翻译成 Rust iterator chain:

```rust
fn process(tasks: Vec<Task>) -> Vec<Result> {
    tasks.into_iter()
        .filter(|t| t.status == "pending")
        .filter(|t| t.priority >= 5)
        .filter_map(|t| run(t).ok())          // 失败的过滤掉
        .take(100)
        .collect()
}
```

10 行 → 6 行,意图更清晰:filter 条件、错误处理、限量,各占一行。

### 进一步:可观察性

如果你需要看每一步发生了什么:

```rust
fn process(tasks: Vec<Task>) -> Vec<Result> {
    tasks.into_iter()
        .inspect(|t| tracing::trace!(task_id = %t.id, "considering"))
        .filter(|t| t.status == "pending")
        .filter(|t| t.priority >= 5)
        .inspect(|t| tracing::debug!(task_id = %t.id, "running"))
        .filter_map(|t| {
            match run(t) {
                Ok(r) => Some(r),
                Err(e) => {
                    tracing::warn!(error = ?e, "task failed");
                    None
                }
            }
        })
        .take(100)
        .collect()
}
```

`inspect` 不改变流,只是 side effect。配合 tracing 是 Rust 工程代码的标准模式。

---

## 10.6 章末小结与习题

### 本章核心概念回顾

1. **闭包三种 trait**:`Fn`(只读)/ `FnMut`(可变)/ `FnOnce`(消费),编译器自动推断
2. **`move ||`**:强制接管捕获变量所有权,跨 thread/task 必备
3. **Iterator trait**:实现 `next`,获得 80+ adapter
4. **Adapter 三类**:转换(map/filter 等)/ 消费(collect/sum 等)/ 观察(inspect/peekable)
5. **Lazy evaluation**:adapter 返回新 iterator,终结操作才驱动
6. **零成本秘密**:monomorphization + inline → 等同手写循环
7. **错误处理短路**:`collect::<Result<Vec<_>, _>>()` 优雅处理批量操作的失败

### 习题

#### 习题 10.1(简单)

把下面 for 循环改成 iterator chain:

```rust
let mut result = vec![];
for n in 1..=20 {
    if n % 2 == 0 {
        result.push(n * n);
    }
}
```

#### 习题 10.2(中等)

实现一个 `Fibonacci` 迭代器:

```rust
let fib = Fibonacci::new();
let first_10: Vec<u64> = fib.take(10).collect();
// [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
```

#### 习题 10.3(中等)

下面代码报错,找出原因并修复:

```rust
fn main() {
    let s = String::from("hello");
    let f = || println!("{}", s);
    std::thread::spawn(f);
}
```

#### 习题 10.4(困难)

实现一个 `chunks_by` adapter:把 iter 按"key 相同"分组,返回 Vec<Vec<T>>。

```rust
let v = vec![1, 1, 2, 2, 2, 3, 1];
let groups: Vec<Vec<i32>> = v.into_iter().chunks_by(|x| *x).collect();
// [[1,1], [2,2,2], [3], [1]]
```

提示:可能要用 trait 扩展或者写一个 wrapper struct 实现 Iterator。

#### 习题 10.5(开放)

回顾你写过的 Go for 循环或 JS .map 链。试着用 Rust iterator chain 重写。
你会发现某些场景 Rust 写起来更短(filter_map / collect 短路 Result),某些场景反而更长(双重索引、复杂 break)。这是判断"什么时候 iterator,什么时候 for"的实操经验。

---

### 下一章预告

Ch 11 进入并发——线程、Send、Sync。Rust 的并发故事从这里开始。

---

> **本章一句话总结**
>
> Iterator 不只是函数式风格的语法糖,它是 Rust 把"表达力"和"性能"放在一起的核心 abstraction。掌握它你的代码会简洁一个量级。
