---
date: "2026-09-18 09:00:00 +02:00"
slug: "rust-leaktracer-memory-debugging"
title: "用 Leaktracer 追踪 Rust 内存分配"
description: "用 GlobalAlloc 实现可嵌入 Rust 应用的内存泄漏追踪器，讲清递归防护、调用符号归因，以及它为何只适合调试。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '11'
---

前几天，我在一个 Rust 应用里碰到了内存问题。项目很大，进程占用的内存
不断增长，累计分配量甚至到了数百 GB，我却一直找不到泄漏来自哪里。

我当然知道 `valgrind`、`heaptrack` 这类工具。不过这次我更想要一个能直接
嵌进应用、接入成本又很低的方案。既然 Rust 允许我们实现自己的分配器，
不妨从这里下手。

现成方案并非没有，只是有的配置过程太长，有的和我的需求并不吻合。于是我写了
一个尽量简单的分配器：记录每次分配和释放，让使用者自行决定如何把结果写入文件，
再做后续分析。这个工具就是 Leaktracer。

## Leaktracer 的设计目标

我给它定了三个目标：

- 追踪所有内存分配与释放。
- 不限制使用者如何导出分配记录。
- 尽可能容易接入现有应用，最好只需要一行关键代码。

## 实现过程

### 定义分配器

第一步是定义 `LeaktracerAllocator`，并为它实现 Rust 的全局分配器 trait
`GlobalAlloc`：

```rust
pub struct LeaktracerAllocator;

impl LeaktracerAllocator {
    pub const fn init() -> Self {
        LeaktracerAllocator
    }
}

unsafe impl GlobalAlloc for LeaktracerAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}
```

这是分配器最基本的骨架。这里最重要的限制是：`init` 必须为 `const fn`，
初始化时不能在堆上分配任何内存。

接下来加入追踪。先不急着区分调用位置，只记录当前分配的总字节数：

```rust
pub struct LeaktracerAllocator {
    allocated: AtomicUsize,
}

impl LeaktracerAllocator {
    pub const fn init() -> Self {
        LeaktracerAllocator {
            allocated: AtomicUsize::new(0),
        }
    }

    /// 返回分配器截至当前仍持有的总字节数。
    pub fn allocated(&self) -> usize {
        self.allocated.load(std::sync::atomic::Ordering::Relaxed)
    }
}

unsafe impl GlobalAlloc for LeaktracerAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            self.allocated.fetch_add(layout.size(), Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) };
        self.allocated.fetch_sub(layout.size(), Ordering::Relaxed);
    }
}
```

这就是能统计总分配量的第一版。`AtomicUsize` 可以在常量上下文中初始化，
所以加入计数器后，`init` 仍然可以保持为 `const fn`。

### 按模块追踪分配

只有总量还不够。我真正想知道的是：每次分配来自哪个模块、哪个函数，
又在何时释放。实现这件事要解决三个问题：

1. 如何在运行时取得模块名和函数名。
2. 如何保存分配记录。
3. 追踪记录本身需要分配内存时，如何避免分配器递归调用自己。

#### 阻止无限递归

先处理第三个问题，因为它最危险。

如果在 `alloc` 里面分配内存，就会再次进入同一个 `alloc`，形成
**无限递归**，最终导致栈溢出。

![两只猫互相舔毛，表示分配器递归调用自己](./recursion.gif)

而且，即使没有立刻崩溃，把追踪器自身产生的分配也算进去，结果也不会准确。

解决办法并不复杂：在线程局部存储中放一个 `Cell<bool>`，记录当前线程是否
正在为追踪工作分配内存。

