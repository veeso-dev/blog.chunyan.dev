---
date: "2026-09-22 16:33:19 +02:00"
slug: "fusibile-remote-filesystem-mount"
title: "用 Fusibile 把远程文件系统挂载到本地"
description: "介绍如何用 Rust、RemoteFs 和 FUSE 把 SFTP、S3、WebDAV、Kubernetes 等远程存储挂载成本地文件系统，以及 UID、GID 和权限映射中的实际问题。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '6'
---

SFTP 客户端可以下载文件，S3 客户端可以列出对象，WebDAV 客户端可以创建
目录。但如果我只想运行下面这条命令呢？

```bash
ls ~/remote
```

我希望这个目录背后可以是 SFTP 服务器、S3 存储桶，甚至 Kubernetes Pod，
同时又能像普通本地目录一样使用。

这正是 [Fusibile](https://github.com/remotefs-rs/remotefs-rs-fuse) 要解决的
问题。它能把远程文件系统挂载成本地卷，目前支持 SFTP、SCP、FTP、SMB、
WebDAV、AWS S3、Google Cloud Storage 和 Kubernetes。

不过，从协议客户端走到真正可挂载的文件系统，中间还隔着好几层。

## 从 RemoteFs 开始

很多年前，我开始开发
[RemoteFs](https://github.com/remotefs-rs/remotefs-rs)。这是一个 Rust 库，
目标是为通过网络协议访问的文件系统提供统一接口。

你可以把它理解成远程存储版本的 `std::fs`：文件可能位于 SFTP 或 FTP
服务器上，也可能放在 S3 存储桶里，但调用方不必为每种协议重新学习一套
操作方式。

整个抽象的核心是 `RemoteFs` trait：

```rust
/// 由协议支持的远程文件系统所遵循的阻塞式接口。
pub trait RemoteFs: Send + Sync {
    /// 连接远程服务器并完成客户端认证。
    ///
    /// # Errors
    ///
    /// 如果建立连接或认证失败，返回相应错误。
    fn connect(&mut self) -> RemoteResult<()>;

    /// 断开与远程服务器的连接。
    ///
    /// # Errors
    ///
    /// 尚未建立连接时返回 [`crate::fs::RemoteErrorType::NotConnected`]。
    fn disconnect(&mut self) -> RemoteResult<()>;

    /// 返回缓存的连接状态，不主动探测传输层。
    fn is_connected(&self) -> bool;

    /// 返回此客户端原生支持的操作。
    fn capabilities(&self) -> Capabilities;

    /// 列出绝对目录路径下的直接子项。
    ///
    /// # Errors
    ///
    /// 路径为相对路径时返回 [`crate::fs::RemoteErrorType::InvalidPath`]；
    /// 无法列出目录时返回后端的查询错误。
    fn list_dir(&self, path: &Path) -> RemoteResult<Vec<File>>;

    /// 返回绝对路径的元数据，不跟随符号链接。
    ///
    /// # Errors
    ///
    /// 路径为相对路径时返回 [`crate::fs::RemoteErrorType::InvalidPath`]；
    /// 无法检查条目时返回后端的查询错误。
    fn stat(&self, path: &Path) -> RemoteResult<File>;

    /// 判断绝对路径是否存在。
    ///
    /// 条目不存在时返回 `Ok(false)`；路径无效或传输失败时返回错误。
    fn exists(&self, path: &Path) -> RemoteResult<bool>;

    /// 修改绝对路径中指定的元数据字段。
    ///
    /// # Errors
    ///
    /// 后端不支持修改元数据时返回
    /// [`crate::fs::RemoteErrorType::UnsupportedFeature`]。
    fn set_metadata(&self, path: &Path, metadata: &SetMetadata) -> RemoteResult<()>;

    /// 在绝对路径下创建目录。
    ///
    /// 后端不支持 POSIX 权限时忽略可选的 mode。
    fn create_dir(&self, path: &Path, mode: Option<UnixPex>) -> RemoteResult<()>;

    /// 删除文件或符号链接。
    fn remove_file(&self, path: &Path) -> RemoteResult<()>;

    /// 删除空目录。
    fn remove_dir(&self, path: &Path) -> RemoteResult<()>;

    /// 把绝对路径 `src` 重命名为绝对路径 `dest`。
    fn rename(&self, src: &Path, dest: &Path) -> RemoteResult<()>;

    /// 把绝对路径 `src` 复制到绝对路径 `dest`。
    fn copy(&self, src: &Path, dest: &Path) -> RemoteResult<()>;

    /// 在 `path` 创建指向绝对路径 `target` 的符号链接。
    fn symlink(&self, path: &Path, target: &Path) -> RemoteResult<()>;

    /// 打开绝对文件路径，按指定范围读取。
    fn open(&self, path: &Path, opts: &ReadOptions) -> RemoteResult<ReadStream>;

    /// 创建或清空绝对文件路径，以便写入。
    fn create(&self, path: &Path, opts: &WriteOptions) -> RemoteResult<WriteStream>;

    /// 打开或创建绝对文件路径，以便追加内容。
    fn append(&self, path: &Path, opts: &WriteOptions) -> RemoteResult<WriteStream>;
}
```

`remotefs` crate 提供 trait 和相关类型，各个独立 crate 则负责实现具体协议的
客户端。截至 2026 年 9 月，已经有 SCP、SFTP、FTP、SMB、AWS S3、
Google Cloud Storage、Kubernetes（单 Pod 和多 Pod）以及 WebDAV 客户端。

RemoteFs 也提供异步的 `AsyncRemoteFs` API，Fusibile 目前使用的正是这套
接口。

统一接口的好处很直接：应用程序初始化客户端之后，不必再关心底层协议。无论文件
实际存在哪里，列目录和打开文件都使用同一套调用方式。

## API 像文件系统，却还不是真正的文件系统

RemoteFs 已经能很好地操作远程文件，但一些用户仍然觉得它缺少本地文件系统与
远程文件系统之间真正透明的交互。

原因也很简单：`remotefs::` 的 API 即使很像 `std::fs`，它终究不是
`std::fs`。现有程序不会仅仅因为两套接口相似，就自动改用 RemoteFs。

于是我把目光转向了 FUSE。

FUSE 允许我们在用户空间实现文件系统，再通过常规文件系统接口把它暴露给应用
程序。内核会向实现发出类似下面的请求：

> 这个目录里有哪些文件？
> 这个 inode 有什么属性？
> 请返回这个文件中的这些字节。

程序只需逐一回答。至于数据来自磁盘、数据库、API、SSH 连接，还是完全虚拟的
数据源，内核并不关心。

这听起来恰好很像 RemoteFs 已经在做的事。

## 用 remotefs-fuse 接上操作系统

借助 Linux 上的 FUSE、macOS 上的
[macFUSE](https://github.com/macfuse/macfuse)，以及 Windows 上对应的
[Dokany](https://github.com/dokan-dev/dokany/releases)，我实现了
[remotefs-fuse](https://github.com/remotefs-rs/remotefs-rs-fuse)。它可以包装
任意 `RemoteFs` 实例，并负责与 FUSE 或 Dokany 交互。

```rust
pub struct Driver<T: RemoteFs> {
    #[cfg(unix)]
    inner: Mutex<unix::DriverInner<T>>,
    #[cfg(windows)]
    remote: RwLock<T>,
    // ...
}
```

这样一来，FUSE 层完全不需要知道后端是 SFTP、S3、SMB，还是别的协议；
它眼里只有一个 `RemoteFs`。

任何应用程序都可以把 RemoteFs 客户端暴露成本地文件系统，不必为每种协议分别
实现 FUSE 驱动。抽象问题到这里算是解决了，但使用这个库仍然需要写一小段 Rust
程序，用来配置后端并执行挂载。

还差最后一步，而且这一步很自然。

## Fusibile：把最后一层做成命令行工具

2026 年夏末，我决定写一个简单的命令行工具，让用户只需一条命令就能挂载任意
受支持的远程文件系统，Fusibile 就这样出现了。

它支持现有的全部 RemoteFs 客户端，包括 SFTP、SCP、FTP、SMB、WebDAV、
AWS S3、Google Cloud Storage 和 Kubernetes。基本用法很简单：

```bash
fusibile --to <path> --volume <name> <PROTOCOL> [protocol_options]
```

例如，把一台树莓派上的 SFTP 文件系统挂载到 `/tmp/raspberry`：

```bash
fusibile /tmp/raspberry \
    --volume raspberry \
    sftp \
    --hostname 192.168.1.59 \
    --username pi \
    --password $RASPBERRY_PASSWORD
```

## 处理不同的 UID 和 GID

把远程文件系统变成 Unix 文件系统时，有一个格外麻烦的细节：两台机器上的用户
不一定拥有相同的 UID 和 GID。

假设本地用户的 UID 是 1000，而 SFTP 服务器返回的文件 UID 是 1002。
从 FUSE 的角度看，这些文件属于另一个用户。可我明明已经用有权访问这些文件的
凭据登录了远程服务器。

为了解决这种语义差异，Fusibile 允许覆盖本地权限检查所使用的 UID 和 GID：

```bash
fusibile \
    --to /tmp/raspberry \
    --volume raspberry \
    --uid "$(id -u)" \
    --gid "$(id -g)" \
    sftp \
    --hostname 192.168.1.59 \
    --username pi
```

这个选项不会在远程机器上执行 `chown`。它只是弥合远程协议提供的所有权信息与
本地挂载用户之间的不一致。

对于根本没有 Unix 权限概念的协议，Fusibile 还提供了 `--default-mode`。
S3 就是最典型的例子：对象存储原本从没打算假装自己是 POSIX 文件系统。

但现在，它确实可以这样用了。

## 从统一接口到透明挂载

这个项目最初只是为几种文件传输协议提供共同接口，后来逐渐长成了一套相当完整的
技术栈。Fusibile 是最后一层，让你无需编写 Rust 代码就能直接使用它。

我觉得这也是这个项目最有意思的地方：操作系统和应用程序不需要理解挂载点背后
究竟是 SFTP、S3、Kubernetes，还是其他协议。对它们而言，这些都只是文件。

Fusibile 仍然很年轻，所以我不会把不可替代数据的唯一副本挂载进去，然后立刻用
`rm -rf` 做压力测试。

你可以用一条 Shell 命令安装 Fusibile：

```bash
curl -sSLf https://remotefs-rs.github.io/remotefs-rs-fuse/install.sh | sh
```

在 PowerShell 中也可以这样安装：

```powershell
irm https://remotefs-rs.github.io/remotefs-rs-fuse/install.ps1 | iex
```

更多代码和使用说明可以在
[Fusibile 项目仓库](https://github.com/remotefs-rs/remotefs-rs-fuse)中找到。
