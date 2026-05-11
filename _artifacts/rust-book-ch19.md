# 第 19 章 · FFI 与跨语言边界

> "Rust gets along with everyone — C, Python, Node.js — but you pay for it in unsafe."

FFI(Foreign Function Interface)是 Rust 跟其他语言互操作的接口。对你来说这一章特别有用:你的 AI / 数据工程背景意味着你会经常需要"Python 调 Rust 加速热点"或"Rust 调 C 库"。

读完这章你应该能:

1. 用 `extern "C"` 暴露 Rust 函数给 C
2. 用 `bindgen` 调用 C 库,知道哪些 pitfall
3. 用 `PyO3` 把 Rust 库做成 Python module
4. 处理 FFI 边界上的字符串、所有权、错误、回调

---

## 19.1 FFI 的基础:extern 块

### 调用 C 函数

```rust
extern "C" {
    fn abs(input: i32) -> i32;
}

fn main() {
    let n = unsafe { abs(-5) };
    println!("{}", n);  // 5
}
```

`extern "C"` 块声明外部 C 函数,链接时找到。调用必须 unsafe(C 不带 Rust 的安全保证)。

### 暴露 Rust 函数给 C

```rust
#[no_mangle]
pub extern "C" fn my_function(x: i32, y: i32) -> i32 {
    x + y
}
```

- `#[no_mangle]`:不要做 Rust 的名字 mangling,保留函数名
- `pub extern "C"`:C ABI,可被外部链接

构建动态库,需要 Cargo.toml:

```toml
[lib]
crate-type = ["cdylib"]
```

生成 `libmy_crate.so`(Linux)/ `my_crate.dll`(Windows)/ `libmy_crate.dylib`(macOS)。

---

## 19.2 FFI 类型映射

C 类型跟 Rust 类型映射:

| C | Rust |
|---|---|
| `char` | `c_char`(可能是 i8 或 u8) |
| `int` | `c_int`(通常 i32) |
| `long` | `c_long`(平台相关) |
| `unsigned int` | `c_uint` |
| `float` | `f32` |
| `double` | `f64` |
| `T*` | `*mut T` / `*const T` |
| `const char*` | `*const c_char` |
| `void*` | `*mut c_void` |
| `void` 返回 | `()` |
| `bool`(C99) | `bool` |

实际用 `libc` crate 提供的 type alias(`c_int` 等),避免硬编码。

### 字符串:CString 与 CStr

C 字符串是 null 结尾的 byte sequence。Rust:

- `CString`:owned C 字符串(类似 `String`)
- `CStr`:borrowed C 字符串(类似 `&str`)
- `CString::new("hello")?` 构造,失败如果含 0 字节

```rust
use std::ffi::{CString, CStr};
use std::os::raw::c_char;

extern "C" {
    fn puts(s: *const c_char) -> i32;
}

fn main() {
    let cstr = CString::new("Hello from C!").unwrap();
    unsafe { puts(cstr.as_ptr()); }
    // cstr 在这里 drop,释放内存
}
```

注意陷阱:`cstr.as_ptr()` 返回的指针**只在 cstr 活着时有效**。常见 bug:

```rust
// ❌ Bug
let p = CString::new("hello").unwrap().as_ptr();
// CString 临时值在此句结束时 drop,p 立刻悬垂
unsafe { puts(p); }
```

修复:`let cstr = ...; let p = cstr.as_ptr();`,保证 cstr 活到使用之后。

### Rust → C 返回字符串

C 期望 `char*`:

```rust
#[no_mangle]
pub extern "C" fn greet() -> *mut c_char {
    let s = CString::new("hello").unwrap();
    s.into_raw()    // 转移所有权给 C
}

#[no_mangle]
pub extern "C" fn free_greet(s: *mut c_char) {
    if !s.is_null() {
        unsafe { let _ = CString::from_raw(s); }
        // CString 在此 drop,释放内存
    }
}
```

设计原则:**谁分配的内存,提供谁释放的函数**。这是 FFI 最大的内存管理坑——C 不能直接 free Rust 的内存(分配器可能不同)。

