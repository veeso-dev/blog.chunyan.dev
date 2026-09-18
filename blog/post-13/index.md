---
date: "2026-09-18 10:00:00 +02:00"
slug: "rust-future-waker-runtime"
title: "异步 Rust 原理：从 Future 到简易运行时"
description: "从 Future、Pin、Poll、Context 和 Waker 入手，亲手实现两个简易运行时，理解异步 Rust 的执行与唤醒机制。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '9'
---

很多 Rust 开发者每天都会写异步代码：给函数加上 `async`，在调用处写下
`.await`，再把程序交给 Tokio。不过，这些语法背后究竟发生了什么？

这篇文章不从运行时的完整工程实现讲起，而是沿着 `Future`、`Pin`、
`Context`、`Poll` 和 `Waker` 一步步往下拆。最后，我们会亲手做出一个很笨、
但足以解释核心机制的异步运行时。

> 类似的文章不是已经有成千上万篇了吗？
>
> 没错，但这一篇是我写的。

## 为什么需要异步

可以先用一句话概括常见场景：**当任务需要等待外部系统，而且我们还想让同一批线程
继续处理其他工作时，异步通常很合适**。这类任务的完成时间往往不由当前程序决定，
外部资源也随时可能产生延迟。

还有一个更实际的原因：资源。如果同时有很多任务，却不用异步，我们往往只能为
每个任务创建一个线程。任务少时这能正常工作，但当任务数量达到几百甚至几千，
线程的成本和管理难度很快就会显现。异步运行时则能用少得多的线程承载大量任务，
并根据可用线程调度这些任务，不必让每项工作独占一个操作系统线程。

至少有三类常见工作适合异步：

- **I/O**：文件系统的读写是否完成取决于文件系统本身。它通常没有特别明显的
  延迟，但依旧不是应用可以直接控制的。程序把 I/O 操作交给操作系统，再等待它
  完成。
- **网络**：网络交互会经过大量不受当前应用控制的环节。仅仅一次 HTTP GET，
  就要创建套接字、写入数据、经过网关和互联网到达服务器，再沿着相反方向返回。
  这里已经省略了很多步骤，而其中每一步都可能带来延迟。
- **时间**：时间本身也无法立刻“求值”。如果要等待 5 秒，程序同样依赖一个外部
  系统——姑且说是整个宇宙吧。因此，定时器也很适合用异步处理。

