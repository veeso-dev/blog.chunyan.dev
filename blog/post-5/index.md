---
date: "2026-09-18 02:00:00 +02:00"
slug: "tokio-cpu-affinity"
title: "用 core_affinity 为 Tokio 运行时指定 CPU 核心"
description: "在 Rust 中手动构建 Tokio 多线程运行时，并用 core_affinity 将工作线程绑定到指定 CPU 核心。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '4'
---

有些应用把性能压到极致时，不能再把线程调度完全交给操作系统，
而是需要明确指定进程可以使用哪些 CPU 核心。比如，我们可能想为某个进程
预留一组核心，也可能希望按服务拆分服务器上的核心资源。

在 Tokio 应用里，可以借助 Rust crate
[core_affinity](https://docs.rs/core_affinity/latest/core_affinity/) 完成这件事。

## 配置依赖

先在 `Cargo.toml` 中加入所需依赖：

```toml
core_affinity = "0.8"
tokio = { version = "1", features = ["full"] }
```

## 获取要使用的 CPU 核心

接下来需要实现一个函数，得到应用应该使用的核心。我在使用
`core_affinity` 的应用里，通常会让用户通过命令行参数传入核心范围，
格式可以是 `x,y,z`，也可以是 `n-m`。

````rust
/// 获取应用要使用的 CPU 核心；
/// 如果没有指定范围，就使用所有可用核心
pub fn get_cpu_cores(range: Option<&str>) -> anyhow::Result<Vec<CoreId>> {
    let available_cores =
        core_affinity::get_core_ids().ok_or(anyhow::anyhow!("无法获取可用的 CPU 核心"))?;

    // 记录所有可用核心
    for core in &available_cores {
        tracing::info!("可用核心：{}", core.id);
    }

    match range.map(parse_range_usize) {
        None => Ok(available_cores),
        Some(Err(err)) => Err(err),
        Some(Ok(range)) => {
            let cores = available_cores
                .into_iter()
                .filter(|core| range.contains(&core.id))
                .collect::<Vec<CoreId>>();
            Ok(cores)
        }
    }
}

/// 将范围字符串解析成 usize 向量
///
/// # 参数
/// - range_str: &str - 要解析的范围字符串
///
/// # 返回值
/// - Result<Vec<usize>, anyhow::Error> - 解析后的范围
///
/// # 示例
/// ```
/// use notpu::utils::parse_range_usize;
///
/// let range = parse_range_usize("0-3").unwrap();
/// assert_eq!(range, vec![0, 1, 2]);
///
/// let range = parse_range_usize("0,1,2,3").unwrap();
/// assert_eq!(range, vec![0, 1, 2, 3]);
/// ```
pub fn parse_range_usize(range_str: &str) -> anyhow::Result<Vec<usize>> {
    // 解析两种格式：0-3 或 0,1,2,3
    if range_str.contains('-') {
        let mut range = range_str.split('-');
        let start = range
            .next()
            .ok_or_else(|| anyhow::anyhow!("无效的范围"))?;
        let end = range
            .next()
            .ok_or_else(|| anyhow::anyhow!("无效的范围"))?;
        let start = start
            .parse::<usize>()
            .map_err(|_| anyhow::anyhow!("无效的范围"))?;
        let end = end
            .parse::<usize>()
            .map_err(|_| anyhow::anyhow!("无效的范围"))?;

        Ok((start..end).collect::<Vec<usize>>())
    } else {
        let range = range_str
            .split(',')
            .map(|s| {
                s.parse::<usize>()
                    .map_err(|_| anyhow::anyhow!("无效的范围"))
            })
            .collect::<Result<Vec<usize>, _>>()?;
        Ok(range)
    }
}
````

> ❗ CPU 核心通常会排序，并用从 0 到核心数量的数字索引来标识。

## 配置 Tokio 运行时

拿到核心列表后，下一步就是配置 **Tokio 运行时**。

一般使用 Tokio 时，`main` 函数会写成这样：

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // ...

    Ok(())
}
```

但这一次需要修改运行时配置，因此要自行构建运行时。

### `tokio::main` 宏背后的工作

这里先说一个你可能没有留意过的细节：`tokio::main` 宏会按默认配置
替我们创建运行时。它所做的事情大致相当于：

```rust
fn main() -> anyhow::Result<()> {
    let rt = tokio::runtime::Runtime::new().unwrap();

    rt.block_on(async {
        // ... async fn main 中的代码 ...
    })
}
```

### 用 CPU 亲和性构建 Tokio 运行时

现在改为手动构建运行时，并在工作线程启动时绑定核心：

```rust
fn main() -> anyhow::Result<()> {
    // 获取要使用的 CPU 核心
    let args: CliConfig = argh::from_env();
    let cpu_cores: Vec<CoreId> = utils::get_cpu_cores(args.cpu_cores.as_deref())?;

    // 构建 Tokio 运行时
    let tokio_runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(cpu_cores.len().max(32))
        .on_thread_start(move || { // 使用 CPU 亲和性，为工作线程随机选择一个核心
            use rand::seq::SliceRandom;
            // 选择运行工作线程的 CPU 核心
            let mut rng = rand::thread_rng();
            let core = cpu_cores.choose(&mut rng).unwrap();
            if core_affinity::set_for_current(*core) {
                debug!("将工作线程绑定到核心 {}", core.id);
            } else {
                error!("无法将工作线程绑定到核心 {}", core.id);
            }
        })
        .enable_all()
        .build()?;

    // 进入运行时上下文
    let _guard = tokio_runtime.enter();

    // 运行异步入口
    tokio_runtime.block_on(async_main(args))
}

async fn async_main(args: CliConfig) -> anyhow::Result<()> {
    // ...
}
```

下面拆开看看，这段代码如何让 Tokio 使用我们指定的核心。

关键在 `on_thread_start`：Tokio 每启动一个运行时工作线程，都会在该线程开始执行
任务前调用一次这个回调。在回调里，我们从为应用配置的核心中随机选择一个：

```rust
// 引入 `choose`
use rand::seq::SliceRandom;
let mut rng = rand::thread_rng();
let core = cpu_cores.choose(&mut rng).unwrap(); // 列表不会为空，可以安全地 unwrap
```

为当前工作线程选好核心后，再调用 `core_affinity::set_for_current`，
把线程绑定到该 CPU 核心：

```rust
if core_affinity::set_for_current(*core) {
    debug!("将工作线程绑定到核心 {}", core.id);
} else {
    error!("无法将工作线程绑定到核心 {}", core.id);
}
```

> ❗ `on_thread_start` 针对工作线程，而不是任务。调用 `tokio::task::spawn`
> 不会再次执行这个回调；新任务会由已经绑定核心的工作线程调度。

## 小结

以上就是在 Rust 中使用 **core_affinity**，为 Tokio 任务配置 CPU 核心的方法。

这段代码还可以继续扩展。借助一些上下文，你可以按任务类型等其他条件选择核心。
`core_affinity` 也不限于异步应用：在同步环境中，可以在线程创建后调用
`core_affinity::set_for_current`，也可以视需要在 `main()` 函数中调用它。
