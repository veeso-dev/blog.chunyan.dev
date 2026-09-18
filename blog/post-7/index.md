---
date: "2026-09-18 04:00:00 +02:00"
slug: "rust-static-native-deps"
title: "Rust 项目如何内置 C/C++ 依赖"
description: "从 src crate、build.rs 到静态库打包，完整讲解如何在 Rust 项目中内置 C/C++ 依赖，并处理只生成动态库的复杂场景。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '11'
---

如果你用过
[native-tls](https://docs.rs/native-tls/latest/native_tls/)，大概已经间接接触过
vendoring。这个 crate 为 Rust 提供了一层 TLS 抽象；因为它比 rustls 出现得早，
在 Linux 上必须依赖 OpenSSL。

麻烦在于，OpenSSL 是 C 库，而 C 项目通常依靠动态链接。Rust 开发者却更愿意把
依赖静态链接进二进制：动态库会让程序换一台机器就可能无法运行，发布可执行文件也
随之变得麻烦。

`vendored` feature 正是为此准备的。开启它以后，OpenSSL 会跟随 crate 一起构建，
再静态嵌入最终的二进制。使用者当然很轻松。

![人群推着音响庆祝](./train-party.gif)

不过，我们今天能轻松享受 vendored 构建，是因为此前有人替我们吃过苦。这一回，
那个吃苦的人就是我。

## Rust vendoring 完整流程

### 项目结构

先从结构说起。假设 `foo` crate 通过 FFI 调用 C 代码，workspace 通常会拆成两层：

- `foo`：暴露 Rust API 的 Rust crate
- `foo-sys`：暴露 C API 的 Rust crate

`foo-sys` 内会有一个 `build.rs`，用指令告诉链接器到哪里寻找 C 库：

```rust
println!("cargo:rustc-link-lib=foo");
```

如果要把 `libfoo` 一起打包，还需要再建一个 `foo-src` crate。它是一个库，提供
**编译 C 库所需的函数**，也可以选择直接包含 C 库源码。

### src crate

先在 `Cargo.toml` 中加入 `cc`。这个 crate 可以让我们从 Rust 调用 C/C++ 编译器：

```toml
[dependencies]
cc = "1"
```

接着编写 `lib.rs`。它要暴露一个负责编译 C 代码的 `build` 函数，并返回两项产物：

- 库的 **include 目录**
- **静态库所在的目录**，例如 `/usr/lib/libfoo.a` 对应 `/usr/lib`

先把这些类型搭起来：

```rust
/// 构建流程生成的产物。
pub struct Artifacts {
    pub lib_dir: PathBuf,
    pub include_dir: PathBuf,
}

/// 库版本
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// 构建配置
pub struct Build {
    out_dir: Option<PathBuf>,
    target: Option<String>,
    host: Option<String>,
}

impl Build {
    /// 新建一个 [`Build`] 配置。
    pub fn new() -> Build {
        Build {
            out_dir: env::var_os("OUT_DIR").map(|s| PathBuf::from(s).join("lib-build")),
            target: env::var("TARGET").ok(),
            host: env::var("HOST").ok(),
        }
    }

    pub fn out_dir<P: AsRef<Path>>(&mut self, path: P) -> &mut Build {
        self.out_dir = Some(path.as_ref().to_path_buf());
        self
    }

    pub fn target(&mut self, target: &str) -> &mut Build {
        self.target = Some(target.to_string());
        self
    }

    pub fn host(&mut self, host: &str) -> &mut Build {
        self.host = Some(host.to_string());
        self
    }

    // ...
}
```

然后需要一个调用 `make` 的函数。DragonFly BSD、FreeBSD、OpenBSD、Solaris 和
illumos 使用 `gmake`，其他平台使用 `make`：

```rust
fn cmd_make(&self) -> Result<Command, &'static str> {
    let host = &self.host.as_ref().ok_or("HOST dir not set")?[..];
    Ok(
        if host.contains("dragonfly")
            || host.contains("freebsd")
            || host.contains("openbsd")
            || host.contains("solaris")
            || host.contains("illumos")
        {
            Command::new("gmake")
        } else {
            Command::new("make")
        },
    )
}
```

还要准备一个辅助函数，在构建阶段执行命令并报告详细错误：

```rust
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
```

有了这层基础，就可以真正着手实现构建函数。

## 编译 C 库

下面实现负责编译库的 `build` 函数。这里分两种情况。

第一种最省心：C 项目本身只需几条命令，就能生成静态库和 include 目录。第二种则
折磨得多：项目规模巨大，`make` 偏偏不生成静态库。没错，说的就是 **Samba**。

### 顺利的 C 编译流程

理想情况下，下面三条命令就能得到静态库：

```sh
./configure
make
make install DESTDIR=$(pwd)/out
```

构建完成后，静态库位于 `out/usr/local/lib/libfoo.a`，include 目录则是
`out/usr/local/include`。

![跟着节奏摇头的猫](./catjam-cat.gif)

这种情况下，构建函数可以这样写：

```rust
pub fn try_build(&mut self) -> Result<Artifacts, String> {
    let target = &self.target.as_ref().ok_or("TARGET dir not set")?[..];
    let host = &self.host.as_ref().ok_or("HOST dir not set")?[..];
    let os = Self::os(target)?;
    let out_dir = self.out_dir.as_ref().ok_or("OUT_DIR not set")?;
    let build_dir = out_dir.join("build");

    if build_dir.exists() {
        fs::remove_dir_all(&build_dir).map_err(|e| format!("build_dir: {e}"))?;
    }

    let inner_dir = build_dir.join("src");
    fs::create_dir_all(&inner_dir).map_err(|e| format!("{}: {e}", inner_dir.display()))?;

    // 在这里取得源码目录；我强烈建议在此处克隆 Git 仓库
    // 后文会进一步说明
    let src_dir = todo!();

    // 初始化 cc
    let mut cc = cc::Build::new();
    cc.target(target).host(host).warnings(false).opt_level(2);
    let compiler = cc.get_compiler();
    let mut cc_env = compiler.cc_env();
    if cc_env.is_empty() {
        cc_env = compiler.path().to_path_buf().into_os_string();
    }

    // 取得 ar
    let ar = cc.get_archiver();

    // 配置
    let mut configure = Command::new("sh");
    configure.arg("./configure");
    // 可以在这里添加 configure 参数
    configure.arg("--disable-python");
    configure.arg("--without-systemd");
    configure.arg("--without-ldb-lmdb");
    configure.arg("--without-ad-dc");
    configure.arg("--bundled-libraries=ALL");
    configure.arg("--without-libarchive");
    configure.env("CC", cc_env);
    configure.env("AR", ar.get_program());

    let ranlib = cc.get_ranlib();
    let mut args = vec![ranlib.get_program()];
    args.extend(ranlib.get_args());
    configure.env("RANLIB", args.join(OsStr::new(" ")));

    configure.current_dir(&src_dir);
    // 执行 configure
    self.run_command(configure, "configuring foo build")?;

    // 执行 make
    let make = self.cmd_make()?;
    make.current_dir(&src_dir);
    self.run_command(make, "building foo")?;
    // 创建输出目录
    let out_dir = src_dir.join("out");
    fs::create_dir_all(&out_dir).map_err(|e| format!("{}: {e}", out_dir.display()))?;
    // 安装
    let install = Command::new("make");
    install.arg("install");
    install.arg(format!("DESTDIR={}", out_dir.display()));
    install.current_dir(&src_dir);
    self.run_command(install, "installing foo")?;

    // 静态库目录 -> /usr/local/lib
    let lib_dir = out_dir.join("usr").join("local").join("lib");
    // include 目录 -> /usr/local/include
    let include_dir = out_dir.join("usr").join("local").join("include");

    Ok(Artifacts {
        lib_dir,
        include_dir,
    })
}
```

不管看起来多不可思议，只要这段简单的函数跑通，你就能拿到 C 代码对应的静态库和
include 目录。可惜我处理 Samba 时没这么幸运。如果你的项目也不肯配合，就只能继续
往下看。

### 折磨人的 C 编译流程

假设手里是一个庞大的 C 项目，它出于某种原因**完全不生成静态库，只生成动态库**。
这时只能自己组装静态库。过程很长，但实际并没有想象中那么难。

![露出勉强笑容的人](./hide-the-pain-harold.gif)

`configure` 阶段通常与上一种情况一样，变化主要发生在 `make` 阶段。如果 `make`
负责生成 shared object，**这条命令仍然必须执行**。

接下来要找出构建该 shared object 所需的**全部目标文件**。具体做法不止一种，
有人会建议使用 `objdump` 或 `ldd`，但它们经常解决不了问题，所以这里没法给出
唯一方案。

实在找不到更好的办法，可以给 `make` 加上 `-V=1`，把输出重定向到文件，再用脚本
解析日志，从中提取**目标文件列表**。下面就是一个可用的脚本：

```python
filename = argv[1]

with open(filename, "r") as f:
    lines = f.readlines()

    objects = []

    for line in lines:
        # 判断是否正在构建库
        if "-Wl,--as-needed" in line:
            # 以逗号分隔
            tokens = line.split(",")
            for token in tokens:
                # 去掉引号
                token = token.strip().strip("'").strip('"')
                if token.endswith(".o"):
                    # 只保留 .c 路径
                    end = token.find(".c")
                    token = token[: end + 2]
                    if token not in objects:
                        objects.append(token)

    for obj in objects:
        print(f'"{obj}",')
```

先向各位 Rustacean 为这段 Python 道个歉。不过处理这类任务时，我确实会用它。

拿到 `make` 使用的目标文件列表后，组装静态库需要的材料就齐了：

```rust
// 要参与构建的目标文件列表
const OBJECTS: &[&str] = &[/* ... */];

pub fn try_build(&mut self) -> Result<Artifacts, String> {
    let target = &self.target.as_ref().ok_or("TARGET dir not set")?[..];
    let host = &self.host.as_ref().ok_or("HOST dir not set")?[..];
    let os = Self::os(target)?;
    let out_dir = self.out_dir.as_ref().ok_or("OUT_DIR not set")?;
    let build_dir = out_dir.join("build");

    if build_dir.exists() {
        fs::remove_dir_all(&build_dir).map_err(|e| format!("build_dir: {e}"))?;
    }

    let inner_dir = build_dir.join("src");
    fs::create_dir_all(&inner_dir).map_err(|e| format!("{}: {e}", inner_dir.display()))?;

    // 把源码放入 `inner_dir`
    let src_dir = todo!();

    // 初始化 cc
    let mut cc = cc::Build::new();
    cc.target(target).host(host).warnings(false).opt_level(2);
    let compiler = cc.get_compiler();
    let mut cc_env = compiler.cc_env();
    if cc_env.is_empty() {
        cc_env = compiler.path().to_path_buf().into_os_string();
    }

    // 取得 ar
    let ar = cc.get_archiver();

    // 配置
    let mut configure = Command::new("sh");
    configure.arg("./configure");
    configure.arg("--disable-python");
    configure.arg("--without-systemd");
    configure.arg("--without-ldb-lmdb");
    configure.arg("--without-ad-dc");
    configure.arg("--bundled-libraries=ALL");
    configure.arg("--without-libarchive");
    #[cfg(target_os = "macos")]
    configure.arg("--without-acl-support"); // macOS 不支持
    configure.env("CC", cc_env);
    configure.env("AR", ar.get_program());

    let ranlib = cc.get_ranlib();
    let mut args = vec![ranlib.get_program()];
    args.extend(ranlib.get_args());
    configure.env("RANLIB", args.join(OsStr::new(" ")));
    configure.current_dir(&src_dir);

    // 执行 configure
    self.run_command(configure, "configuring foo build")?;

    // 执行 make
    let make = self.cmd_make()?;
    make.current_dir(&src_dir);
    self.run_command(make, "building foo")?;

    // 使用 AR 构建静态库
    let mut build_static = cc.get_archiver();
    build_static.arg("rcs");
    build_static.arg("libfoo.a");
    build_static.current_dir(&src_dir);

    // 加入目标文件
    for object in OBJECTS {
        let path = inner_dir.join(object);
        build_static.arg(path.display().to_string());
    }

    // 执行 ar
    self.run_command(build_static, "building static library")?;

    // include 目录 -> ??? include/
    let include_dir = src_dir.join("include");

    Ok(Artifacts {
        lib_dir: src_dir,
        include_dir,
    })
}
```

最难的部分到这里就结束了。剩下的工作，是给 `foo` 和 `foo-sys` 加上 `vendored`
feature，并在 `foo-sys` 中运行构建脚本。

## 运行构建脚本

先给 `foo-sys` 增加 `vendored` feature：

```toml
[build-dependencies]
cc = { version = "1", optional = true }
foo-src = { version = "4.22.0", path = "../foo-src", optional = true }

[features]
vendored = ["dep:cc", "dep:foo-src"]
```

然后在 `build.rs` 中根据 feature 做选择：启用时走 vendored 构建，否则照常链接
动态库。

```rust
fn main() {
    #[cfg(feature = "vendored")]
    {
        build_vendored();
    }
    #[cfg(not(feature = "vendored"))]
    {
        build_normal();
    }
}

fn build_normal() {
    println!("cargo:rustc-link-lib=foo");
}

#[cfg(feature = "vendored")]
fn build_vendored() {
    let mut build = foo_src::Build::new();

    println!("building vendored foo library... this may take several minutes");
    let artifacts = build.build();
    println!("cargo:vendored=1");
    println!(
        "cargo:root={}",
        artifacts.lib_dir.parent().unwrap().display()
    );

    if !artifacts.lib_dir.exists() {
        panic!(
            "foo library does not exist: {}",
            artifacts.lib_dir.display()
        );
    }
    if !artifacts.include_dir.exists() {
        panic!(
            "foo include directory does not exist: {}",
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

最后再给 `foo` crate 加上对应的 feature：

```toml
[features]
vendored = ["foo-sys/vendored"]
```

到此就完成了。现在使用 `vendored` feature 构建项目，C 库会被静态链接进二进制。
祝你编译顺利。

![画面上写着段错误的鹦鹉](./segfault.gif)

## 补充：怎样包含源码

把 C 代码放进 `-src` crate，通常有两种选择：

1. 使用 **Git submodule**
2. 在构建过程中**克隆 Git 仓库**

`openssl-src` 采用第一种方式，但它并非总是可行。我处理 Samba 时就用不了
submodule，因为 Samba 仓库太大，crates.io 会直接以体积超限为由拒收这个 crate。

如果你也遇到这种情况，可以在 `lib.rs` 中克隆仓库。下面仍以 Samba 为例：

```toml
[dependencies]
git2 = "0.20"
```

```rust
/// 将 Samba 仓库克隆到指定路径并检出对应标签
fn clone_samba(p: &Path) -> Result<(), String> {
    let repo_url = "https://git.samba.org/samba.git";
    let repo = git2::Repository::clone(repo_url, p).map_err(|e| format!("cloning samba: {e}"))?;

    // 检出标签 "samba-4.22.0"
    let tag = format!("samba-{}", version());
    let obj = repo
        .revparse_single(&tag)
        .map_err(|e| format!("revparse_single: {e}"))?;

    let commit = obj
        .peel_to_commit()
        .map_err(|e| format!("peel_to_commit: {e}"))?;

    repo.checkout_tree(&obj, None)
        .map_err(|e| format!("checkout_tree: {e}"))?;

    repo.set_head_detached(commit.id())
        .map_err(|e| format!("set_head_detached: {e}"))?;

    Ok(())
}
```

在这个例子中，`src_dir` 就是传给 `clone_samba` 的路径。

## 补充：链接静态库的依赖

Samba 这类项目还会依赖 `libtalloc`、`libtevent`、`libtdb` 等其他库。这时，静态库
也必须把这些依赖链接进来。

因此，需要在 `foo-sys` 的 `build.rs` 中追加相应的链接指令：

```rust
fn build_vendored() {
    // ...
    add_library("icuuc", "icu4c");
    add_library("gnutls", "gnutls");
    add_library("bsd", "libbsd");
    add_library("resolv", "libresolv");
    // ...
}

fn add_library(lib: &str, brew_name: &str) {
    // 使用 pkg-config 查找库，并尝试静态链接
    match pkg_config::Config::new()
        .statik(true)
        .cargo_metadata(true)
        .probe(lib)
    {
        Ok(_) => {
            if cfg!(target_os = "macos") {
                if cfg!(target_arch = "aarch64") {
                    println!("cargo:rustc-link-search=/opt/homebrew/opt/{brew_name}/lib");
                } else if cfg!(target_arch = "x86_64") {
                    println!("cargo:rustc-link-search=/usr/local/Homebrew/opt/{brew_name}/lib");
                }
                println!("cargo:rustc-link-lib={lib}");
            }
        }
        Err(_) => {
            println!("{lib} was not found with pkg_config; trying with LD_LIBRARY_PATH; but you may need to install it manually");
            // 碰碰运气，尝试动态链接
            println!("cargo:rustc-link-lib={lib}");
        }
    };
}
```

这里用 `pkg-config` 查找依赖，并优先尝试静态链接；如果失败，就退回动态链接。

## 补充：加载内置的 shared object

给 libsmbclient 做 vendoring 时，我一度因为造不出静态库而准备放弃，于是开始考虑：
能不能把 shared object 本身打包进去？

如果可执行文件链接了一个 shared object，运行它的系统上必须存在同一个 shared
object，二进制的可移植性自然会大幅下降。我的想法是，先把 shared object 放在
项目内的固定路径，通过 `include_bytes!()` 把它的字节嵌入可执行文件，再提供一个
初始化函数，用
[libloading](https://docs.rs/libloading/latest/libloading/index.html) 从这些字节加载它。

大致会是这样：

```rust
const LIBSMBCLIENT: &[u8] = include_bytes!("libsmbclient.so");

fn init_libsmbclient() {
    let lib = tempfile::NamedTempFile::new().unwrap();
    lib.write_all(LIBSMBCLIENT).unwrap();
    let lib = libloading::Library::new(lib.path()).unwrap();
}
```

或者采用类似的写法。写下最初版本时，我并不知道它究竟能不能工作，只打算以后再试。

后来我真的验证了：它可以工作。具体过程可以继续阅读
[在 Rust 二进制中嵌入共享库并动态加载](/blog/rust-bundled-shared-library/)。

![实验人员把液体倒入容器](./science-lab.gif)

## 总结

希望这份指南能帮你在 Rust 项目中内置 C/C++ 依赖，也希望以后有人需要完整做法时，
可以把它当作参考，甚至链接或收录到某本 Rust 图书中。转载或收录没有问题，只要保留
对原作者的署名。

### 参考资料

- [libloading](https://docs.rs/libloading/latest/libloading/index.html)
- [openssl-sys 构建脚本](https://github.com/sfackler/rust-openssl/blob/master/openssl-sys/build/main.rs#L47)
- [openssl-sys vendored 构建脚本](https://github.com/sfackler/rust-openssl/blob/master/openssl-sys/build/find_vendored.rs)
- [pavao](https://github.com/veeso/pavao)
