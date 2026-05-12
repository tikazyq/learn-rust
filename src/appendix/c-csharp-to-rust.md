# 附录 C · C# → Rust 概念翻译大全

> 面向 .NET 工程师的迁移指南

**核心问题**:C# 中的每个概念在 Rust 中对应什么?

C# 和 Rust 都属于"类型系统强、面向系统的语言",但底层假设不同:C# 假定有 GC + 运行时 + 反射,Rust 假定零成本 + 静态决定一切。这附录给你常用 C# 概念到 Rust 的对照。

---

## C.1 类型系统

| C# | Rust | 备注 |
|---|---|---|
| `class Foo { ... }`(reference type) | `struct Foo { ... }` + `Arc<Foo>` 共享 | Rust 默认 value,共享要显式 Arc |
| `struct Foo { ... }`(value type) | `struct Foo { ... }` | 一致(但 Rust 不区分 class / struct) |
| `record Foo(int X, int Y)` | `#[derive(Clone, PartialEq, Eq, Hash)] struct Foo(i32, i32)` | record 等价于"自动生成 Equality 的 struct" |
| `interface IFoo { void Bar(); }` | `trait Foo { fn bar(&self); }` | nominal,显式实现 |
| `enum Color { Red, Green }` | `enum Color { Red, Green }` | Rust enum 是 sum type,比 C# 强得多 |
| `enum Color : byte` | `#[repr(u8)] enum Color { ... }` | |
| `class Tagged<T>` | `struct Tagged<T>` | |
| `T?`(nullable reference) | `Option<T>` | 显式 |
| `Tuple<A, B>` / `(A, B)` | `(A, B)` | |
| `dynamic` | 没有等价(`Box<dyn Any>` 受限) | Rust 鄙视动态类型 |
| `object` | `Box<dyn Any>` |  受限 |
| sealed class | 默认就是(Rust 没有继承) | |
| abstract class | 用 trait + default methods | |
| partial class | 没有(模块拆分代替) | |

---

## C.2 内存管理

| C# | Rust |
|---|---|
| GC,自动回收 | ownership + Drop,确定性回收 |
| `IDisposable` + `using` | `Drop` trait,作用域结束自动释放 |
| `IAsyncDisposable` + `await using` | 没有 async drop(用 explicit `close()`) |
| `WeakReference<T>` | `Weak<T>`(`Rc::downgrade` / `Arc::downgrade`) |
| `GC.Collect()` | 没有(对象在所有者 drop 时立刻释放) |
| ref struct(stack-only) | 普通 struct(默认就在栈) |
| `stackalloc` | 普通数组 / `SmallVec` |
| pinned object(`fixed`) | `Box::leak` / `Pin` |
| `Span<T>` / `Memory<T>` | `&[T]` / `&mut [T]`(更自然) |

---

## C.3 async/await

| C# | Rust |
|---|---|
| `Task` / `Task<T>`(hot) | `impl Future<Output = T>`(lazy) |
| `ValueTask<T>` | 没有专门类型,Rust Future 默认就在栈 |
| `await task` | `future.await` |
| `Task.Run(() => ...)` | `tokio::spawn(async { ... })` |
| `Task.WhenAll(tasks)` | `futures::future::join_all` 或 `JoinSet` |
| `Task.WhenAny(tasks)` | `tokio::select!` / `FuturesUnordered::next` |
| `CancellationToken` | drop Future / `tokio_util::sync::CancellationToken` |
| `Task.Delay(...)` | `tokio::time::sleep(...).await` |
| `ConfigureAwait(false)` | 没有(Rust async 默认无 SyncContext) |
| `IAsyncEnumerable<T>` | `futures::Stream<Item = T>` |
| `await foreach` | `while let Some(x) = stream.next().await` |
| `SemaphoreSlim` | `tokio::sync::Semaphore` |
| `Channel<T>` | `tokio::sync::mpsc::channel` |

---

## C.4 LINQ → Iterator chain

| C# LINQ | Rust Iterator |
|---|---|
| `.Where(x => p)` | `.filter(\|x\| p)` |
| `.Select(x => x.Name)` | `.map(\|x\| x.name)` |
| `.SelectMany(...)` | `.flat_map(...)` |
| `.OrderBy(x => k)` | `.sorted_by_key(\|x\| k)`(via itertools)或 `Vec::sort_by_key` |
| `.GroupBy(...)` | `.fold` 或 itertools `.group_by` |
| `.Distinct()` | `.collect::<HashSet<_>>()` |
| `.First() / .FirstOrDefault()` | `.next()` |
| `.Single()` | 自己写 |
| `.Count()` | `.count()` |
| `.Sum() / .Max() / .Min() / .Average()` | `.sum() / .max() / .min() / fold for average` |
| `.Any(p) / .All(p)` | `.any(\|x\| p) / .all(\|x\| p)` |
| `.Take(n) / .Skip(n)` | `.take(n) / .skip(n)` |
| `.ToList() / .ToArray()` | `.collect::<Vec<_>>()` |
| `.ToDictionary(k, v)` | `.collect::<HashMap<_, _>>()` |
| `.Zip(other)` | `.zip(other)` |
| `.Aggregate(seed, fn)` | `.fold(seed, fn)` |
| 表达式树 LINQ to SQL | sqlx + 编译期校验 SQL |