---

## 19.3 调用 C 库:bindgen

手写 `extern "C"` 块对大型 C 库不现实(几百个函数)。`bindgen` 自动生成绑定:

### 步骤

1. 写 `build.rs` 生成 bindings:

```rust
// build.rs
fn main() {
    println!("cargo:rustc-link-lib=zstd");  // 链接 libzstd

    let bindings = bindgen::Builder::default()
        .header("wrapper.h")                // 包含目标 C 头
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("Unable to generate bindings");

    let out_path = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings");
}
```

2. `wrapper.h`:

```c
#include <zstd.h>
```

3. 代码里 include:

```rust
include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

fn main() {
    let level = unsafe { ZSTD_maxCLevel() };
    println!("max compression level: {}", level);
}
```

bindgen 读 zstd.h,生成所有函数、struct、enum、constant 的 Rust 绑定。

### 常见 pitfall

- **C struct 字段对齐 / packing**:bindgen 处理大多数,但某些平台特定的 layout 需要手动调
- **回调函数**:C 函数指针的 ABI 跟 Rust 函数不一样,需要 `extern "C" fn` 类型
- **生命周期**:C 不知道生命周期,bindings 全是裸指针,你要在 wrapper 里加 safe abstraction
- **inline 函数**:头文件里的 inline 函数 bindgen 不能生成,需要 wrapper 函数

工程实践:**bindgen 生成 raw bindings,在它上面手写 safe abstraction**。raw 模块用 `#[allow(non_camel_case_types)]` 等关掉警告,safe 模块给用户用。

### `*-sys` crate 模式

Rust 生态约定:

- `mylib-sys` crate:raw bindings(只有 bindgen 输出)
- `mylib` crate:safe abstraction(依赖 sys crate)

例子:`zstd-sys` + `zstd`、`openssl-sys` + `openssl`、`pq-sys` + `postgres`。

---

## 19.4 PyO3:Rust ↔ Python

PyO3 是 Rust 跟 Python 互操作的主流库。两个方向:

- **Rust 写 Python module**:用 PyO3 的属性,生成 `.so`/`.pyd` 给 Python import
- **Rust 嵌入 Python interpreter**:在 Rust 代码里跑 Python(少见)

我们重点看第一种——这是数据工程师把 Rust 加速热点接入 Python pipeline 的标准做法。

### 一个完整例子

`Cargo.toml`:

```toml
[lib]
name = "my_fast_lib"
crate-type = ["cdylib"]

[dependencies]
pyo3 = { version = "0.20", features = ["extension-module"] }
```

`src/lib.rs`:

```rust
use pyo3::prelude::*;

#[pyfunction]
fn sum_squares(numbers: Vec<f64>) -> f64 {
    numbers.iter().map(|x| x * x).sum()
}

#[pyfunction]
fn parallel_sum(numbers: Vec<f64>) -> f64 {
    use rayon::prelude::*;
    numbers.par_iter().sum()
}

#[pyclass]
struct FastCounter {
    count: u64,
}

#[pymethods]
impl FastCounter {
    #[new]
    fn new() -> Self {
        FastCounter { count: 0 }
    }

    fn increment(&mut self) {
        self.count += 1;
    }

    fn get(&self) -> u64 {
        self.count
    }
}

#[pymodule]
fn my_fast_lib(_py: Python<'_>, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(sum_squares, m)?)?;
    m.add_function(wrap_pyfunction!(parallel_sum, m)?)?;
    m.add_class::<FastCounter>()?;
    Ok(())
}
```

### 用 maturin 构建

`maturin` 是 PyO3 项目的标准构建工具:

```bash
pip install maturin
maturin develop          # 本地开发:build + install 到当前 venv
maturin build --release  # 构建 wheel
```

构建完 Python 直接 import:

```python
import my_fast_lib

result = my_fast_lib.sum_squares([1.0, 2.0, 3.0])
print(result)  # 14.0

counter = my_fast_lib.FastCounter()
counter.increment()
counter.increment()
print(counter.get())  # 2
```

