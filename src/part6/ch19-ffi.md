# Ch 19 · FFI 与跨语言边界

> Rust 怎么跟 C / Python / JS / WASM 互操作

**核心问题**:Rust 和别的语言怎么互操作?每种边界各有什么坑?

Rust 的现实世界主战场之一就是**给别的语言提供库**:Python(AI / 数据)、Node.js(前端工具)、C/C++(系统集成)、Web 浏览器(WASM)。这章是工程师向导,讲每种边界的工具、坑、生产实践。

读完你应该能:

1. 解释 C ABI / `#[repr(C)]` / `#[no_mangle]` 各自做什么
2. 用 bindgen 调一个 C 库,用 cbindgen 把 Rust 暴露给 C
3. 用 PyO3 给 Python 写一个 Rust 模块
4. 用 napi-rs 给 Node.js 写一个 Rust 模块
5. 用 wasm-bindgen 把 Rust 编到浏览器

---

## 19.1 C ABI 基础

Rust 默认 ABI 不稳定——版本之间结构布局可能改。要跨语言,必须用 C ABI(几十年来稳定的事实标准)。

### 三个关键 attribute

```rust,ignore
#[no_mangle]                       // 不混淆函数名,符号叫 add_one
pub extern "C" fn add_one(x: i32) -> i32 { x + 1 }

#[repr(C)]                          // C 兼容布局
pub struct Point { pub x: f64, pub y: f64 }
```

- `extern "C"` —— 用 C ABI(参数寄存器、栈布局)
- `#[no_mangle]` —— 编译后符号保留原名(否则 Rust 加 hash 后缀,C 找不到)
- `#[repr(C)]` —— struct 字段顺序、对齐按 C 规则(否则 Rust 可能重排字段优化布局)

### 类型对应

| Rust | C |
|---|---|
| `i8/i16/i32/i64` | `int8_t/int16_t/int32_t/int64_t` |
| `u8/u16/u32/u64` | `uint8_t/...` |
| `f32/f64` | `float/double` |
| `bool` | `bool`(stdbool.h) |
| `*const T / *mut T` | `const T* / T*` |
| `Option<&T>`(T:Sized) | `T*`(可为 NULL,niche 优化) |
| `&[T]` | **没有直接对应**(必须拆成 ptr + len) |
| `String` | **没有直接对应**(只能 `*const c_char` + len) |

### 字符串边界

```rust,ignore
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::catch_unwind;
use std::ptr;

#[no_mangle]
pub extern "C" fn greet(name: *const c_char) -> *mut c_char {
    // FFI 边界:任何 panic 跨过都是 UB,所以整体包 catch_unwind。
    let result = catch_unwind(|| {
        if name.is_null() { return ptr::null_mut(); }
        // SAFETY: 调用方保证 name 指向以 NUL 结尾的有效 C 字符串。
        let cstr = unsafe { CStr::from_ptr(name) };
        let s = match cstr.to_str() {
            Ok(s) => s,                                 // UTF-8 非法 → 返回 Err,不是 UB
            Err(_) => return ptr::null_mut(),
        };
        let owned = format!("Hello, {}!", s);
        match CString::new(owned) {
            Ok(c) => c.into_raw(),                       // 把所有权交给 C
            Err(_) => ptr::null_mut(),                   // 内部含 NUL → 返回 NULL
        }
    });
    result.unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn free_string(s: *mut c_char) {
    if s.is_null() { return; }
    // SAFETY: s 必须是之前由 greet 返回的指针,且未被 free 过。
    unsafe { let _ = CString::from_raw(s); }   // Rust 回收
}
```

**三条边界规则**:

1. **谁分配谁释放**:不能 Rust 用 `malloc` C 用 `free`(allocator 不同)。必须暴露 `free_string` 给 C 调用。
2. **NULL / NUL 终止符的安全责任**:`CStr::from_ptr(name)` 要求 `name` 非 NULL 且指向 NUL 结尾的 C 字符串——违反就是 UB。**所以入口先做 NULL 检查,文档里写明 NUL 终止的契约**。
3. **错误用返回值表达,不要 `unwrap`**:`to_str` 失败(非 UTF-8)和 `CString::new` 失败(中间含 NUL 字节)都返回 `Err`,**这不是 UB,但你 `.unwrap()` 一旦 panic 跨过 FFI 边界就成 UB 了**。所有 `extern "C" fn` 都该 `catch_unwind` 兜底。

---

## 19.2 调 C 库:bindgen 自动生成 binding

```toml
[build-dependencies]
bindgen = "0.70"
```

```rust,ignore
// build.rs
fn main() {
    println!("cargo:rustc-link-lib=zstd");
    let bindings = bindgen::Builder::default()
        .header("wrapper.h")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("Unable to generate bindings");
    let out_path = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
    bindings.write_to_file(out_path.join("bindings.rs")).unwrap();
}
```