```rust
thread_local! {
    static IN_ALLOC: Cell<bool> = const { Cell::new(false) };
}

impl LeaktracerAllocator {

  // ...

    /// 返回这次分配是否来自外部。
    ///
    /// “外部分配”指并非由分配器自身请求，而是由分配器使用者请求的分配。
    ///
    /// 判断依据是线程局部变量 `IN_ALLOC` 是否为 `false`。
    fn is_external_allocation(&self) -> bool {
        !IN_ALLOC.get()
    }

    /// 进入分配上下文，标记当前正在执行分配。
    fn enter_alloc(&self) {
        IN_ALLOC.with(|cell| cell.set(true));
    }

    /// 退出分配上下文，标记本次分配已经完成。
    fn exit_alloc(&self) {
        IN_ALLOC.with(|cell| cell.set(false));
    }

  // ...

}
```

这样，`alloc` 和 `dealloc` 只在 `is_external_allocation` 返回 `true` 时
记录操作，也就是忽略分配器自己触发的内存请求。

每条记录还要带一个 `AllocId`。它其实就是把指针转换成 `usize`；稍后会定义
这个类型别名，也会看到为什么释放时需要它。

```rust
impl LeaktracerAllocator {
    // ...

    /// 将指针转换为 [`AllocId`]。
    fn alloc_id_from_ptr(&self, ptr: *mut u8) -> AllocId {
        ptr as AllocId
    }
}

unsafe impl GlobalAlloc for LeaktracerAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // 某些平台（尤其是 macOS）解析符号时会在内部执行分配。
        // 如果已经处于追踪过程，就直接转交给系统分配器。
        if IN_ALLOC.with(|c| c.get()) {
            return unsafe { System.alloc(layout) };
        }

        let ptr = unsafe { System.alloc(layout) };
        // 仅当指针非空且分配来自外部时，才记录这次分配。
        if !ptr.is_null() && self.is_external_allocation() {
            let alloc_id = self.alloc_id_from_ptr(ptr);
            self.trace(alloc_id, layout, AllocOp::Alloc);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        if IN_ALLOC.with(|c| c.get()) {
            return unsafe { System.dealloc(ptr, layout) };
        }

        if !ptr.is_null() && self.is_external_allocation() {
            let alloc_id = self.alloc_id_from_ptr(ptr);
            self.trace(alloc_id, layout, AllocOp::Dealloc);
        }
        unsafe { System.dealloc(ptr, layout) };
    }
}
```

到这里，无限递归的问题就处理掉了。

#### 找到模块名和函数名

运行时取得模块和函数名，可以借助 `backtrace` crate。它能捕获当前调用栈，
也能从栈帧中取出模块与函数符号。最直接的写法类似这样：

```rust
let bt = backtrace::Backtrace::new();

let frame = backtrace
    .frames()
    .first()
    .and_then(|frame| frame.symbols().first())?;

let name_str = symbol.name().map(|name| format!("{name}"))?;
// 去掉名称的最后一段，它通常是一个哈希值。
let name_string = if let Some(pos) = name_str.rfind("::") {
    &name_str[..pos]
} else {
    &name_str
};
```

这算是个起点，但对我们的目标来说其实**完全没用**。

假设 `foo` 调用了 `String::new()`，分配器直接看到的调用者很可能是
`std::alloc::...`。可我既不想把它归因给 `std::alloc`，也不想停在
`String::new`；真正需要找到的是 `foo`。

如果不明确告诉追踪器关心哪些模块，就没有可靠办法挑出这一帧。调用栈可能非常长，
使用 `tokio` 时尤其如此。我们需要在其中找到最后一个匹配目标模块的栈帧。

因此，分配器要接收一组待追踪模块，再用它们筛选回溯记录。我把这部分放进了
`demangle.rs`：

