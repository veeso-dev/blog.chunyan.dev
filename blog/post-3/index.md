---
date: "2026-09-18 00:00:00 +02:00"
slug: "rust-windows-smb-share"
title: "用 Rust 在 Windows 上访问 SMB 共享"
description: "从 windows-sys 依赖配置到连接清理，介绍如何借助 Windows API 连接 SMB 共享，再用 Rust 标准库访问其中的文件。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '4'
---

我开发了 termscp，这是一个功能比较完整的终端文件传输与文件浏览工具，
支持 SCP、SFTP、FTP、S3，现在也支持 SMB。不过，SMB 支持并没有想象中
那么容易实现。

在 Linux 和 macOS 上，我已经让 libsmbclient 的 Rust 接口跑了起来，相关实现
可以看 [pavao](https://github.com/veeso/pavao)。到了 Windows，我却一直没找到
一份真正说明该怎么做的指南。

我在 Stack Overflow 的一个讨论里看到，Windows 原生支持 SMB：只要把
IP 地址或主机名放到路径前面，就应该能像访问普通文件一样访问共享。
但实际操作并没有这么顺利。最后，我只好翻阅各种论坛里其他语言的实现，
才拼出完整办法。

这篇文章就把结果整理成一份教程：如何用 Rust 在 Windows 上访问 SMB 共享。

## 挂载 SMB 共享

我先确认了一件事：在 PowerShell 中，可以用下面的命令访问 SMB 共享：

```sh
net use \\server\share /user:username [password]
```

接下来要弄清楚的，就是这条命令背后调用了什么 API。答案是 Windows API，
而且挂载共享只需要一次简单的调用。先从依赖开始配置。

### 添加依赖

这个实现只需要 `windows-sys`，并启用一个额外的 feature：

```toml
[dependencies]
windows-sys = { version = "^0.48", features = [ "Win32_NetworkManagement_WNet" ] }
```

依赖准备好以后，就可以在客户端里挂载共享了。

### 建立连接

先引入需要的类型：

```rust
use std::ffi::CString;

use windows_sys::Win32::Foundation::{NO_ERROR, TRUE};
use windows_sys::Win32::NetworkManagement::WNet;
```

后面会处理裸指针，因此还需要一个工具函数，把 `String` 转成 `CString`：

```rust
fn to_cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}
```

这里为了突出主线直接用了 `unwrap`，实际项目里可以把错误处理得更妥当。

现在可以实现连接函数：

```rust
fn connect(
    server: &str,
    share: &str,
    username: Option<&str>,
    password: Option<&str>
) -> Result<(), i32>
{
    let remote_name = to_cstr(&format!("\\\\{server}\\{share}"));

    // 初始化资源
    let mut resources = WNet::NETRESOURCEA {
        dwDisplayType: WNet::RESOURCEDISPLAYTYPE_SHAREADMIN,
        dwScope: WNet::RESOURCE_GLOBALNET,
        dwType: WNet::RESOURCETYPE_DISK,
        dwUsage: WNet::RESOURCEUSAGE_ALL,
        lpComment: std::ptr::null_mut(),
        // 如果想把共享挂载为 Windows 卷，请在这里填写卷名
        lpLocalName: std::ptr::null_mut(),
        lpProvider: std::ptr::null_mut(),
        lpRemoteName: remote_name.as_c_str().as_ptr() as *mut u8,
    };

  let username = username.as_ref().map(|username| to_cstr(username));
  let password = password.as_ref().map(|password| to_cstr(password));

  // 挂载共享
  let result = unsafe {
      let username_ptr = username
          .as_ref()
          .map(|username| username.as_ptr())
          .unwrap_or(std::ptr::null());
      let password_ptr = password
          .as_ref()
          .map(|password| password.as_ptr())
          .unwrap_or(std::ptr::null());
      WNet::WNetAddConnection2A(
          &mut resources as *mut WNet::NETRESOURCEA,
          password_ptr as *const u8,
          username_ptr as *const u8,
          // 凭据错误时，交互模式会显示系统对话框，让用户重新输入密码。
          // 如果不需要对话框，请改为 0。
          WNet::CONNECT_INTERACTIVE,
       )

  };

  if result == NO_ERROR {
    Ok(())
  } else {
    Err(result)
  }

}
```

### 访问共享中的文件

调用上面的函数以后，共享中的文件就可以访问了。但具体应该使用哪种
路径？这里有两种选择：

1. 在 `resources` 中设置 `lpLocalName`，之后通过选定的卷访问挂载的共享。
2. 使用下面的 `full_path` 函数构造完整路径。

```rust
fn full_path(server: &str, share: &str, p: &Path) -> PathBuf {
    let mut full_path = PathBuf::from(format!("\\\\{}\\{}", server, share));
    full_path.push(p);

    full_path
}
```

我选择第二种方式。打开文件的代码可以这样写：

```rust
use std::fs::File;
use std::io::Result as IoResult;

fn open(server: &str, share: &str, path: &Path) -> IoResult<File> {
    let path = full_path(server, share, path);
    File::open(&path)
}
```

可以看到，只要为已经挂载的共享拼出完整路径，就能直接使用标准库访问
远程共享中的每个文件，操作方式与本地文件系统没有区别。

### 清理连接

应用退出前，别忘了清理 SMB 共享连接。Windows API 也为此提供了一个
简单调用：

```rust
fn disconnect(server: &str, share: &str) -> Result<(), i32> {
    let remote_name = to_cstr(&format!("\\\\{server}\\{share}"));

    let result =
        unsafe { WNet::WNetCancelConnection2A(remote_name.as_ptr() as *mut u8, 0, TRUE) };

    if result == NO_ERROR {
        Ok(())
    } else {
        Err(result)
    }

}
```

到这里就完成了。查了很久的资料，最后才发现，在 Windows 上处理 SMB 共享
其实并不复杂。

## 参考实现

本文的全部代码都能在
[remotefs-rs-smb 仓库](https://github.com/veeso/remotefs-rs-smb)的
`src/client/windows.rs` 中找到。如果你正在使用 remotefs-rs，也可以直接采用
这个库，它提供了一套更简单的 SMB 共享接口。

这个库同样支持 Linux 和 macOS。因此，如果你的 Rust SMB 应用需要跨平台
兼容，也可以直接使用它。