```rust,ignore
include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

fn main() {
    let v = unsafe { ZSTD_versionNumber() };
    println!("zstd version: {}", v);
}
```

bindgen 解析 `wrapper.h`(`#include <zstd.h>` 等),生成 Rust 的 `extern "C"` 声明 + `#[repr(C)]` struct。你直接 `unsafe` 调即可。

### 工程包装

bindgen 生成的是 `-sys` crate(惯例:`libfoo-sys`)。在上面再封装一个安全 crate `libfoo`:

```
my-zstd/
├── libzstd-sys/        # bindgen 输出,raw unsafe
└── libzstd/            # 在上面包安全 API:Compressor / Decompressor / Stream
```

Rust 生态约定:**sys crate = 1:1 binding,普通 crate = 安全封装**。

---

## 19.3 暴露 Rust 给 C/C++:cbindgen

```toml
[build-dependencies]
cbindgen = "0.27"
```

```rust,ignore
// build.rs
fn main() {
    cbindgen::Builder::new()
        .with_crate(env!("CARGO_MANIFEST_DIR"))
        .with_language(cbindgen::Language::C)
        .generate()
        .unwrap()
        .write_to_file("include/my_lib.h");
}
```

`cargo build` 自动生成 `my_lib.h`:

```c
typedef struct Point { double x; double y; } Point;
double point_distance(const Point *a, const Point *b);
```

C 工程 `#include "my_lib.h"` 后链接 `libmy_lib.a` / `.so` 即可。

### Cargo.toml 编出 staticlib / cdylib

```toml
[lib]
crate-type = ["staticlib", "cdylib"]   # 选你需要的
```

- `staticlib` → `.a`(静态库,链进 C 程序)
- `cdylib` → `.so` / `.dylib` / `.dll`(动态库)
- `rlib`(默认) → Rust-only,不能给 C 用

---

## 19.4 PyO3:暴露 Rust 给 Python

```toml
[lib]
name = "my_rust_module"
crate-type = ["cdylib"]

[dependencies]
pyo3 = { version = "0.22", features = ["extension-module"] }
```

```rust,ignore
use pyo3::prelude::*;

#[pyfunction]
fn sum_as_string(a: usize, b: usize) -> PyResult<String> {
    Ok((a + b).to_string())
}

#[pymodule]
fn my_rust_module(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(sum_as_string, m)?)?;
    Ok(())
}
```

构建 + 安装(用 maturin):

```bash
pip install maturin
maturin develop   # 编译并 pip install 到当前 venv
```

```python
import my_rust_module
print(my_rust_module.sum_as_string(1, 2))   # "3"
```

### AI 工程价值

Python 数据科学栈 + Rust 高性能 = 现代标配:

- **pydantic-core**:Pydantic v2 内核(Rust 写,Pydantic 速度提升 5-50x)
- **polars**:DataFrame 库(pandas 替代,纯 Rust)
- **ruff**:Python linter,比 flake8 快 10-100x
- **uv**:Python package manager,比 pip / pipenv / poetry 都快得多
- **tokenizers** / **safetensors**:Hugging Face 生态

写 Python 的人都在间接用 Rust。

### GIL 与并发

```rust,ignore
#[pyfunction]
fn heavy(py: Python<'_>) -> PyResult<i64> {
    py.allow_threads(|| {       // 释放 GIL,Python 其他线程能跑
        (0..1_000_000_000_i64).sum()
    })
}
```

`allow_threads` 让你在 Rust 里跑 CPU 密集任务**而不阻塞 Python GIL**——这是 PyO3 性能的关键。

---

## 19.5 napi-rs:暴露 Rust 给 Node.js

```toml
[lib]
crate-type = ["cdylib"]

[dependencies]
napi = { version = "2", features = ["napi9"] }
napi-derive = "2"

[build-dependencies]
napi-build = "2"
```

```rust,ignore
use napi_derive::napi;

#[napi]
fn sum(a: i32, b: i32) -> i32 { a + b }
```

```bash
npm install -g @napi-rs/cli
napi build --platform --release
```

生成 `.node` 文件,Node.js 里 `require()` 就用。

### 实战案例

- **SWC**:Rust 写的 JS / TS 编译器(替代 Babel / TSC,快 20-70x)
- **Turbopack**(Vercel):Rust 写的 webpack 替代,Next.js 用
- **Rolldown** / **Lightning CSS**:同上,前端工具链的"用 Rust 重写"潮

---

## 19.6 WASM:Rust 编译到浏览器

```toml
[lib]
crate-type = ["cdylib", "rlib"]

[dependencies]
wasm-bindgen = "0.2"
```