```rust
/// 从反混淆后的名称表中取得符号名称。
pub fn get_demangled_symbol(modules: &[&str]) -> &'static str {
    let bt = backtrace::Backtrace::new();
    let Some(caller) = get_symbol_from_backtrace(&bt, modules) else {
        return UNKNOWN;
    };

    symbol_name(caller).unwrap_or(UNKNOWN)
}

/// 取得回溯中特定栈帧上的符号。
fn get_symbol_from_backtrace<'a>(
    backtrace: &'a backtrace::Backtrace,
    modules: &[&str],
) -> Option<&'a BacktraceSymbol> {
    // 找到名称以目标模块之一开头的最后一个栈帧。
    let frame = backtrace
        .frames()
        .iter()
        .enumerate()
        .find_map(|(index, frame)| {
            let symbol = frame.symbols().first()?;

            let name = symbol.name().map(|name| format!("{name}"))?;

            // 忽略当前调用。
            if IGNORE_LIST.iter().any(|ignore| name.starts_with(*ignore)) {
                return None;
            }

            if modules.iter().any(|module| name.starts_with(*module)) {
                Some(index)
            } else {
                None
            }
        })?;

    backtrace
        .frames()
        .get(frame)
        .and_then(|frame| frame.symbols().first())
}

/// 从 [`BacktraceSymbol`] 中取得符号名称。
fn symbol_name(symbol: &BacktraceSymbol) -> Option<&'static str> {
    // 去掉符号名称的最后一段，例如
    // `backtrace::b::h3777baf656cd0c35`。
    let name_str = symbol.name().map(|name| format!("{name}"))?;

    let name_string = if let Some(pos) = name_str.rfind("::") {
        &name_str[..pos]
    } else {
        &name_str
    };

    // 转换为静态字符串。
    Some(Box::leak(name_string.to_string().into_boxed_str()))
}
```

现在我们能拿到实际调用模块的名称，可以用它为分配记录归类了。

#### 保存分配记录

最后一步是把记录存起来，供之后分析。这里找不到合适的无分配数据结构，
只能使用 `Mutex<HashMap<CallerName, Stats>>`。

不过还有一个容易忽略的问题：只有分配发生时，解析回溯符号才有意义。一个值被
drop 时，当前调用栈几乎不会指回当初创建它的函数，而更可能落在析构函数、`Vec`
扩容逻辑，或者此刻正在释放内存的运行时清理代码上。

要把释放正确归因，我们必须为每个 `AllocId` 记住最初负责分配的符号。
进入 `dealloc` 后直接查表，而不是再解析一次回溯。这样还有一个额外收益：释放路径
快了不少，因为它完全跳过了回溯解析。

我把这些逻辑放进 `symbols.rs`。它导出的 `SymbolTable` 同时保存按符号汇总的
分配数据，以及从 `AllocId` 到所属符号的映射：