10 行 Rust + 一个 Cargo.toml,你有一个 Python module。

### PyO3 的类型映射

| Python | Rust |
|---|---|
| `int` | `i64` / `u64` / `usize` |
| `float` | `f64` |
| `str` | `String` / `&str` |
| `bytes` | `Vec<u8>` / `&[u8]` |
| `list` | `Vec<T>` |
| `dict` | `HashMap<K, V>` / `BTreeMap` |
| `tuple` | `(T1, T2, ...)` |
| `None` | `Option<T>::None` |
| 自定义类 | `#[pyclass]` |

### GIL 与 release_gil

Python 有 GIL(Global Interpreter Lock),阻止多线程并行执行 Python 字节码。但 Rust 代码不受 GIL 约束——你可以在 Rust 里释放 GIL 跑 CPU 密集计算:

```rust
#[pyfunction]
fn heavy_compute(py: Python, data: Vec<f64>) -> f64 {
    py.allow_threads(|| {
        // GIL 在这里释放,Python 主线程能跑别的
        // 这里跑你的 Rust 计算
        data.iter().map(|x| x * x).sum()
    })
}
```

这是 Rust + Python 组合的关键收益——**多个 Python 线程可以并行调你的 Rust 函数,绕过 GIL**。NumPy / pandas 这些库就是这么实现并行的。

### Pitfall:大 list 的传递成本

```rust
#[pyfunction]
fn process(data: Vec<f64>) -> Vec<f64> {
    data.iter().map(|x| x * 2.0).collect()
}
```

Python 调这个函数时:
1. PyO3 把 Python list 转 Vec<f64>(每个元素 alloc + copy)
2. Rust 计算
3. Vec<f64> 转回 Python list(再一轮 alloc + copy)

如果 list 是百万级,转换开销比计算还大。

解决:用 NumPy array,通过 buffer protocol 零拷贝:

```rust
use numpy::{PyArray1, IntoPyArray};

#[pyfunction]
fn process<'py>(py: Python<'py>, data: &PyArray1<f64>) -> &'py PyArray1<f64> {
    let arr = data.readonly();
    let slice = arr.as_slice().unwrap();
    let result: Vec<f64> = slice.iter().map(|x| x * 2.0).collect();
    result.into_pyarray(py)
}
```

`numpy` crate 让 Rust 直接操作 NumPy array 的内存,零拷贝。性能差异:几倍到几十倍。

---

## 19.5 cbindgen:Rust → C 头文件

跟 bindgen 相反方向。`cbindgen` 自动生成 C 头文件供其他 C/C++ 代码 include:

```bash
cargo install cbindgen
cbindgen --crate my_rust_lib --output my_rust_lib.h
```

输出:

```c
#ifndef MY_RUST_LIB_H
#define MY_RUST_LIB_H

#include <stdint.h>

int32_t my_function(int32_t x, int32_t y);

#endif
```

C/C++ 代码:

```c
#include "my_rust_lib.h"

int main() {
    int r = my_function(2, 3);
    printf("%d\n", r);
    return 0;
}
```

工程场景:把 Rust crate 当 C 库给 C++ / Swift / 其他语言用(任何能调 C 的语言都能调)。

---

## 19.6 FFI 的几个安全实践

### 实践 1:边界检查

```rust
#[no_mangle]
pub extern "C" fn process_data(ptr: *const u8, len: usize) -> i32 {
    if ptr.is_null() {
        return -1;
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    // ... 用 slice
    0
}
```

任何来自 C 的指针,**第一件事是 null 检查**。

### 实践 2:catch panic

Rust panic 跨 FFI 边界是 UB。在 extern "C" 函数里包 `catch_unwind`:

```rust
use std::panic::{catch_unwind, AssertUnwindSafe};

#[no_mangle]
pub extern "C" fn safe_entry() -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        // 你的 Rust 代码,可能 panic
        risky_operation();
        0
    }));
    match result {
        Ok(code) => code,
        Err(_) => -1,  // panic 被捕获,转成错误码
    }
}
```

### 实践 3:返回错误码而非 panic

