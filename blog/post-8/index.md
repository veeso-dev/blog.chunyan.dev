---
date: "2026-09-18 05:00:00 +02:00"
slug: "rust-bundled-shared-library"
title: "在 Rust 二进制中嵌入共享库并动态加载"
description: "用 CMake、include_bytes! 和 libloading，把 C 共享库嵌入 Rust 二进制，并在运行时提取和加载。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '10'
---

## 为什么要这样做

![奥巴马摊手问为什么](./but-why.gif)

前一篇文章里，我写过如何在 Rust 项目中
[内置 C/C++ 依赖](/blog/rust-static-native-deps/)：
先构建静态库，再把它链接进 Rust 库。

那次处理 `smbclient` 时，拿到可用的静态库非常困难。我当时其实想过本文要试的
方案，却不确定它是否可行。Samba 又是个庞大的项目，实在不适合拿来做第一次实验。

现在换成一个足够简单的 C 库，我们终于可以把思路走完。先说结论：**确实能用。**

下面就来看看，怎样把共享对象（shared object）直接嵌进 Rust 二进制，
并在程序运行时加载它。

## 准备项目

先新建一个 Rust 库，并加入实验需要的依赖：

```toml
[dependencies]
libc = "0.2"

[build-dependencies]
cc = "1"
```

然后写一个很小的 C 库，用它验证共享库能否被动态加载。

## C 库

这个库只做一件事：**把两个整数相加**。

```c
// libfoo.h

#ifndef LIBFOO_H
#define LIBFOO_H

int sum(int x, int y);

#endif // LIBFOO_H
```

```c
// libfoo.c

#include <libfoo.h>

int sum(int x, int y)
{
    return x + y;
}
```

接下来用 CMake 同时构建共享库和静态库：

```cmake
cmake_minimum_required(VERSION 3.10)

project(libfoo C)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

include_directories(include)

set(SOURCES src/libfoo.c)

add_library(foo_shared SHARED ${SOURCES})
set_target_properties(foo_shared PROPERTIES OUTPUT_NAME "foo")
target_include_directories(foo_shared PUBLIC include)

add_library(foo_static STATIC ${SOURCES})
set_target_properties(foo_static PROPERTIES OUTPUT_NAME "foo")
target_include_directories(foo_static PUBLIC include)
```

## 为 Rust 编写绑定

在 Rust 库中新建 `libfoo_sys.rs` 模块：

```rust
use libc::c_int;

#[link(name = "foo")]
unsafe extern "C" {
    pub unsafe fn sum(x: c_int, y: c_int) -> c_int;
}
```

再从 `lib.rs` 暴露 `sum` 函数：

```rust
mod libfoo_sys;

pub fn sum(x: i32, y: i32) -> i32 {
    unsafe { libfoo_sys::sum(x, y) }
}
```

绑定已经齐了，现在可以构建并测试这个库。

## 从 Rust 构建 libfoo

我们在 `build.rs` 中负责构建 C 库。先准备以下代码：