```rust
/// 分配标识符的类型别名。
/// 它由 `*mut u8` 指针派生而来。
pub type AllocId = usize;

/// [`Symbol`] 表。
///
/// 每个 [`Symbol`] 都由模块名标识，例如 `leaktracer::alloc`。
#[derive(Debug)]
pub struct SymbolTable {
    /// 当前追踪的模块。
    modules: &'static [&'static str],
    /// 把符号名称映射到对应的 [`Symbol`]。
    symbols: HashMap<&'static str, Symbol>,
    /// 把分配标识符映射到符号，以便释放时快速查询。
    ptr_to_symbol: HashMap<AllocId, &'static str>,
}

impl SymbolTable {
    /// 使用给定容量和模块列表创建新的 [`SymbolTable`]。
    pub(crate) fn new(
        size: usize,
        modules: &'static [&'static str],
    ) -> Self {
        Self {
            modules,
            symbols: HashMap::with_capacity(size),
            ptr_to_symbol: HashMap::with_capacity(size),
        }
    }

    /// 迭代表中的 [`Symbol`] 及其名称。
    pub fn iter(&self) -> impl Iterator<Item = (&&'static str, &Symbol)> {
        self.symbols.iter()
    }

    /// 按名称取得 [`Symbol`]。
    pub fn get(&self, name: &'static str) -> Option<&Symbol> {
        self.symbols.get(&name)
    }

    /// 增加某个 [`Symbol`] 的已分配字节数。
    pub(crate) fn alloc(&mut self, alloc_id: AllocId, bytes: usize) {
        let name = demangle::get_demangled_symbol(self.modules);

        // 符号不存在时，用给定名称创建它。
        if !self.symbols.contains_key(&name) {
            self.insert(name);
        }
        // 记住这次分配属于哪个符号，`dealloc` 就不必再次猜测。
        self.ptr_to_symbol.insert(alloc_id, name);

        let symbol = self.symbols.get_mut(name).expect("符号应当存在");

        symbol
            .allocated
            .fetch_add(bytes, std::sync::atomic::Ordering::Relaxed);
        symbol
            .count
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }

    /// 减少某个 [`Symbol`] 的已分配字节数。
    pub(crate) fn dealloc(&mut self, alloc_id: AllocId, bytes: usize) {
        // 查询当初执行分配的符号，不再重新解析回溯。
        let Some(name) = self.ptr_to_symbol.remove(&alloc_id) else {
            return;
        };

        if let Some(symbol) = self.symbols.get_mut(name) {
            // 使用饱和减法，避免意外或不匹配的释放让计数器下溢。
            symbol
                .allocated
                .fetch_update(
                    std::sync::atomic::Ordering::Relaxed,
                    std::sync::atomic::Ordering::Relaxed,
                    |current| Some(current.saturating_sub(bytes)),
                )
                .ok();
            symbol
                .count
                .fetch_update(
                    std::sync::atomic::Ordering::Relaxed,
                    std::sync::atomic::Ordering::Relaxed,
                    |current| Some(current.saturating_sub(1)),
                )
                .ok();
        }
    }

    /// 向表中插入新的 [`Symbol`]。
    fn insert(&mut self, name: &'static str) {
        self.symbols.insert(
            name,
            Symbol {
                allocated: AtomicUsize::new(0),
                count: AtomicUsize::new(0),
            },
        );
    }
}

/// 符号表中的一个条目。
#[derive(Debug)]
pub struct Symbol {
    /// 这个符号当前已分配的字节数。
    allocated: AtomicUsize,
    /// 这个符号当前持有的分配次数。
    count: AtomicUsize,
}

impl Symbol {
    /// 返回这个符号当前已分配的字节数。
    pub fn allocated(&self) -> usize {
        self.allocated.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// 返回这个符号当前持有的分配次数。
    pub fn count(&self) -> usize {
        self.count.load(std::sync::atomic::Ordering::Relaxed)
    }
}
```

`SymbolTable` 接收待追踪模块的列表。这个列表稍后由使用者提供，因此究竟关注
哪些模块，可以由接入 Leaktracer 的应用自行决定。

### 完成分配器

现在所需组件已经齐全，只要定义 `trace` 相关方法，把每次操作写入符号表：

```rust
    /// 记录一次分配及其内存布局。
    fn trace_allocation(
        &self,
        alloc_id: AllocId,
        layout: Layout,
        table: Option<&mut MutexGuard<SymbolTable>>,
    ) {
        // 先增加已分配字节数。
        self.allocated
            .fetch_add(layout.size(), std::sync::atomic::Ordering::Relaxed);
        if let Some(table) = table {
            table.alloc(alloc_id, layout.size());
        }
    }

    /// 记录一次释放及其内存布局。
    fn trace_deallocation(
        &self,
        alloc_id: AllocId,
        layout: Layout,
        table: Option<&mut MutexGuard<SymbolTable>>,
    ) {
        // 先减少已分配字节数，并用饱和减法避免下溢。
        self.allocated
            .fetch_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |current| Some(current.saturating_sub(layout.size())),
            )
            .ok();
        if let Some(table) = table {
            table.dealloc(alloc_id, layout.size());
        }
    }

    /// 根据 [`AllocOp`] 的类型，用 [`Layout`] 记录分配或释放操作。
    fn trace(&self, alloc_id: AllocId, layout: Layout, op: AllocOp) {
        self.enter_alloc();
        // 锁住符号表，避免死锁。
        let mut lock = SYMBOL_TABLE.get().and_then(|table| table.lock().ok());

        match op {
            AllocOp::Alloc => {
                self.trace_allocation(alloc_id, layout, lock.as_mut())
            }
            AllocOp::Dealloc => {
                self.trace_deallocation(alloc_id, layout, lock.as_mut())
            }
        }
        drop(lock);
        self.exit_alloc();
    }
```

