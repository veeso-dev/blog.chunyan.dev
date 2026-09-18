---
date: "2026-09-18 06:00:00 +02:00"
slug: "rust-memory-toolbox"
title: "Rust std::mem 模块漫游"
description: "逐个认识 Rust std::mem 模块中的内存工具，从 drop、swap 和判别值，到 transmute、zeroed 与 MaybeUninit 的安全边界。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '10'
---

## 一个不太常用的模块

Rust 的 [`std::mem`](https://doc.rust-lang.org/std/mem/index.html) 总让我觉得有点
神秘。一天晚上十点，我随手翻起标准库文档，想看看当前都有哪些主要模块，结果在
其中发现了 `std::mem`，顺带还注意到标准库正在实现 `random`。我以前用过
`std::mem` 几次，却发现这里还有不少从未碰过的东西。

写了五年多 Rust 之后还能遇到这么多陌生的标准库 API，实在很有意思。于是我决定
从熟悉的部分开始，看看这个模块里究竟藏了哪些工具。

## `drop` 还需要介绍吗

`drop` 大概是 `std::mem` 中最广为人知的函数。它让我们在值离开作用域之前，明确
指定销毁它的时机。

互斥锁就是常见例子：不再需要锁时立即 `drop` 锁守卫，可以尽早释放锁，而不必等到
整个作用域结束。

```rust
use std::mem;

fn main() {
    let x = 1;
    mem::drop(x);

    // 此处 x 已经失效
}
```

## `swap`、`take` 与 `replace`

接下来是另外三个常用函数：`swap`、`take` 和 `replace`。

`take` 会从变量中取走原值，再用该类型的默认值填回去；`replace` 则更进一步，允许
你指定一个新值来占据原来的位置。两者都会把旧值返回给调用方。

```rust
use std::mem;

fn main() {
    let mut x = 1;
    let y = mem::take(&mut x);
    println!("x: {}, y: {}", x, y); // x: 0, y: 1

    let mut x = 1;
    let y = mem::replace(&mut x, 10);
    assert_eq!(x, 10);
    assert_eq!(y, 1);
}
```

`swap` 的用途更直白：在原地交换两个值。

```rust
use std::mem;

let mut x = 1;
let mut y = 2;
mem::swap(&mut x, &mut y);
assert_eq!(x, 2);
assert_eq!(y, 1);
```

这三个函数都能在不做多余复制或移动的情况下调整值，和 `Option` 搭配时尤其好用：
你可以取得某个值的所有权，又不用立刻销毁它。

`JoinHandle` 就是典型场景。如果一个结构体必须保存线程的 `JoinHandle`，通常可以把
它包装成 `Option`；需要等待线程结束时，再用 `join.take()` 取出线程句柄并调用
`join`。

熟悉的函数看完了，下面按字母顺序继续探索那些不那么常见的 API。

## `align_of` 与 `align_of_val`

这两个函数分别返回类型 `T` 和某个 `T` 类型值的 **ABI 所需对齐量**。

那么，什么叫 ABI 所需对齐量？ABI（Application Binary Interface，应用二进制接口）
定义了二进制程序中不同组件彼此交互的规则，其中包括调用约定、数据类型和内存布局。
编译器必须遵守目标架构要求的对齐方式，程序才能正确运行。

简单地说，ABI 对齐保证值被放在合适的内存地址上。不同程序组件共享数据时尤其需要
一致的布局，例如调用其他语言或其他二进制文件里的函数，以及访问它们定义的结构体。

先看一个简单例子：

```rust
let align_of_i32 = mem::align_of::<i32>();
assert_eq!(align_of_i32, 4);
```

`i32` 占 4 字节，这个结果不难理解。结构体的情况更有意思：

```rust
struct Foo {
    a: i32,
    b: i32,
    c: bool,
    d: i64,
}

let align_of_foo = mem::align_of::<Foo>();
assert_eq!(align_of_foo, 8);
```

为什么是 8？这个结构体中对齐要求最高的字段是 `i64`，其对齐量为 8 字节，所以
结构体也必须按 8 字节对齐。换句话说，结构体的地址必须是 8 的倍数。

如果再放进一个 `String` 呢？

```rust
struct Foo {
    a: i32,
    b: i32,
    c: bool,
    d: i64,
    text: String,
}

let align_of_foo = mem::align_of::<Foo>();
assert_eq!(align_of_foo, 8);
```

结果仍然是 8，既可能来自 `i64`，也可能来自 `String`。`String` 以 `Vec<u8>` 为
基础，内部含有机器字长的字段；在我的 64 位机器上，`usize` 占 8 字节，因此这个
结果也说得通。

不过坦白说，我目前还真不太关心这两个函数。

## `discriminant`

到这里开始有意思了。`discriminant` 文档的意思是：返回一个能够唯一标识值所属枚举
变体的值。

返回的是不透明类型，但可以把它当作各枚举变体的唯一标识。在只想比较变体、并不
关心内部数据时，它相当实用，我以后大概会经常用到它。

假设有这样一个枚举：

```rust
struct Uncomparable {
    a: i32,
}

enum MyEnum {
    A(u32),
    B(u32, u32),
    C(Uncomparable),
}
```

现在要判断两个 `MyEnum` 值是否属于同一变体。注意，不是比较两个值是否相等，只看
它们是不是同一种变体。用 `match` 当然可以：

```rust
match (a, b) {
    (MyEnum::A(_), MyEnum::A(_)) => true,
    (MyEnum::B(_, _), MyEnum::B(_, _)) => true,
    (MyEnum::C(_), MyEnum::C(_)) => true,
    _ => false,
}
```

不过我们还可以直接用 `discriminant` 比较变体：

```rust
let a = MyEnum::A(1);
let b = MyEnum::B(1, 2);
let c = MyEnum::B(64, 48);

let a_same_of_b = mem::discriminant(&a) == mem::discriminant(&b);
assert_eq!(a_same_of_b, false);
let b_same_of_c = mem::discriminant(&b) == mem::discriminant(&c);
assert_eq!(b_same_of_c, true);
```

到目前为止，`discriminant` 是最让我惊喜的一个。明明很实用，我以前却从未见人用过。

## `forget`

`forget` 可能稍微出名一些，因为它允许你**泄漏内存**，尽管真正需要泄漏一个值时，
通常更应该考虑 `Box::leak`。

它取得值的所有权，却不运行这个值的析构逻辑，就好像把它彻底忘掉一样。这个值永远
不会被销毁，它持有的资源也会随之泄漏。

```rust
let leaked = 1u32;
mem::forget(leaked);
```

这有什么用？一个实际场景是把文件描述符移交给 C 代码：在 Rust 中打开 `File`，
把描述符交给 C，然后让 Rust 忘掉原来的 `File`。此后，关闭描述符就是 C 代码的
责任。

```rust
use std::fs::File;
use std::mem;
use std::os::unix::io::AsRawFd;

fn main() {
    let file = File::open("foo.txt").unwrap();
    let fd = file.as_raw_fd();
    mem::forget(file);

    // 现在可以把 fd 传给 C 代码
}
```

## `needs_drop`

对类型 `T` 调用 `needs_drop`，如果 `T` 需要执行析构，它会返回 `true`，否则返回
`false`。

等等，什么叫一个值不需要析构？我原以为所有值都要被销毁。

不妨猜猜下面的结果是 `true` 还是 `false`：

```rust
mem::needs_drop::<i32>()
```

答案是 **`false`**。

那么 `String` 呢？

```rust
mem::needs_drop::<String>()
```

这次是 `true`。

换成结构体：

```rust
struct ToDrop {
    a: i32,
}

assert_eq!(mem::needs_drop::<ToDrop>(), false);
```

结果又是 `false`，除非我们为它实现 `Drop`：

```rust
struct ToDrop {
    a: i32,
}

impl Drop for ToDrop {
    fn drop(&mut self) {
        println!("正在析构 ToDrop");
    }
}

assert_eq!(mem::needs_drop::<ToDrop>(), true);
```

因此，只要一个类型本身实现了 `Drop`，或者它包含的任意层级字段需要执行 `Drop`，
这个类型就需要析构。最终常常能追溯到在堆上管理资源的类型，例如 `String` 或
`Vec`，它们都实现了 `Drop`。

## `size_of` 与 `size_of_val`

这两个函数比较直观，分别返回类型 `T` 和某个 `T` 类型值所占的字节数。

```rust
let size_of_i32 = mem::size_of::<i32>();
assert_eq!(size_of_i32, 4);
```

结构体的大小又是多少？

```rust
#[repr(C)]
struct Foo {
    a: i32,
    b: i32,
    c: bool,
    d: i64,
    text: String,
}

let size_of_foo = mem::size_of::<Foo>();
#[cfg(target_pointer_width = "64")]
assert_eq!(size_of_foo, 48);
```

在常见的 64 位目标上，结果是 48。字段大小加起来是 4 + 4 + 1 + 8 + 24
（`String` 的大小），也就是 41 字节。`#[repr(C)]` 要求字段保持声明顺序；为了让
`i64` 和整个结构体按 8 字节对齐，编译器会在 `bool` 后加入 7 字节填充，最终得到
48 字节。没有 `#[repr(C)]` 时，Rust 不保证字段顺序，这套计算也就不能用来解释
所有编译器和目标平台上的结果。

## 进入 `unsafe` 王国

小心，从这里起，我们要踏进 **Corro——unsafe Rust 小刺猬** 的领地了。

![守卫 unsafe Rust 王国的 Corro](./corro.webp)

接下来的内容请谨慎对待。

### `transmute`

`transmute` 会**把一种类型的值所含的位重新解释成另一种类型**。这个函数威力很大，
也很容易制造混乱，好在编译器能够挡住一部分灾难性错误。

最基本的规则是：**源类型和目标类型的大小必须相同**。

先看一个很简单的例子：

```rust
struct Bar {
    a: i32,
    b: i32,
}

struct Baz {
    a: i32,
    b: i32,
}

let bar = Bar { a: 1, b: 2 };
let baz = unsafe { mem::transmute::<Bar, Baz>(bar) };
assert_eq!(baz.a, 1);
assert_eq!(baz.b, 2);
```

如果 `Baz` 多一个字段，代码甚至无法通过编译：

```rust
struct Bar {
    a: i32,
    b: i32,
}

struct Baz {
    a: i32,
    b: i32,
    c: i32,
}

let bar = Bar { a: 1, b: 2 };
let baz = unsafe { mem::transmute::<Bar, Baz>(bar) };
```

```text
cannot transmute between types of different sizes, or dependently-sized types
source type: `Bar` (64 bits)
target type: `Baz` (96 bits)
```

不过，即使大小相同，也很容易写出有问题的代码：

```rust
struct Bar {
    a: i32,
    b: i32,
}

struct Baz {
    b: i32,
    a: i32,
}

let bar = Bar { a: 1, b: 2 };

let baz = unsafe { mem::transmute::<Bar, Baz>(bar) };
assert_eq!(baz.a, 1); // 不对，这里是 2
assert_eq!(baz.b, 2); // 不对，这里是 1
```

显然，字段顺序也必须一致。结构体的破坏性变更，哪怕只是重新排列字段，都可能让这段
代码失效。

有人可能会想到用它扩展结构体。例如，某个库公开了 `Foo`，我们想增加几个方法，
于是创建 `FooExt`，再把它转换成 `Foo` 来调用原有方法。

可一旦库修改结构体，我们的代码就可能崩坏。更好的方式是让 `FooExt` 包装 `Foo`：

```rust
struct FooExt(Foo);
```

编译器只检查结构体总大小吗？如果两种类型不同，但大小加起来一样，会怎样？

```rust
struct Bar {
    a: u16,
}

struct Baz {
    b: u8,
    a: u8,
}

let bar = Bar { a: 65535 };

let baz = unsafe { mem::transmute::<Bar, Baz>(bar) };
assert_eq!(baz.a, 255);
assert_eq!(baz.b, 255);
```

这段代码可以通过，因为两种类型的总大小都是 2 字节。编译器只在意大小，并不要求
字段类型相同。

这个值被拆成 `u8` 后，每个字段接收一个字节，效果类似移位。这里原值两个字节都是
`255`，所以看不出字节序差异。`u8::from_le_bytes`、`u8::from_ne_bytes` 这类安全的
字节转换 API 更适合这类操作；具体到拆分这里的 `u16`，可以使用
`u16::to_le_bytes` 或 `u16::to_ne_bytes`。因此，这并不是 `transmute` 的好用法。

Rust 官方文档提到，现实中它主要用于少数几类操作：

- 在满足平台布局前提时，将数据指针转换成函数指针；不同平台的数据指针与函数指针
  大小可能不同，因此必须特别检查约束
- 延长或缩短不变生命周期；这个技巧很酷，但显然也非常危险

  ```rust
  struct R<'a>(&'a i32);
  unsafe fn extend_lifetime<'b>(r: R<'b>) -> R<'static> {
      std::mem::transmute::<R<'b>, R<'static>>(r)
  }

  unsafe fn shorten_invariant_lifetime<'b, 'c>(r: &'b mut R<'static>)
                                               -> &'b mut R<'c> {
      std::mem::transmute::<&'b mut R<'static>, &'b mut R<'c>>(r)
  }
  ```

最后还要提醒一句：只要没有使用 `#[repr(C)]`，Rust 编译器就可以自由调整结构体字段
的布局。因此，即便是前面那个看似简单的例子，字段也可能被重新排序。

### `zeroed` 与 `MaybeUninit`

最后来看 `zeroed`。它会创建一个所有位都为零的 `T` 类型值。

有些 FFI 场景需要把全零初始化的值传给 C 代码，这时它可能派上用场；但一般来说，
应该避免使用它。

```rust
let x: i32 = unsafe { mem::zeroed() };
assert_eq!(x, 0);
```

结构体又如何？

```rust
struct Baz {
    b: u8,
    a: u8,
}

let baz: Baz = unsafe { mem::zeroed() };
assert_eq!(baz.a, 0);
assert_eq!(baz.b, 0);
```

这个结构体的所有字段都允许全零位模式，因此代码有效。如果结构体里有 `String` 呢？

```rust
struct ZeroingString {
    a: u8,
    text: String,
}
```

这就不行了。`String` 内部含有 `std::ptr::NonNull<u8>`，把指针的所有位清零，相当于
把它设为 `NULL`；对 `String` 来说，这不是有效状态。用 `mem::zeroed` 创建这样的值
会立即触发未定义行为，绝不能依赖编译器替我们处理。某些工具链可能在运行时主动
终止程序，并显示类似下面的 panic，但这不是 Rust 保证的安全检查：

```text
thread 'main' panicked at library/core/src/panicking.rs:218:5:
attempted to zero-initialize type `ZeroingString`, which is invalid
```

`zeroed` 与 `MaybeUninit` 关系密切。`MaybeUninit` 允许先创建尚未初始化的 `T`，从而
不必为了占据一块内存而先构造普通的 `T` 值。

例如，下面两种写法等价：

```rust
let a: i32 = unsafe { mem::zeroed() };
let b: i32 = unsafe { mem::MaybeUninit::zeroed().assume_init() };
```

`MaybeUninit` 也广泛用于配合 `std::ptr` 处理指针。例如：

```rust
let null_ptr: *const i32 = std::ptr::null();
// 实际上等价于
let null_ptr = unsafe { MaybeUninit::<*const i32>::zeroed().assume_init() };
```

## 写在最后

每次深入标准库，我都会惊讶于自己还有这么多东西可学。`std::mem` 虽然有些冷门，
却藏着不少实用函数：有些能让常规所有权操作更顺手，有些则直接触及 Rust 内存布局
和 `unsafe` 的边界。

希望这次 `std::mem` 漫游也让你发现了几个新工具。如果你有问题或想法，欢迎留言；
也可以在 Mastodon 上关注我：
[@veeso_dev@hachyderm.io](https://hachyderm.io/@veeso_dev)。