```rust
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};

struct Artifacts {
    include_dir: PathBuf,
    lib_dir: PathBuf,
}

struct Build {
    out_dir: Option<PathBuf>,
    host: Option<String>,
    target: Option<String>,
}

impl Default for Build {
    fn default() -> Self {
        Self {
            out_dir: env::var_os("OUT_DIR").map(|s| PathBuf::from(s).join("foo-build")),
            host: env::var("HOST").ok(),
            target: env::var("TARGET").ok(),
        }
    }
}

impl Build {
    fn build(&self) -> Result<Artifacts, String> {
        let target = &self.target.as_ref().ok_or("TARGET dir not set")?[..];
        let host = &self.host.as_ref().ok_or("HOST dir not set")?[..];
        let out_dir = self.out_dir.as_ref().ok_or("OUT_DIR not set")?;
        let build_dir = out_dir.join("build");

        if build_dir.exists() {
            fs::remove_dir_all(&build_dir).map_err(|e| format!("build_dir: {e}"))?;
        }

        let inner_dir = build_dir.join("libfoo");
        fs::create_dir_all(&inner_dir).map_err(|e| format!("inner_dir: {e}"))?;

        // 把 libfoo/ 复制到 build_dir
        cp_r(&Self::source_dir(), &inner_dir)?;

        // 初始化 cc
        let mut cc = cc::Build::new();
        cc.target(target).host(host).warnings(false).opt_level(2);
        let compiler = cc.get_compiler();
        let mut cc_env = compiler.cc_env();
        if cc_env.is_empty() {
            cc_env = compiler.path().to_path_buf().into_os_string();
        }

        // 构建目录
        let lib_build_dir = inner_dir.join("build");
        // 如果 build/ 目录已经存在，就先删除它
        if lib_build_dir.exists() {
            fs::remove_dir_all(&lib_build_dir).map_err(|e| format!("lib_build_dir: {e}"))?;
        }
        fs::create_dir_all(&lib_build_dir).map_err(|e| format!("lib_build_dir: {e}"))?;

        // 运行 cmake
        let mut cmake = Command::new("cmake");
        cmake.arg("..");
        cmake.current_dir(&lib_build_dir);
        cmake.env("CC", cc_env);

        // 执行命令
        self.run_command(cmake, "cmake")?;

        // 运行 make
        let mut make = Command::new("make");
        make.current_dir(&lib_build_dir);
        self.run_command(make, "make")?;

        // 取得库和头文件目录
        let include_dir = inner_dir.join("include");
        let lib_dir = lib_build_dir.join("lib");

        Ok(Artifacts {
            include_dir,
            lib_dir,
        })
    }

    fn source_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("libfoo")
    }

    #[track_caller]
    fn run_command(&self, mut command: Command, desc: &str) -> Result<(), String> {
        println!("running {:?}", command);
        let status = command.status();

        let verbose_error = match status {
            Ok(status) if status.success() => return Ok(()),
            Ok(status) => format!(
                "'{exe}' reported failure with {status}",
                exe = command.get_program().to_string_lossy()
            ),
            Err(failed) => match failed.kind() {
                std::io::ErrorKind::NotFound => format!(
                    "Command '{exe}' not found. Is {exe} installed?",
                    exe = command.get_program().to_string_lossy()
                ),
                _ => format!(
                    "Could not run '{exe}', because {failed}",
                    exe = command.get_program().to_string_lossy()
                ),
            },
        };
        println!("cargo:warning={desc}: {verbose_error}");
        Err(format!(
            "Error {desc}:
    {verbose_error}
    Command failed: {command:?}"
        ))
    }
}

fn cp_r(src: &Path, dst: &Path) -> Result<(), String> {
    for f in fs::read_dir(src).map_err(|e| format!("{}: {e}", src.display()))? {
        let f = match f {
            Ok(f) => f,
            _ => continue,
        };
        let path = f.path();
        let name = path
            .file_name()
            .ok_or_else(|| format!("bad dir {}", src.display()))?;

        // 跳过 Git 元数据；它过去引发过问题（#26），构建本来也不需要它
        if name.to_str() == Some(".git") {
            continue;
        }

        let dst = dst.join(name);
        let ty = f.file_type().map_err(|e| e.to_string())?;
        if ty.is_dir() {
            fs::create_dir_all(&dst).map_err(|e| e.to_string())?;
            cp_r(&path, &dst)?;
        } else if ty.is_symlink() && path.iter().any(|p| p == "cloudflare-quiche") {
            // 构建时不需要
            continue;
        } else {
            let _ = fs::remove_file(&dst);
            if let Err(e) = fs::copy(&path, &dst) {
                return Err(format!(
                    "failed to copy '{}' to '{}': {e}",
                    path.display(),
                    dst.display()
                ));
            }
        }
    }
    Ok(())
}
```