最后再公开初始化分配器和访问符号表的 API：

```rust
/// 使用给定模块和默认容量的符号表初始化内存泄漏追踪器。
///
/// 待追踪模块以静态字符串切片传入。模块列表用于过滤与使用者无关的分配，
/// 例如来自 [`std`]、[`tokio`] 等模块的分配。
pub fn init_symbol_table(modules: &'static [&'static str]) {
    SYMBOL_TABLE.get_or_init(|| {
        Mutex::new(SymbolTable::new(DEFAULT_SYMBOL_TABLE_SIZE, modules))
    });
}

/// 提供线程安全的符号表访问方式。
///
/// 接收闭包 `f`，让它读取符号表并返回结果。
pub fn with_symbol_table<F, R>(
    f: F,
) -> Result<R, PoisonError<std::sync::MutexGuard<'static, SymbolTable>>>
where
    F: FnOnce(&SymbolTable) -> R,
{
    // 在获取锁期间阻止追踪分配。
    IN_ALLOC.with(|cell| cell.set(true));

    let lock = match SYMBOL_TABLE
        .get()
        .expect("符号表尚未初始化")
        .lock()
    {
        Ok(lock) => lock,
        Err(poisoned) => {
            // 解除分配保护。
            IN_ALLOC.with(|cell| cell.set(false));
            // 锁已中毒时，返回对应错误。
            return Err(poisoned);
        }
    };

    let res = Ok(f(&lock));

    IN_ALLOC.with(|cell| cell.set(false));

    res
}
```

### 避免死锁

第一版分配器还有一个问题：使用者持有符号表锁并访问其中数据时，我没有阻止
死锁。如果使用者在持锁期间触发了任何分配，分配器会尝试再次获取同一把锁，
随后一直等待自己。

解决办法是在获取锁之前把 `IN_ALLOC` 设为 `true`，释放锁之后再恢复为
`false`。同时，`trace` 方法的整个执行期间都必须持有互斥锁，避免使用者仍在访问
符号表时，`IN_ALLOC` 已经提前变回 `false`。

## 在应用中使用 Leaktracer

接入应用只需要加入下面这些代码：

```rust
use leaktracer::LeaktracerAllocator;

#[global_allocator]
static ALLOCATOR: LeaktracerAllocator = LeaktracerAllocator::init();

fn main() {
    leaktracer::init_symbol_table(&["my_app", "my_lib"]);

    leaktracer::with_symbol_table(|table| {
        for (name, symbol) in table.iter() {
            tracing::info!(
                "符号：{name}，已分配：{}，次数：{}",
                symbol.allocated(),
                symbol.count()
            );
        }
    })?;
}
```

## 性能表现

性能当然很糟。

真的，启用 **Leaktracer** 后，应用会变得非常慢。它本来就只打算用于极端的
调试场景：内存正在泄漏，而你完全不知道问题发生在哪里。释放比分配明显便宜一些，
因为它只用 `AllocId` 查表，不必解析回溯；但整体开销仍然高得远不适合生产环境。

## 结语

我希望你永远用不上 Leaktracer。不过真遇到常规工具很难定位的 Rust 内存泄漏时，
它也许值得一试。

项目源码可以在 [GitHub](https://github.com/veeso/leaktracer) 找到。
