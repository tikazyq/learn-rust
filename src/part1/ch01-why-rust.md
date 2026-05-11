# Ch 1 · 为什么 Rust 不一样

> "If you're going to learn Rust, you need to first unlearn some things you know about programming."
> — 一位匿名 Rust 老手

这一章不教语法。这一章只做一件事:**让你对 Rust 这门语言形成正确的预期**。

如果你跳过这一章直奔后面的 ownership、trait、async,你会在某个时刻撞墙。撞墙的原因不是技术,是心智模型——你带着 Go 或 C# 的世界观走进 Rust,会发现编译器一直在拒绝你"明显正确"的代码。这章帮你提前调整世界观。

---

## 1.1 这本书是写给谁的

直接对话——你已经写了多年代码。你懂 GC、懂 channel、懂 interface、懂 async/await、懂 generic constraint、懂 monorepo、懂分布式系统的取舍。市面上的 Rust 书要么把你当成 C++ 老兵(假设你天天手写 `new`/`delete`),要么把你当成新手(从 `let x = 1` 讲起),都不合适。

**这本书假设你已经会的事情**:

- 至少一门 GC 语言到生产级(Go / Java / C# / Python / TS 任意一种)
- 并发的基本概念:thread、mutex、race condition、deadlock
- 异步的基本概念:event loop、Promise/Task、callback hell
- 泛型与接口:Go interface、C# generic、TS type parameter
- 工程基础:版本控制、CI/CD、依赖管理、单元测试

**这本书不会教你的事情**:

- 什么是变量
- 什么是函数
- 什么是循环
- 什么是面向对象

**这本书不是**:

- *Rust 语法手册*(那是 *The Rust Reference*)
- *Rust 食谱*(那是 *Rust by Example*)
- 一本万人通用的教科书

**这本书是**:

- 一份从你已知世界出发,到 Rust 的迁移指南
- 一本对你已有的工程直觉做"必要拆除和重建"的书
- 一本写到 unsafe 与 async runtime 内部的全栈视图

---

## 1.2 五分钟内看到 Rust 的差异

理论说再多不如一段代码。下面这个任务用三种语言实现:**并发抓取一组 URL,把响应体收集起来**。

### Go 版本

```go
func fetchAll(urls []string) []string {
    results := make([]string, len(urls))
    var wg sync.WaitGroup
    for i, url := range urls {
        wg.Add(1)
        go func(i int, url string) {
            defer wg.Done()
            resp, err := http.Get(url)
            if err != nil {
                return
            }
            defer resp.Body.Close()
            body, _ := io.ReadAll(resp.Body)
            results[i] = string(body)
        }(i, url)
    }
    wg.Wait()
    return results
}
```

写得很自然。但请回答几个问题:

- `results[i] = string(body)` 是在多个 goroutine 里并发写同一个 slice。这为什么是安全的?
- 答:因为不同 goroutine 写**不同的 index**,所以底层数组的不同 cache line 不会冲突。这是程序员的承诺,**编译器不验证**。
- 如果某天你重构,把 `results[i] = ...` 改成 `results = append(results, ...)`,会发生什么?
- 答:运行时数据竞争,`go test -race` 可能能抓到,生产环境可能不能。线上挂掉。

### C# 版本

```csharp
async Task<List<string>> FetchAll(List<string> urls)
{
    using var client = new HttpClient();
    var tasks = urls.Select(u => client.GetStringAsync(u));
    return (await Task.WhenAll(tasks)).ToList();
}
```

更简洁。但请注意:

- `client` 是被 closure 捕获的。多个 task 并发使用同一个 `HttpClient`——这为什么安全?
- 答:因为 `HttpClient` 的设计者承诺它线程安全。这是**库的承诺**,编译器不验证。
- 如果你换成自己的 stateful object,async 之间的状态污染需要你自己想清楚。
- 如果你忘了 `await`(`var tasks = ...; return tasks.ToList();`),编译器会给你警告但不会报错。Production crash 风险。

### Rust 版本(Tokio)

```rust
use reqwest::Client;
use futures::future::join_all;

async fn fetch_all(urls: Vec<String>) -> Vec<String> {
    let client = Client::new();
    let futures = urls.into_iter().map(|u| {
        let client = client.clone();
        async move {
            let resp = client.get(&u).send().await?;
            let body = resp.text().await?;
            Ok::<_, reqwest::Error>(body)
        }
    });
    join_all(futures).await
        .into_iter()
        .filter_map(Result::ok)
        .collect()
}
```

注意几个细节:

- **`let client = client.clone();`**:为什么这一行必须有?Rust 不会让你"隐式共享"。
- **`async move`**:`move` 关键字明确告诉编译器"closure 接管捕获变量的所有权"。
- **`Result::ok` + `filter_map`**:错误必须显式处理。Rust 没有"unhandled exception"这种东西。

> ⚠️ **本节剩余内容(对比表 + 三语言的责任分配 + ASCII 内存示意图)需补充。**
>
> 这一节是 Ch 1 的"五分钟震撼"——让读者立刻看到 Rust 的不同。完整版应包括:
>
> - 三语言对比表(谁验证什么)
> - Rust 编译器在编译这段代码时检查了哪些事情
> - 如果让 Rust 接受不安全的写法,编译器给出什么错误

---

## 1.3 Rust 多了一个维度:所有权

> ⚠️ **本节正文待补。**
>
> 核心论点:其他语言只关心"值是什么",Rust 还关心"值属于谁、活多久"。
>
> 应包含的内容:
>
> - "类型 + 所有权"二维表格(把概念可视化成一个网格)
> - 为什么这第二个维度让 GC、unsafe、async 三个问题用同一个机制解决
> - Go GC / C# GC / C 手动 / Rust 所有权 四种内存管理模式的对比

---

## 1.4 Rust 不是反人类,它是反"省事"

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - Rust 强迫显式表达的清单(可见性、可变性、错误、生命周期等)
> - 这些"显式"的工程价值:被 review、被压测、被维护时的优势
> - 反例:省事的代价(用线上事故举例)

---

## 1.5 学习曲线长什么样

> ⚠️ **本节正文待补。**
>
> 应包含:
>
> - 经典的"Rust 学习曲线"图(几个阶段的描述)
> - 老手 vs 新手的曲线差异(老手前期更慢,中期反超)
> - 卡住时的应对策略

---

## 1.6 从 Go / C# / TS 到 Rust 的术语翻译表

> ⚠️ **本节正文待补。**
>
> 应包含约 40 条核心概念翻译。完整版 200+ 条在附录 B/C。

---

## 1.7 这本书的读法建议

> ⚠️ **本节正文待补。**

---

## 1.8 习题

> ⚠️ **本节习题待补。**
>
> 建议包含:
>
> - 1.1(简单):列出你最常用的语言里"不显式但 Rust 会显式"的事情
> - 1.2(思考):你为什么决定学 Rust?用一段话写下来,Week 12 末尾回来对照
> - 1.3(开放):找一段你写过的并发代码,标出哪些安全保证靠编译器、哪些靠你自己

---

> **本章一句话总结**
>
> Rust 不是"更难的 Go",也不是"更安全的 C++"。它是一门多了一个维度(所有权)的语言。理解这个维度,你能写出任何其他语言都达不到的安全和性能;理解不到,你会一直跟编译器吵架。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点(借用检查器拒绝的具体场景) | |
| 关键收获 | |
| 配套代码仓库链接 | |