暂时先在 `build.rs` 中静态链接 libfoo：

```rust
fn main() {
    build_and_link_libfoo();
}

fn build_and_link_libfoo() {
    println!("building vendored foo library...");
    let artifacts = Build::default().build().expect("build failed");

    println!("cargo:vendored=1");
    println!(
        "cargo:root={}",
        artifacts.lib_dir.parent().unwrap().display()
    );

    if !artifacts.lib_dir.exists() {
        panic!("libfoo lib does not exist: {}", artifacts.lib_dir.display());
    }
    if !artifacts.include_dir.exists() {
        panic!(
            "libfoo include directory does not exist: {}",
            artifacts.include_dir.display()
        );
    }

    println!(
        "cargo:rustc-link-search=native={}",
        artifacts.lib_dir.display()
    );
    println!("cargo:include={}", artifacts.include_dir.display());
    println!("cargo:rustc-link-lib=static=foo");
}
```

## 先确认静态链接可用

在 `lib.rs` 中加一个简单测试：

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        let result = sum(2, 2);
        assert_eq!(result, 4);
    }
}
```

```shell
cargo test
```

测试通过，说明**构建脚本可以正常工作**，Rust 代码也已经能够使用这个 C 库。

## 把共享对象嵌入二进制

接下来才是实验的重点。我想做三件事：

1. **移除静态链接**。假设依赖项目十分庞大，根本不生成静态库，而我们也没找到
   构建它的办法，Samba 就是这种情况。
2. **构建共享对象**，再用 `include_bytes!` 宏把它嵌进最终二进制。
3. **在运行时加载共享对象**并调用其中的函数。

第一步，删掉构建脚本里的静态链接逻辑：

```rust
// 这里只保留 libfoo 的构建逻辑

fn build_libfoo() {
    println!("building vendored foo library...");
    Build::default().build().expect("build failed");
}
```

现在运行 `cargo test`，由于 libfoo 不再被链接，测试会失败：

```txt
mold: fatal: library not found: foo
```

这正是我们想要的结果。

然后，把 `libfoo.so` 复制到清单文件所在目录：

```rust
fn build_libfoo() {
    println!("building vendored foo library...");
    let artifacts = Build::default().build().expect("build failed");

    let shared_object = artifacts.lib_dir.join("libfoo.so");
    let dest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    // 把共享对象复制到 dest_dir
    fs::copy(&shared_object, dest_dir.join("libfoo.so"))
        .expect("failed to copy shared object to dest_dir");
}
```

这段代码会完成复制。接着在 `.gitignore` 中忽略生成的文件：

```txt
/libfoo.so
```

现在可以把它嵌进最终二进制：

```rust
const LIBFOO_SO: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/libfoo.so"));
```

剩下的问题，是怎样在运行时加载这份共享对象。

这里还需要两个依赖：`tempfile` 用来创建临时文件，`libloading` 负责加载共享对象。

```toml
[dependencies]
libloading = "0.8"
tempfile = "3"
```

回到 `libfoo_sys.rs`。我们先分别为临时文件和库创建静态 `OnceLock`：

```rust
static LIBFOO_SO_FILE: OnceLock<NamedTempFile> = OnceLock::new();
static LIBFOO_LIB: OnceLock<Library> = OnceLock::new();
```

然后写一个 `init_libfoo` 函数。它创建临时文件，并把嵌入的共享对象写进去：

```rust
fn init_libfoo() {
    LIBFOO_SO_FILE.get_or_init(|| {
        let mut file = NamedTempFile::new().expect("failed to create temp file");
        file.write_all(LIBFOO_SO)
            .expect("failed to write to temp file");
        file
    });
}
```

最后在 `init_libfoo` 内加载 `libfoo.so`，完整实现如下：

```rust
pub unsafe fn init_libfoo() -> &'static Library {
    let libfoo_file = LIBFOO_SO_FILE.get_or_init(|| {
        let mut file = NamedTempFile::new().expect("failed to create temp file");
        file.write_all(LIBFOO_SO)
            .expect("failed to write to temp file");
        file
    });

    LIBFOO_LIB.get_or_init(|| unsafe {
        Library::new(libfoo_file.path()).expect("failed to load libfoo.so")
    })
}
```

还要改变 `sum` 的行为，让它从库中加载同名符号：

```rust
//#[link(name = "foo")]
//unsafe extern "C" {
//    pub unsafe fn sum(x: c_int, y: c_int) -> c_int;
//}