C ABI 没有 Result。FFI 函数用错误码约定:

```rust
#[no_mangle]
pub extern "C" fn open_file(path: *const c_char, fd_out: *mut i32) -> i32 {
    if path.is_null() || fd_out.is_null() {
        return ERR_INVALID_ARG;
    }
    let cstr = unsafe { CStr::from_ptr(path) };
    let s = match cstr.to_str() {
        Ok(s) => s,
        Err(_) => return ERR_UTF8,
    };
    match std::fs::File::open(s) {
        Ok(f) => {
            unsafe { *fd_out = /* convert f to fd */ 0 };
            0
        }
        Err(_) => ERR_IO,
    }
}
```

### 实践 4:Opaque pointer pattern

不暴露 struct 内部布局,只给 C 一个 opaque 指针:

```rust
pub struct InternalState { /* fields */ }

#[no_mangle]
pub extern "C" fn state_create() -> *mut InternalState {
    Box::into_raw(Box::new(InternalState { /* ... */ }))
}

#[no_mangle]
pub extern "C" fn state_destroy(state: *mut InternalState) {
    if !state.is_null() {
        unsafe { let _ = Box::from_raw(state); }
    }
}

#[no_mangle]
pub extern "C" fn state_do_something(state: *mut InternalState) -> i32 {
    let state = unsafe { &mut *state };
    // ... 操作 state
    0
}
```

C 头文件里 `InternalState` 是 `typedef struct InternalState InternalState;`(不知道大小),只能通过指针操作。Rust 内部可以随便改 struct 布局,C 接口稳定。

---

## 19.7 章末小结与习题

### 本章核心概念回顾

1. **`extern "C"`**:声明外部 C 函数 / 暴露 Rust 函数
2. **`#[no_mangle]`**:保留函数名,C 才能链接
3. **CString / CStr**:Rust ↔ C 字符串转换,注意生命周期
4. **bindgen**:C 库 → Rust binding
5. **cbindgen**:Rust → C 头文件
6. **PyO3 + maturin**:Rust → Python module 的标准栈
7. **GIL 释放**:`py.allow_threads` 让 Rust 跑并行计算
8. **零拷贝 NumPy**:大数据用 PyArray 而非 Vec
9. **FFI 安全实践**:null check / catch_unwind / 错误码 / opaque pointer

### 习题

#### 习题 19.1(简单)

写一个 Rust 函数 `add(a: i32, b: i32) -> i32`,用 extern "C" 暴露,从 C 程序调用。

#### 习题 19.2(中等)

用 PyO3 包装一个 Rust 函数:接受 `Vec<f64>`,返回均值和标准差(tuple)。

#### 习题 19.3(中等)

下面 FFI 代码有 bug,找出来:

```rust
#[no_mangle]
pub extern "C" fn get_name() -> *const c_char {
    let s = CString::new("hello").unwrap();
    s.as_ptr()
}
```

#### 习题 19.4(困难,工程)

回到你 AI/data 工程背景。设计一个 Rust crate:
- 用 Rust 实现一个高性能 CSV parser
- 通过 PyO3 暴露给 Python
- 返回 Pandas DataFrame(用 pyo3-polars 或类似)
- 释放 GIL,让多个 Python 线程能并发用

写出 Cargo.toml + 主要函数签名 + 用 maturin 构建的步骤。

#### 习题 19.5(开放)

回顾你过去 Python 项目中 CPU 密集的代码段。如果用 Rust + PyO3 加速,会是怎样的:
- 性能提升预估
- 维护成本(团队 Rust 熟练度)
- 部署成本(wheels 平台支持)

考虑值不值得做。

---

### 下一章预告

Ch 20 是毕业作品:**从零实现 Mini-Tokio**。把这本书所有概念串起来——unsafe / Future / Pin / Waker / channel / executor / work-stealing。

---

> **本章一句话总结**
>
> FFI 是 Rust 跟外部世界对话的门。Rust 在 safety 上的承诺到 FFI 边界就由你接管——加 null 检查、catch panic、用 opaque pointer。门后是 C / Python / 任何能调 C 的语言。