性能差异:LINQ 有委托调用 / 装箱,Rust iterator 是零成本(见 Ch 10)。

---

## C.5 Attributes → derive / proc-macro

| C# | Rust |
|---|---|
| `[Serializable]` | `#[derive(Serialize, Deserialize)]` |
| `[JsonProperty("name")]` | `#[serde(rename = "name")]` |
| `[Required]` (DataAnnotations) | 用类型表达(`Option<T>` vs `T`) |
| `[AttributeUsage]` 自定义 | 写 proc-macro |
| reflection `typeof / GetType()` | `std::any::TypeId` / `type_name`,受限 |
| `[DllImport]` / P/Invoke | `extern "C"` + `#[link]` / `bindgen` |
| `[Conditional("DEBUG")]` | `#[cfg(debug_assertions)]` |
| `[Obsolete("...")]` | `#[deprecated(note = "...")]` |
| source generator | proc-macro |

---

## C.6 Nullable

| C# | Rust |
|---|---|
| `T?`(reference / value nullable) | `Option<T>` |
| `x?.Foo()` | `x.as_ref().map(\|v\| v.foo())` |
| `x ?? default` | `x.unwrap_or(default)` |
| `x ??= default` | `x.get_or_insert(default)`(对 Option) |
| `!`(null-forgiving) | `.unwrap()`(更安全:崩在显式 unwrap 处) |
| nullability annotation `#nullable enable` | Option 强制了 |

Rust 没有"无意识的 null"——把"可能没有"显式编码在类型上,**编译器逼你处理 None 分支**。这是 Rust 比 C# 安全的核心一点之一。

---

## C.7 异常 → Result

| C# | Rust |
|---|---|
| `try { } catch (Exception e) { }` | `match result { Ok(v) => ..., Err(e) => ... }` |
| `try { } catch (FooEx e1) { } catch (BarEx e2) { }` | enum + match 多分支 |
| `throw new FooException("msg")` | `return Err(FooError::new("msg"))` |
| `throw;`(rethrow) | `return Err(e)` |
| `using` + dispose on exception | `Drop` 自动处理(无 try/finally) |
| `Exception.InnerException` | `source()` (`std::error::Error::source`) |
| custom exception class | enum variant + thiserror |
| `Ex.StackTrace` | `RUST_BACKTRACE=1` + `std::backtrace::Backtrace` |
| `Task.Exception` | `Result<T, E>` |

经验:**Rust 90% 错误用 Result;只在"真正异常" / 不变量违反时 panic**。

---

## C.8 Generic constraints → trait bounds

| C# | Rust |
|---|---|
| `where T : class` | 没有完全等价(Rust 没有 reference/value 区分) |
| `where T : struct` | `T: Copy`(对 value type 模拟) |
| `where T : new()` | `T: Default` 或 `T: From<...>` |
| `where T : IFoo` | `T: Foo`(trait 名一样) |
| `where T : IFoo, IBar` | `T: Foo + Bar` |
| `where T : U`(类型参数关系) | `T: Trait<U>` 类似关联类型 |
| variance(`out T` / `in T`) | variance 由编译器从字段推断(见 Ch 7) |
| reified generic(value type) | monomorphization(同效果) |

---

## C.9 NuGet ↔ crates.io

| C# | Rust |
|---|---|
| `dotnet add package Foo` | `cargo add foo` |
| `Foo.csproj` | `Cargo.toml` |
| `obj/ / bin/` | `target/` |
| `nuget.org` | `crates.io` |
| `dotnet pack` / `nuget push` | `cargo publish` |
| `dotnet restore` | `cargo build`(自动) |
| .NET Standard 多版本兼容 | edition + feature + MSRV |
| private feed | `[source]` in `.cargo/config.toml` |

---

## C.10 测试

| C# (xUnit / NUnit) | Rust |
|---|---|
| `[Fact]` / `[Test]` | `#[test]` |
| `[Theory]` + `[InlineData]` | `#[test]` 多个 / 用 `proptest`(更强) |
| `Assert.Equal(a, b)` | `assert_eq!(a, b)` |
| `Assert.Throws<T>(...)` | `#[should_panic(expected = "...")]` |
| `Moq` | `mockall` |
| BenchmarkDotNet | `criterion` |
| Coverlet 覆盖率 | `cargo llvm-cov` |
| dotnet-trace / dotnet-counters | `tokio-console` / `pprof-rs` / `flamegraph` |
| `IDisposable` cleanup | `Drop` |
| `IAsyncLifetime` | 测试函数手动 setup/cleanup |

---

## 几条战略级差异(给 C# 工程师)

1. **没有 GC,但你不用 manual free** —— ownership 自动管,但你要学会"思考所有权"
2. **没有 exception** —— `Result<T, E>` 把"可能失败"写进类型,所有调用方必须显式处理
3. **没有 null reference** —— `Option<T>` 强制你解构,bug 大幅减少
4. **没有继承** —— trait + 组合代替,设计上更平
5. **没有 reflection** —— 类型擦除、运行时类型查询都很受限。**这是优点**:静态决定一切,优化空间大
6. **async 模型不同** —— Rust Future 是 lazy + value type,没有 Task pool / SynchronizationContext
7. **没有 LINQ provider** —— sqlx 用编译期 SQL 校验代替 LINQ-to-SQL,体验不一样但更可控

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