pub unsafe fn sum(x: c_int, y: c_int) -> c_int {
    let libfoo = unsafe { init_libfoo() };

    let func = unsafe { libfoo.get::<unsafe extern "C" fn(c_int, c_int) -> c_int>(b"sum\0") }
        .expect("failed to get function");

    unsafe { func(x, y) }
}
```

再次运行 `cargo test`，这次测试会通过。

![吉恩·怀尔德露出惊喜表情](./gene-wilder.gif)

## 是否始终内置依赖

当然，并不是所有使用者都希望项目始终内置这份 C 依赖。我们可以增加一个
`vendored` feature，让使用者自己选择：

```toml
[package]
name = "embedded-so"
version = "0.1.0"
edition = "2024"
build = "build.rs"

[dependencies]
libc = "0.2"
libloading = { version = "0.8", optional = true }
tempfile = { version = "3", optional = true }

[build-dependencies]
cc = { version = "1", optional = true }

[features]
default = ["vendored"]
vendored = ["dep:cc", "dep:libloading", "dep:tempfile"]
```

随后给构建脚本加上 feature gate：

```rust
#[cfg(feature = "vendored")]
mod libfoo;

fn main() {
    #[cfg(feature = "vendored")]
    libfoo::build_libfoo();
}
```

再把其他构建代码移到 `libfoo` 模块中。

最后，为 `libfoo_sys.rs` 加上 feature gate：

```rust
#[cfg(not(feature = "vendored"))]
mod dylib;
#[cfg(feature = "vendored")]
mod vendored;

#[cfg(not(feature = "vendored"))]
pub use self::dylib::*;
#[cfg(feature = "vendored")]
pub use self::vendored::*;
```

新建 `vendored.rs`：

```rust
use std::{io::Write as _, sync::OnceLock};

use libc::c_int;
use libloading::Library;
use tempfile::NamedTempFile;

const LIBFOO_SO: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/libfoo.so"));
static LIBFOO_SO_FILE: OnceLock<NamedTempFile> = OnceLock::new();
static LIBFOO_LIB: OnceLock<Library> = OnceLock::new();

unsafe fn init_libfoo() -> &'static Library {
    let libfoo_file = LIBFOO_SO_FILE.get_or_init(|| {
        let mut file = NamedTempFile::new().expect("failed to create temp file");
        file.write_all(LIBFOO_SO)
            .expect("failed to write to temp file");
        file
    });

    LIBFOO_LIB.get_or_init(|| unsafe {
        Library::new(libfoo_file.path()).expect("failed to load libfoo.so")
    })
}

pub unsafe fn sum(x: c_int, y: c_int) -> c_int {
    let libfoo = unsafe { init_libfoo() };

    let func = unsafe { libfoo.get::<unsafe extern "C" fn(c_int, c_int) -> c_int>(b"sum\0") }
        .expect("failed to get function");

    unsafe { func(x, y) }
}
```

以及 `dylib.rs`：

```rust
use libc::c_int;