> 💡 I/O 并不总是真正的异步。以 Linux 为例，许多异步文件系统函数在底层仍会
> 在线程池里执行传统的阻塞式 libc 调用，Tokio 的 `spawn_blocking` 做的就是这类
> 工作，因为 `epoll` 根本不支持普通文件。Linux 确实提供了真正的异步 I/O
> 接口 [io_uring](https://kernel.dk/io_uring.pdf)，但它仍然相当复杂，而且支持情况
> 不够一致，通用运行时很难默认依赖它，所以通常还是用线程池来模拟异步文件 I/O。

理解了使用场景，接下来就看看异步 Rust 如何运行。

## 不用 Tokio 运行异步代码

第一次接触异步代码时，你可能试过在同步函数里直接执行它。编译器会拒绝，因为
只有在异步上下文中才能使用 `await`。大多数时候，我们会加上 `tokio::main`，
或者使用 **futures** crate 提供的 `block_on`。

其实，在同步上下文里驱动异步代码并没有想象中复杂。先实现一个最简单的
`DumbRuntime`：

```rust
use std::pin::Pin;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

/// 用于执行异步代码的简单运行时
pub struct DumbRuntime;

impl DumbRuntime {
    pub fn block_on<F>(mut f: F) -> F::Output
    where
        F: Future,
    {
        let mut f = unsafe { Pin::new_unchecked(&mut f) };

        let mut ctx = Context::from_waker(Waker::noop());

        loop {
            println!("polling future");
            match f.as_mut().poll(&mut ctx) {
                Poll::Ready(val) => {
                    println!("future is ready");
                    return val;
                }
                Poll::Pending => {
                    std::thread::sleep(Duration::from_micros(10)); // 这里甚至不该执行到
                }
            }
        }
    }
}
```

这里暂时只有一个 `block_on` 函数，它负责在同步上下文里执行异步函数。代码看起来
可能和你平时写的 Rust 不太一样。

![困惑地看着镜头的猫](./huh.gif)

把它拆开看，就容易理解多了：

1. `block_on` 接收一个可变的 `Future`，并返回它的输出。

   `Future` 是表示异步计算的 trait，这项计算可能已经完成，也可能尚未完成。
   它的 `poll` 方法接收一个可变的 `Context`，返回 `Poll` 枚举。`Poll::Ready`
   携带计算结果，`Poll::Pending` 则表示计算还没有结束。

2. 我们从 future 的可变引用创建一个 `Pin`。`Pin` 用来保证对象不会在内存中被
   移动。异步状态机可能依赖这一保证；如果破坏其固定位置的不变量，就可能触发
   未定义行为，包括段错误之类的严重问题。
3. 我们用 `Waker` 创建 `Context`。`Waker` 负责在任务可以继续执行时唤醒它。
4. 进入循环并不断轮询 future。如果它已经就绪，就返回结果；否则休眠 10 微秒，
   然后再次轮询。

现在，我们已经能从同步上下文执行异步代码：

```rust
mod runtime;

use self::runtime::DumbRuntime;

fn main() {
    DumbRuntime::block_on(async_main());
}

async fn async_main() {
    println!("Hello, world!");
}
```

程序会输出一次 `Hello, world!`，也会各输出一次 `polling future` 和
`future is ready`，因为这里只运行了一个 future。

### 嵌套异步调用会怎样

如果再加一层异步调用呢？

```rust
mod runtime;

use self::runtime::DumbRuntime;

fn main() {
    DumbRuntime::block_on(async_main());
}

async fn async_main() {
    let res = async_fn().await;
    println!("Hello, world! {res}");
}

async fn async_fn() -> i32 {
    42
}
```

程序退出前会输出多少次 `polling future`？答案其实只有一次。那么，内部的异步函数
又是怎么执行的？

![面对公式思考的女性](./math.gif)

## 异步代码如何执行

要回答这个问题，得先弄清楚异步函数究竟是什么。

`async` 函数本质上是语法糖，可以把它近似理解为下面这个签名：

```rust
fn async_fn() -> impl Future<Output = i32> {
    std::future::ready(42)
}
```

它只是一个返回 `Future` 实现的函数。

前面提到，`Future` trait 的 `poll` 方法会返回一个 `Poll` 枚举。对 future 使用
`await` 时，底层状态机会轮询它。这个过程由运行时负责：无论是 Tokio，还是刚才
写的 `DumbRuntime`，都会继续驱动最外层的 future，直到它就绪；嵌套 future 则由
外层 future 在自己的 `poll` 过程中继续轮询。因此，上面的立即就绪计算只需一次
外层轮询。

## 创建一个异步任务

只返回 `42` 没什么意思。我们来做一个稍微像样的异步任务：它接收 `n: u64`，先
返回 `n - 1` 次 `Pending`，最后才返回 `Ready`。

```rust
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::task::{Context, Poll};

pub struct Counter {
    pub counter: Arc<AtomicU64>,
    max: u64,
}

impl Future for Counter {
    type Output = u64;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        self.counter
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);

        let value = self.counter.load(std::sync::atomic::Ordering::SeqCst);
        println!("polled with current value: {value}");

        if value >= self.max {
            Poll::Ready(value)
        } else {
            // 唤醒 future
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}
```

一个异步任务不一定非得写成 `async fn`；也可以像这里一样，定义一个实现
`Future` trait 的结构体。`Counter` 保存 `counter` 和 `max` 两个字段。每次
`poll` 都会将计数器加一：达到 `max` 时返回 `Ready`，否则返回 `Pending`。

当然，**这仍然不是真正合理的异步任务**。异步应该用来处理依赖外部资源的工作，
比如 I/O 或超时，而不是单纯地递增内存里的数字。这个例子只是为了把轮询过程展示
出来。

接着创建一个返回该任务的函数：

```rust
fn count(to: u64) -> impl Future<Output = u64> {
    Counter { counter: Arc::new(AtomicU64::new(0)), max: to }
}
```

这里有趣的地方在于，我们返回的是一个结构体，而不是最终结果。调用 `.await` 后，
运行时会替我们不断驱动它的 `poll`。

核心概念到这里已经齐了。不过，`DumbRuntime` 名副其实：它离 Tokio 这样的真正
异步运行时还很远。下面稍微认真一点，再实现一个版本。

## 实现一个稍微像样的异步运行时

这个运行时至少要完成三件事：

1. 创建新任务，并返回一个可用于取得结果的句柄。
2. 提供一个负责轮询任务的 worker。
3. 能够阻塞等待某个 future 完成。

先定义 `Task` 结构体，用它保存 future，以及一个用于回传结果的 sender：

```rust
struct Task<T>
where
    T: Send,
{
    future: Pin<Box<dyn Future<Output = T> + Send>>,
    sender: SyncSender<T>,
}
```

这里的 `T` 是任务的返回类型。

然后定义运行时。它持有一个 sender，用于把任务发送给 worker：

```rust
pub struct TaskRuntime<T>
where
    T: Send,
{
    sender: Sender<Task<T>>,
}
```

我们还需要一个等待结果的句柄：

```rust
pub struct TaskHandle<T>
where
    T: Send,
{
    receiver: Receiver<T>,
}

impl<T> TaskHandle<T>
where
    T: Send,
{
    pub fn join(self) -> T {
        self.receiver.recv().expect("failed to receive result")
    }
}
```

最后，实现任务运行时本身：

```rust
impl<T> TaskRuntime<T>
where
    T: Send + 'static,
{
    pub fn new() -> Self {
        let (sender, receiver) = channel();
        // 启动负责创建任务的 worker
        std::thread::spawn(move || Self::run(receiver));

        Self { sender }
    }

    /// 创建新任务，并取得用于等待结果的 [`TaskHandle`]
    pub fn spawn<F>(&mut self, f: F) -> TaskHandle<T>
    where
        F: Future<Output = T> + Send + 'static,
        T: Send,
    {
        let (result_sender, result_receiver) = sync_channel(1);

        let task = Task {
            future: Box::pin(f),
            sender: result_sender,
        };

        self.sender.send(task).expect("failed to spawn");

        TaskHandle {
            receiver: result_receiver,
        }
    }

    /// 阻塞等待 future，并返回结果
    pub fn block_on<F>(mut f: F) -> F::Output
    where
        F: Future,
    {
        let mut f = unsafe { Pin::new_unchecked(&mut f) };

        let thread = std::thread::current();
        let waker = Arc::new(SimpleWaker { thread }).into();
        let mut ctx = Context::from_waker(&waker);

        loop {
            println!("polling future");
            match f.as_mut().poll(&mut ctx) {
                Poll::Ready(val) => {
                    println!("future is ready");
                    return val;
                }
                Poll::Pending => {
                    std::thread::park();
                    println!("parked");
                }
            }
        }
    }

    /// 运行该运行时的内部 worker。
    /// 每当收到一个任务时，就创建一个新线程来执行它
    fn run(receiver: Receiver<Task<T>>) {
        while let Ok(task) = receiver.recv() {
            std::thread::spawn(move || Self::run_task(task));
        }
    }

    /// 执行任务，等待它就绪，再把结果发回去
    fn run_task(task: Task<T>) {
        let res = Self::block_on(task.future);
        task.sender.send(res).expect("failed to send result");
    }
}
```

现在可以创建异步任务，并等待它们完成：

```rust
fn main() {
    let mut runtime = TaskRuntime::new();
    let handle_1 = runtime.spawn(async_fn());
    let handle2 = runtime.spawn(async_fn2());

    let res = handle_1.join();
    let res2 = handle2.join();

    println!("res: {res}");
    println!("res2: {res2}");
}

async fn async_fn() -> u64 {
    let res = count(10).await;
    println!("async_fn {res}");
    res
}

async fn async_fn2() -> u64 {
    let res = count(23).await;
    println!("async_fn2 {res}");
    res
}

fn count(max: u64) -> impl Future<Output = u64> {
    println!("count");
    Counter {
        counter: Arc::new(AtomicU64::new(0)),
        max,
    }
}
```

到这里，一个能够执行异步任务的简单运行时就完成了。

它还缺少很多功能，而且目前**会使用大量线程**；此外，任务也**不能拥有不同的
返回类型**。不过，它已经足够帮助我们理解异步 Rust 的工作方式。继续补齐生产级
运行时的细节会让示例迅速失去重点，所以这篇文章先停在这里。

## 补充：Context 与 Waker

还有两个前面用过、但没有仔细说明的类型：`Context` 和 `Waker`。

### Context

future 被轮询时，`Context` 用来向它传递信息。在这里，我们主要通过它取得
`Waker`，再用后者唤醒当前任务。

### Waker

`Waker` 是唤醒任务的句柄。它会通知执行器：这个任务已经可以再次运行了。

调用 `poll` 时，我们会收到一个 `Context` 参数，因此可以通过 `cx.waker()` 取得
`Waker`。如果 `poll` 要返回 `Pending`，就应当安排任务在可以继续推进时被唤醒。
在 `Counter` 示例里，我们直接调用了 `cx.waker().wake_by_ref()`。

运行时会持续驱动任务，直到 `poll` 返回 `Ready`。但它不该毫无目的地忙轮询；
`Waker` 的职责，正是在 future 值得再次轮询时通知运行时。

## 总结

现在，我们已经从一个只会循环轮询的 `DumbRuntime` 出发，走到了能创建任务、
休眠线程并通过 `Waker` 唤醒的简易运行时。它离生产环境很远，却把异步 Rust 的
核心关系展示得很清楚：异步函数产生 future，运行时调用 `poll` 推进状态，
`Poll` 告诉运行时任务是否完成，而 `Context` 中的 `Waker` 决定何时再来轮询。

这只是深入异步 Rust 的起点，但理解这些部件之后，再去读 Tokio 或其他运行时的
实现，就不会只看到一层神秘的 `async` 和 `.await` 了。
