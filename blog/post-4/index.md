---
date: "2026-09-18 01:00:00 +02:00"
slug: "rust-range-parser-without-step"
title: "Rust 泛型范围解析器：绕过不稳定的 Step"
description: "从一个看似简单的范围字符串解析需求出发，拆解 Rust 泛型 trait 约束，并比较两种绕过不稳定 Step 的实现。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '8'
---

## 简单需求，复杂解法

前几天，我需要写一个看起来很简单的函数：接收用字符串表示的范围，
返回一个包含范围内所有元素的 `Vec`。

我希望它能支持任意原生数值类型，于是先写出了下面这个函数签名：

````rust
/// 将范围字符串解析为 usize 向量
///
/// # 参数
/// - range_str: &str - 要解析的范围字符串
///
/// # 返回值
/// - Result<Vec<T>, anyhow::Error> - 解析后的范围
///
/// # 示例
///
/// ```rust
/// let range: Vec<u64> = parse_range::<u64>("0-3").unwrap();
/// assert_eq!(range, vec![0, 1, 2, 3]);
///
/// let range: Vec<u64> = parse_range::<u64>("0,1,2,3").unwrap();
/// assert_eq!(range, vec![0, 1, 2, 3]);
/// ```
fn parse_range<T>(range_str: &str) -> Result<Vec<T>, Box<dyn Error>>
````

接着实现函数体：

```rust
fn parse_range<T>(range_str: &str) -> Result<Vec<T>, Box<dyn Error>> {
    // 解析 0-3 和 0,1,2,3 两种格式
    if range_str.contains('-') {
        let mut range = range_str.split('-');
        let start = range.next().ok_or_else(|| "invalid range: start token not found")?;
        let end = range.next().ok_or_else(|| "invalid range: end token not found")?;
        let start = start
            .parse::<T>()
            .map_err(|_| "invalid range: start is not a number")?;
        let end = end
            .parse::<T>()
            .map_err(|_| "invalid range: end is not a number")?;

        Ok((start..=end).collect::<Vec<T>>())
    } else {
        let range = range_str
            .split(',')
            .map(|s| {
                s.parse::<T>()
                    .map_err(|_| "invalid range values: not a number")
            })
            .collect::<Result<Vec<T>, _>>()?;
        Ok(range)
    }
}
```

这段代码同时尝试解析 `start-end` 和 `a,b,...,y,z` 两种格式。

字符串里只要有 `-`，函数就会先拆出 `start` 和 `end`，再把两者解析为
`T`。解析成功后，它会返回从 `start` 到 `end` 的全部元素。

> ❗ 当然，范围解析器还有更好的写法，例如继续迭代并查找逗号。
> 这里只讨论最简单的版本。另外，这个实现不能处理负数。

不过，这段代码现在还无法工作。我们没有告诉编译器 `T` 可以从字符串解析，
所以需要先添加第一个 trait 约束：

```rust
fn parse_range<T>(range_str: &str) -> Result<Vec<T>, Box<dyn Error>>
where
    T: FromStr,
{
  // ...
}
```

![演员克里斯·埃文斯说看起来不错](./looks-great-chris-evans.gif)

然而，编译器仍然不肯放行：

```txt
error[E0599]: the method `collect` exists for struct `RangeInclusive<T>`, but its trait bounds were not satisfied
   --> src/main.rs:44:26
    |
44  |         Ok((start..=end).collect::<Vec<T>>())
    |                          ^^^^^^^ method cannot be called on `RangeInclusive<T>` due to unsatisfied trait bounds
    |
   ::: /home/veeso/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/core/src/ops/range.rs:345:1
    |
345 | pub struct RangeInclusive<Idx> {
    | ------------------------------ doesn't satisfy `RangeInclusive<T>: Iterator`
    |
    = note: the following trait bounds were not satisfied:
            `T: Step`
            which is required by `RangeInclusive<T>: Iterator`
            `RangeInclusive<T>: Iterator`
            which is required by `&mut RangeInclusive<T>: Iterator`
help: consider restricting the type parameter to satisfy the trait bound
    |
26  |     T: FromStr, T: Step
    |               ~~~~~~~~~
```