#[link(name = "foo")]
unsafe extern "C" {
    pub unsafe fn sum(x: c_int, y: c_int) -> c_int;
}
```

这样两条路径就完全分开了：`dylib` 和 `vendored` 都能独立工作。

## 用宏消除重复的 C 符号声明

到这里你可能已经注意到：`vendored` 和动态链接两种路径都要声明一次 C 符号。
这份重复代码可以交给宏来生成。

先把 `vendored.rs` 精简为下面的内容：

```rust
use std::io::Write as _;
use std::sync::OnceLock;

use libloading::Library;
use tempfile::NamedTempFile;

const LIBFOO_SO: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/libfoo.so"));
static LIBFOO_SO_FILE: OnceLock<NamedTempFile> = OnceLock::new();
static LIBFOO_LIB: OnceLock<Library> = OnceLock::new();

pub unsafe fn init_libfoo() -> &'static Library {
    let libfoo_file = LIBFOO_SO_FILE.get_or_init(|| {
        let mut file = NamedTempFile::new().expect("failed to create temp file");
        file.write_all(LIBFOO_SO)
            .expect("failed to write to temp file");
        file
    });

    // 使用 libloading 加载
    LIBFOO_LIB.get_or_init(|| unsafe {
        Library::new(libfoo_file.path()).expect("failed to load libfoo.so")
    })
}
```

把 `sum` 函数和 `dylib.rs` 都删掉。然后在 `libfoo_sys.rs` 里定义一个生成导出项的宏：

```rust
#[cfg(feature = "vendored")]
mod vendored;

#[cfg(feature = "vendored")]
pub use self::vendored::*;

#[cfg(not(feature = "vendored"))]
macro_rules! clib {
    ($name:ident
        (
            $( $arg_name:ident : $arg_ty:ty ),*
            $(,)?
        )
        -> $ret:ty) => {
            #[link(name = "foo")]
            unsafe extern "C" {
                pub fn $name( $( $arg_name : $arg_ty ),* ) -> $ret;
            }

    };
}

#[cfg(feature = "vendored")]
macro_rules! clib {
    ($name:ident
        (
            $( $arg_name:ident : $arg_ty:ty ),*
            $(,)?
        )
        -> $ret:ty) => {
            pub unsafe fn $name( $( $arg_name : $arg_ty ),* ) -> $ret {
                let libfoo = unsafe { init_libfoo() };

                let func = unsafe { libfoo.get::<unsafe extern "C" fn($( $arg_ty ),*) -> $ret>(concat!(stringify!($name), "\0").as_bytes()) }
                    .expect("failed to load function");

                unsafe { func( $( $arg_name ),* ) }
            }
    };
}
```

现在声明 C 函数 `sum` 只需要一行：

```rust
clib!(sum(x: c_int, y: c_int) -> c_int);
```

通过这个宏，其余要在 Rust 中调用的 C 函数也能用同样的方式轻松声明。

![戴墨镜的孩子露出得意表情](./cool-kid.gif)

## 结语

对我来说，这是一次很有意思的实验，而且结果确实不错。

写完上一篇
[Rust 项目如何内置 C/C++ 依赖](/blog/rust-static-native-deps/)
之后，我一直想验证这个方案。面对一个不生成静态库的庞大项目时，
把共享对象嵌入二进制，或许能绕开静态库难以构建的问题。

那么，我是否建议不计代价地构建静态库，还是直接采用本文方案？
**我没有统一答案，它取决于项目和具体场景。**

Samba 当时确实把我折腾得够呛。我始终构建不出静态库，如果那时知道这个办法，
我很可能会用它。后来我还是找到一种相当粗暴的方式生成静态库，最终也沿用了
那条路。

但我相信，在那个场景中直接嵌入共享对象同样可行。所以，我依然无法断言哪一种
方案更好。

至少，**它值得作为一个备选项**。我不知道 Rust 社区此前是否讨论过这种做法，
自己也从未见过类似实现。不管怎样，这次实验值得一试，我也很高兴把它跑通了。

### 参考资料

- [embedded-so 示例项目](https://github.com/veeso/embedded-so)