```rust,ignore
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn greet(name: &str) -> String {
    format!("Hello, {}!", name)
}
```

```bash
cargo install wasm-pack
wasm-pack build --target web
```

生成 `pkg/` 目录,里面是 `.wasm` + JS glue。前端:

```js
import init, { greet } from './pkg/my_lib.js';
await init();
console.log(greet('world'));
```

### 适用场景

- 计算密集型:图像处理 / 音频处理 / 加密 / parser
- 复用业务核心代码(同一份 Rust 跑前端 + 后端)
- 在线 IDE / playground(Rust playground 自己就是 WASM)

代价:

- 二进制比 JS 大(常见 100KB-2MB)
- 跟 JS 互调有边界开销
- Rust → JS DOM 操作没有直接 API,要靠 web-sys 全套

---

## 19.7 FFI 安全检查清单

跨边界时,**安全规则全靠你**(编译器无法越过 FFI 检查):

### 1. lifetime 不穿越边界

不要把 `&'a T` 直接暴露给外部语言。如果非要,文档**严格写明**"返回的指针只在 X 之前有效"。

### 2. panic 不能跨 FFI 边界

```rust,ignore
#[no_mangle]
pub extern "C" fn risky() {
    std::panic::catch_unwind(|| {
        // 你的代码,可能 panic
    }).unwrap_or_else(|_| {
        // 处理 panic(转 error code 等)
    });
}
```

panic 跨 FFI = UB。所有 `extern "C" fn` 入口都应该 `catch_unwind` 或保证不 panic。

### 3. 用错误码,不用异常

Python / JS / Java 期待异常,C/Go/Rust 期待返回值。**Rust 的 Result 转什么由调用方决定**。常见做法:返回 `i32`(0 = OK,负数 = 错误码)。

### 4. UTF-8 vs 别的编码

区分两类失败:

- **指针无效 / 不是以 NUL 结尾** → `CStr::from_ptr` 直接 UB(编译器无法检测,你必须保证)
- **字节合法但不是 UTF-8** → `to_str()` 返回 `Err(Utf8Error)`,**不是 UB**;转 `Result` 处理即可

所以从 C 接来 `*const c_char` 时,**先 NULL 检查,再 `CStr::from_ptr(...)`(凭契约 unsafe),最后 `to_str()?` 拿到 `&str`**——前两步是安全责任,第三步是普通错误处理。

### 5. allocator 不能跨边界

C 的 malloc 跟 Rust 的 alloc 是两个 allocator,**互相不能 free**。设计 API 时:谁分配谁释放,或暴露明确的 `free_xxx` 函数。

### 6. opaque pointer 比 struct 安全

把 Rust 类型作为 opaque `void*` 暴露给 C,比暴露 `#[repr(C)]` struct 安全得多——你保留了改动内部布局的自由。

---

## 19.8 真实案例

| 项目 | 干什么 | FFI 边界 |
|---|---|---|
| **ruff** | Python linter(替代 flake8 / pylint) | 纯 Rust,带 Python wrapper |
| **uv** | Python package manager | 纯 Rust binary,通过 CLI 跟 Python 交互 |
| **polars** | DataFrame | Rust core + PyO3 + napi |
| **deno** | TypeScript runtime | Rust + v8 binding |
| **swc** | JS 编译器 | Rust + napi-rs |
| **turbopack** | bundler | Rust + napi-rs |
| **firefox** | 浏览器 | C++ + Rust(CSS engine 等子系统) |
| **discord** | 部分服务后端 | Elixir/Erlang + Rust(NIF) |

**生态趋势**:**FFI 边界写好的 Rust 库 > 用 Rust 写整个产品**。所以这章是高 ROI 内容。

---

## 习题

1. 用 PyO3 把一个 Rust 函数(比如 fibonacci)暴露给 Python,在 Python 里压测 vs 纯 Python 实现。
2. 用 bindgen 给 sqlite3 写 binding,实现一个 `open + execute` 的最小 Rust 包装。
3. 故意在 `extern "C" fn` 里写一个 panic,看会发生什么(Linux 下可能 abort)。再用 `catch_unwind` 包好。
4. 用 napi-rs 给 Node.js 暴露一个 Rust 函数,在 Node 里 `require` 调用。
5. 把一个 Rust 计算函数编到 WASM,写个 HTML 调它,benchmark vs 纯 JS。

---

> **本章一句话总结**
>
> FFI 是 Rust 渗透到所有语言生态的能力。写得好的 Rust 库往往不是用 Rust 调用,是被 Python / Node / Web 调用——掌握这块,你的"投资回报"最高。

---

## 📝 学习记录

| 项 | 内容 |
|---|---|
| 起始日期 | |
| 完成日期 | |
| 卡点 | |
| 关键收获 | |
| 配套代码仓库链接 | |