`Step` trait 是什么？它定义了一个类型在迭代器里应该怎样前进一步。
对我们来说，`2` 排在 `1` 后面、`3` 前面再自然不过，但编译器不知道这一点。
此处的 `T` 可以是任何实现了 `FromStr` 的类型，甚至可以是字符串。

例如，下面这个结构体也能满足当前约束：

```rust
struct MyType {
  a: String,
  b: String,
}

impl FromStr for MyType {
  // ...
}
```

这样一来，我们也可以要求函数解析 `MyType` 的范围。可 `MyType A` 和
`MyType N` 之间究竟有哪些值？`Step` trait 正是用来回答这个问题的。

那么，给函数加上 `Step` 约束应该就可以了：

```rust
use std::iter::Step;

fn parse_range<T>(range_str: &str) -> Result<Vec<T>, Box<dyn Error>>
where
    T: FromStr + Step,
{
  // ...
}
```

![女子摇头表示不行](./nope.gif)

代码还是无法构建，这次 Rust 编译器给出了新的错误：

```txt
error[E0658]: use of unstable library feature 'step_trait'
 --> src/main.rs:1:25
  |
1 | use std::{error::Error, iter::Step, str::FromStr};
  |                         ^^^^^^^^^^
  |
  = note: see issue #42168 <https://github.com/rust-lang/rust/issues/42168> for more information

error[E0658]: use of unstable library feature 'step_trait'
  --> src/main.rs:26:18
   |
26 |     T: FromStr + Step,
   |                  ^^^^
   |
   = note: see issue #42168 <https://github.com/rust-lang/rust/issues/42168> for more information

For more information about this error, try `rustc --explain E0658`.
```

问题到这里已经很清楚了：我们想从 `T` 创建范围，而这要求 `Step` trait；
偏偏 `Step` 还是不稳定特性。看起来，这条路走不通了。

## 解法一：用运算 trait 绕开 Step

换个角度想。虽然不能使用 `Step`，但这里真正需要支持的基本都是数值类型，
更具体地说，很可能就是整数。我们的需求只是从 `n` 迭代到 `m`，依次取出
中间的每个值，这也正是 `Step` 所做的事。既然如此，不妨自己实现这段逻辑。

步骤可以简化成：

1. 令 `x = n`
2. 把 `x` 放进 `Vec`
3. 令 `x = x + 1`
4. 如果 `x > m`，停止循环
5. 否则回到第 2 步

实现这套逻辑并不需要 `Step`，只要 `Add`、`Eq` 和 `Ord` 就够了。

![男子指着太阳穴示意动脑思考](./think-about-it.gif)

```rust
use std::cmp::{Eq, Ord};
use std::ops::Add;

fn parse_range<T>(range_str: &str) -> Result<Vec<T>, Box<dyn Error>>
where
    T: FromStr + Add<Output = T> + Eq + Ord,
{
  // ...

        let mut range = Vec::new();
        let mut x = start;
        while x <= end {
            range.push(x);
            x = x + 1;
        }

        Ok(range)

  // ...
}
```

现在只剩一个问题：怎样给 `x` 加上 `1`？字面量 `1` 并不是 `T`，
我们得找到一种办法，把代表一个单位的值以 `T` 的形式加到 `x` 上。

### Unit trait

先说明一下：Rust 中并没有名为 `Unit` 的 trait。不过，我们可以自己定义一个，
再把它加进函数的约束：

```rust
/// 用于具有单位值的类型。
///
/// 例如，整数的单位值是 1，浮点数的单位值是 1.0，等等。
pub trait Unit {
    fn unit() -> Self;
}
```

接下来用 `macro_rules!` 为所有原生整数类型实现它：

```rust
/// 为常见数值类型实现 Unit。
macro_rules! impl_one_for_numeric {
    ($($t:ty)*) => ($(
        impl Unit for $t {
            fn unit() -> Self {
                1
            }
        }
    )*)
}

impl_one_for_numeric!(usize u8 u16 u32 u64 isize i8 i16 i32 i64);
```

终于，我们可以给函数补全 trait 约束了：

```rust
fn parse_range<T>(range_str: &str) -> Result<Vec<T>, Box<dyn Error>>
where
    T: FromStr + Add<Output = T> + Eq + Ord + Unit + Copy,
```

现在，迭代部分也能写完整：

