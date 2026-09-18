---
date: "2026-09-18 08:00:00 +02:00"
slug: "rust-trait-object-or-generics"
title: "Rust 结构体中该用 trait 对象还是泛型"
description: "在 Rust 结构体中存放不同 trait 实现时，比较 Box<dyn Trait>、泛型和枚举封装在条件类型、性能与库 API 上的取舍。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '5'
---

假设我们有一个 `Greet` trait，以及两种不同的实现：

```rust
trait Greet {

  fn greet(&self) -> String;

}

struct Alice;

impl Greet for Alice {
  fn greet(&self) -> String {
    "Hello".to_string()
  }
}

struct Carlo;

impl Greet for Carlo {
  fn greet(&self) -> String {
    "Ciao".to_string()
  }
}

// ...

struct User {
  greet: Greet
}

// ...

let greet = Alice;

let user = User { greet };
```

很多 Rust 开发者都试过类似的写法：想把动态类型直接放进数据结构。
通常有两条路可走：使用 `Box<dyn Trait>`，或者使用泛型。

问题是，哪一种更合适？如果具体类型还要根据运行时条件决定，又该怎么处理？

## 为什么不能直接存放 trait

上面的 `User` 把 `Greet` 当成了字段类型：

```rust
struct User {
  greet: Greet // <-- 这里的 Greet 是一个 trait
}
```

trait 本身不是可以直接放进结构体的具体类型，因此编译器会报错：

```txt
error[E0782]: expected a type, found a trait
  --> src/main.rs:26:3
   |
26 |   greet: Greet
   |   ^^^^^
   |
help: you can add the `dyn` keyword if you want a trait object
   |
26 |   greet: dyn Greet
   |   +++
```

接下来可以选择 `Box<dyn Greet>`，也可以让 `User` 变成泛型结构体。

### 用 `Box<dyn Greet>` 保存 trait 对象

最直接的办法是用 `Box` 包住 `Greet` trait 对象：

```rust
struct User {
  greet: Box<dyn Greet>,
}

let greet = Alice;
let user = User { greet: Box::new(greet) };
```

![一只黑猫从纸箱里探出头](./cat-box.gif)

这段代码能工作，但它未必总是最好的方案。另一种选择是泛型。

### 用泛型保存具体类型

把 `User` 写成泛型后，可以让字段直接持有实现了 `Greet` 的具体类型：

```rust
struct User<T>
where T: Greet
{
  greet: T,
}

let greet = Alice;
let user = User { greet };
```

单看这段代码没有问题，麻烦出现在具体类型需要由条件决定时。

## 泛型遇到条件类型

如果程序要根据名字选择不同的 `Greet` 实现，可能会自然地写出下面的代码：

```rust
let user = match name {
    "carlo" => User { greet: Carlo },
    "alice" => User { greet: Alice },
    _ => panic!("Unknown user"),
};
```

这无法通过编译，因为同一个 `user` 变量不能既是 `User<Carlo>`，又是
`User<Alice>`：

```txt
error[E0308]: `match` arms have incompatible types
  --> src/main.rs:36:20
   |
34 |       let user = match name {
   |  ________________-
35 | |         "carlo" => User { greet: Carlo },
   | |                    --------------------- this is found to be of type `User<Carlo>`
36 | |         "alice" => User { greet: Alice },
   | |                    ^^^^^^^^^^^^^^^^^^^^^ expected `User<Carlo>`, found `User<Alice>`
37 | |     };
   | |_____- `match` arms have incompatible types
   |
   = note: expected struct `User<Carlo>`
              found struct `User<Alice>`
```

若字段使用 `Box<dyn Greet>`，两个分支产生的 `User` 类型相同，这个问题就不存在：

```rust
let user = match name {
    "carlo" => User { greet: Box::new(Carlo) },
    "alice" => User { greet: Box::new(Alice) },
    _ => panic!("Unknown user"),
};
```

看起来，条件类型似乎只能靠 `Box<dyn Greet>` 解决。其实泛型还有另一种写法。

## 用枚举封装泛型类型

我们可以定义一个枚举来容纳所有可能的 `Greet` 实现，再让这个枚举本身实现
`Greet`：

```rust
enum MyGreet {
    Alice(Alice),
    Carlo(Carlo),
}

impl MyGreet {
    /// 用对应的 [`Greet`] 实现调用给定闭包
    fn on_greet<F, T>(&self, f: F) -> T
    where
        F: FnOnce(&dyn Greet) -> T,
    {
        match self {
            Self::Alice(v) => f(v),
            Self::Carlo(v) => f(v),
        }
    }
}


impl Greet for MyGreet {
    fn greet(&self) -> String {
        self.on_greet(|greet| greet.greet())
    }
}

let user = match name {
    "carlo" => User { greet: MyGreet::Carlo(Carlo) },
    "alice" => User { greet: MyGreet::Alice(Alice) },
    _ => panic!("Unknown user"),
};
```

这段代码能够编译。两个方案都能达到目标，但它们在灵活性、性能和库 API
设计上有重要区别。为了比较方便，下面假设这个包含动态实现的类型会由一个库
公开给使用者。

## `Box<dyn Trait>` 与泛型封装如何选择

### 灵活性

泛型以及泛型的枚举封装允许我们编写更多定制逻辑。不过，如果枚举内部类型还要
满足额外的 trait bound，封装就可能变得复杂。有时动态数据里会包含多个泛型，
甚至事先无法确定会有哪些具体类型。在这些情况下，更适合使用 `Box<dyn Trait>`。

### 性能

两种方案各有代价，而且运行速度与二进制体积需要分开比较：

- 泛型使用静态分发，没有虚函数调用的间接开销，编译器也有更多内联和优化空间。
  不过，编译器需要为不同具体类型生成专门代码，可能增大最终二进制。
- `Box<dyn Trait>` 通常需要堆分配和动态分发，热点路径上可能更慢，但类型擦除能减少
  重复生成的代码，因此有时有利于控制二进制体积。

因此，这里没有脱离场景的胜者。关注运行时性能时，应当以真实负载做基准测试；
关注二进制体积时，也要实际比较构建产物，不能只根据分发方式下结论。

### 库 API

设计开源库的公开 API 时，还要站在库使用者的角度考虑。假设库需要暴露类似
下面的类型：

```rust
struct Data {
  imp: MyTrait
}
```

这种情况下，泛型显然更合适。使用者如果不需要额外的封装，而且只用少量具体
类型，就能同时得到更好的性能和更大的灵活性。

这看上去与前面的性能结论矛盾，但库 API 的常见用法通常比枚举封装简单。具体类型
数量不多时，二进制仍可能较小，同时还能避开动态分发的开销。

## 结论

`Box<dyn Trait>` 写起来更直接，对刚接触 Rust 的开发者尤其如此；在具体类型集合
开放、需要类型擦除或运行时扩展时，它通常也是自然选择。具体类型集合固定、调用处
重视静态分发和内联时，泛型或枚举封装往往更合适。与其规定统一的优先级，不如根据
扩展性、API 形状、运行时性能和二进制体积分别取舍。

值得注意的是，编译器遇到最初那段代码时，通常只会给出这样的提示：

```txt
error[E0782]: expected a type, found a trait
  --> src/main.rs:26:3
   |
26 |   greet: Greet
   |   ^^^^^
   |
help: you can add the `dyn` keyword if you want a trait object
   |
26 |   greet: dyn Greet
   |   +++
```

它没有告诉你，泛型可能更适合这个场景。对新手而言，这个提示很容易把人带向一个
并非最优的方案。我刚开始用 Rust 时，也经常用 `Box<dyn Trait>` 代替泛型。