```rust
let mut range = Vec::new();
let mut x = start;
while x <= end {
    range.push(x);
    x = x + T::unit();
}

Ok(range)
```

你可能注意到，这里又多了一个 `Copy`：

```rust
range.push(x);
x = x + T::unit();
```

这两行代码需要先把 `x` 的值复制进 `range`，然后继续使用 `x`。

至此，完整函数终于可以成功编译：

```rust
fn parse_range<T>(range_str: &str) -> Result<Vec<T>, Box<dyn Error>>
where
    T: FromStr + Add<Output = T> + Eq + Ord + Unit + Copy,
{
    // 解析 0-3 和 0,1,2,3 两种格式
    if range_str.contains('-') {
        let mut range = range_str.split('-');
        let start = range
            .next()
            .ok_or_else(|| "invalid range: start token not found")?;
        let end = range
            .next()
            .ok_or_else(|| "invalid range: end token not found")?;
        let start = start
            .parse::<T>()
            .map_err(|_| "invalid range: start is not a number")?;
        let end = end
            .parse::<T>()
            .map_err(|_| "invalid range: end is not a number")?;

        let mut range = Vec::new();
        let mut x = start;
        while x <= end {
            range.push(x);
            x = x + T::unit();
        }

        Ok(range)
    } else {
        let range = range_str
            .split(',')
            .map(|s| {
                s.parse::<T>()
                    .map_err(|_| "invalid range values: not a number")
            })
            .collect::<Result<Vec<T>, _>>()?;
        Ok(range)
    }
}
```

## 解法二：通过 isize 转换

另一种办法是围绕 `isize` 增加约束。它确实比前一种方案更简单，
但我认为整体上反而更差。之所以仍把它写出来，是因为读者很可能会注意到：
这看起来才是最直接的实现。

具体来说，可以这样写范围解析器：

```rust
fn parse_range<T>(range_str: &str) -> Result<Vec<T>, Box<dyn Error>>
where
    T: FromStr + TryInto<isize> + TryFrom<isize>,
{
    // 解析 0-3 和 0,1,2,3 两种格式
    if range_str.contains('-') {
        let mut range = range_str.split('-');
        let start = range
            .next()
            .ok_or_else(|| "invalid range: start token not found")?;
        let end = range
            .next()
            .ok_or_else(|| "invalid range: end token not found")?;
        let start = start
            .parse::<isize>()
            .map_err(|_| "invalid range: start is not a number")?;
        let end = end
            .parse::<isize>()
            .map_err(|_| "invalid range: end is not a number")?;

        let range = (start..=end).collect::<Vec<isize>>();
        let mut t_range = Vec::with_capacity(range.len());
        for x in range {
            if let Ok(x) = x.try_into() {
                t_range.push(x);
            } else {
                return Err("invalid range values: conversion error".into());
            }
        }
        Ok(t_range)
    } else {
        let range = range_str
            .split(',')
            .map(|s| {
                s.parse::<T>()
                    .map_err(|_| "invalid range values: not a number")
            })
            .collect::<Result<Vec<T>, _>>()?;
        Ok(range)
    }
}
```

这样，我们就能用所有可以放进 `isize` 的原生类型。不过，一些 `u64` 值会在
转换时出错；因此，这个方案虽然简单，却肯定不如第一种，而且性能很可能也更差。

## 补充：完善后的 range-parser

后来，我决定继续完善这个范围解析器，并把它发布成一个 Rust crate。

改进后的 range-parser 仍然采用前文介绍的核心方案，同时增加了多段范围字符串
（例如 `1-3,7-9`）、负数（例如 `-1-2,-8--5,-10`）、自定义分隔符以及更好的
错误信息。最近重读这篇文章时，我还发现当初没有检查范围的
**起点 `start` 是否小于终点 `end`**，
这也确实引发了一个 bug。

如果你想看看实现，或者直接使用这个稳定的库，可以在 crates.io 上找到
[range-parser](https://crates.io/crates/range-parser) ❤️。

![舞台上的歌手庆祝起舞](./party-dance.gif)

## 总结

希望这次拆解能让你觉得有点意思；如果你刚好在寻找范围解析器的实现方法，
也希望它确实帮到了你。最后不妨再确认一下：`Step` trait 现在是否已经稳定了 😅。
