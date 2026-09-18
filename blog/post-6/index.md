---
date: "2026-09-18 03:00:00 +02:00"
slug: "rust-ssh-config-parser"
title: "用 Rust 写 SSH 配置解析器，没那么简单"
description: "从匹配优先级、逐行分词到 Include 指令，记录我用 Rust 和 nom 实现 SSH 配置解析器时踩过的坑。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '10'
---

你有没有过这种经历：刚开一个项目时觉得没什么难的，真正动手以后，
才发现自己把问题想简单了？这篇文章讲的就是
[ssh2-config](https://github.com/veeso/ssh2-config) 的实现过程。
它是一个用 Rust 解析 SSH 配置文件的库，这一路还会碰到 `nom`
以及 SSH 配置本身那些不那么符合直觉的规则。

我为什么要写它？因为很多 [termscp](https://github.com/veeso/termscp)
用户都希望直接使用自己的 SSH 配置文件。要支持这个需求，
最直接的办法自然是写一个能解析 SSH 配置的库。

## 我一开始就搞错了

先看一份 SSH 配置：

```txt
User veeso

Host 192.168.1.*
    compression yes
    User foo

Host 192.168.1.1
    User root
    Port 2222
    IdentityFile ~/.ssh/id_rsa
```

从这里很容易看出，SSH 配置既能为具体主机写规则，也能通过模式匹配一组主机。

第一条 `User veeso` 没有放在任何 `Host` 块里，因此对所有主机都有效。
如果连接 `192.168.1.1`，后面的两个 `Host` 块也都会匹配。

问题来了：多个规则冲突时，应该采用哪一个？

正常人的第一反应大概都是“最具体的规则优先”。按这个思路，连接
`192.168.1.1` 时，`User` 应该是 `root`，优先级看起来也应该是
`* < 192.168.1.* < 192.168.1.1`。

![以为最具体的主机规则会胜出的梗图](./for-the-better.webp)

然而答案并不是这样。

SSH 配置根本不关心这套层级。OpenBSD 的 `ssh_config` 手册写得很清楚：

> 除非另有说明，每个参数都会使用最先取得的值。配置文件由 `Host`
> 规则分隔成多个部分，只有主机与规则中的某个模式匹配时，相应部分才会生效。
> 用来匹配的主机名通常就是命令行中提供的名称，但 `CanonicalizeHostname`
> 选项可能改变这一点。
>
> 正因为每个参数都采用最先取得的值，越具体的主机声明越应该放在文件前面，
> 通用默认值则应该放在最后。

而我的解析器直到第 4 个大版本才真正弄明白这件事。

开始实现以前，我是不是应该把文档完整读一遍？当然应该。可我当时只看了开头几行，
就觉得已经足够动手写解析器。偏偏“最具体的规则会覆盖通用规则”又实在太符合直觉，
我便把它当成了不需要验证的事实。最后只能用最费劲的方式补上这堂课。

## 数据结构怎么设计

可以先把配置想成下面这层关系：

`Config -> HostMatch -> Parameters`

接下来从最底层开始看代码。

### 参数

首先需要一个结构体，保存 SSH 配置中可能出现、并且我们准备支持的参数：

```rust
/// 描述 SSH 配置。
/// 配置格式见：<http://man.openbsd.org/OpenBSD-current/man5/ssh_config.5>
/// 这里只实现 libssh2 支持的参数。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostParams {
    pub bind_address: Option<String>,
    pub bind_interface: Option<String>,
    pub ca_signature_algorithms: Algorithms,
    pub certificate_file: Option<PathBuf>,
    pub ciphers: Algorithms,
    pub compression: Option<bool>,
    pub connection_attempts: Option<usize>,
    pub connect_timeout: Option<Duration>,
    pub host_key_algorithms: Algorithms,
    pub host_name: Option<String>,
    pub identity_file: Option<Vec<PathBuf>>,
    pub ignore_unknown: Option<Vec<String>>,
    pub kex_algorithms: Algorithms,
    pub mac: Algorithms,
    pub port: Option<u16>,
    pub pubkey_accepted_algorithms: Algorithms,
    pub pubkey_authentication: Option<bool>,
    pub remote_forward: Option<u16>,
    pub server_alive_interval: Option<Duration>,
    pub tcp_keep_alive: Option<bool>,
    pub user: Option<String>,
    pub ignored_fields: HashMap<String, Vec<String>>,
    pub unsupported_fields: HashMap<String, Vec<String>>,
}
```

### 主机

`Host` 结构体需要保存两类信息：

- 用来匹配主机的规则
- 匹配成功后应该使用的参数

```rust
/// 描述应用于某个主机的规则。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Host {
    /// 参数有效的主机列表。String 是字符串模式，bool 表示条件是否取反。
    pub pattern: Vec<HostClause>,
    pub params: HostParams,
}

/// 描述一条用于匹配主机的子句。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostClause {
    pub pattern: String,
    pub negated: bool,
}
```

`HostClause` 保存待匹配的模式，以及这个条件是否取反。模式本身是字符串，
可以是主机名、IP 地址，也可以是通配符模式。

然后为它实现 `intersects`，判断主机是否与模式匹配：

```rust
impl Host {
    /// 返回 `host` 参数是否与主机子句相交。
    pub fn intersects(&self, host: &str) -> bool {
        let mut has_matched = false;
        for entry in self.pattern.iter() {
            let matches = entry.intersects(host);
            // 如果取反的条目匹配成功，就不必继续搜索。
            if matches && entry.negated {
                return false;
            }
            has_matched |= matches;
        }
        has_matched
    }
}

impl HostClause {
    /// 返回 `host` 参数是否与当前子句相交。
    pub fn intersects(&self, host: &str) -> bool {
        WildMatch::new(self.pattern.as_str()).matches(host)
    }
}
```

### SSH 配置

最顶层的结构就是 `SshConfig`。它持有一个 `Vec<Host>`，保存所有可能匹配主机的规则，
每个主机条目由自己的匹配模式标识。

```rust
/// 描述 SSH 配置。
/// 配置格式见：<http://man.openbsd.org/OpenBSD-current/man5/ssh_config.5>
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SshConfig {
    /// 主机规则集。
    /// 默认配置使用键 `*` 保存。
    hosts: Vec<Host>,
}
```

这里主要需要两个方法。一个负责从文件中解析配置：

```rust
pub fn parse(mut self, reader: &mut impl BufRead) -> SshParserResult<Self> {
    parser::SshConfigParser::parse(&mut self, reader).map(|_| self)
}
```

另一个负责查询某个主机的参数：

```rust
pub fn query<S: AsRef<str>>(&self, pattern: S) -> HostParams {
    let mut params = HostParams::new(&self.default_algorithms);
    // 从上到下遍历键，只覆盖尚未设置的值。
    for host in self.hosts.iter() {
        if host.intersects(pattern.as_ref()) {
            debug!(
                "Merging params for host: {:?} into params {params:?}",
                host.pattern
            );
            params.overwrite_if_none(&host.params);
            trace!("Params after merge: {params:?}");
        }
    }
    // 返回计算出的参数。
    params
}
```

`query` 先创建一份默认的 `HostParams`，然后依次遍历所有主机规则。
如果传入的模式与某条主机规则相交，就用这条规则补上当前参数中尚未设置的值。

这里**绝不能**覆盖已经设置的参数，因为 SSH 采用的是最先取得的值。

还有一个同样重要的要求：主机条目必须按文件中的先后顺序保存在 `Vec` 里。
只有保持从上到下的顺序，最先取得的值才真的是文件中最早出现的值。
如果某条规则更具体，就应该由配置文件的作者把它放在前面。

数据结构准备好以后，终于可以实现解析器本身了。这个解析器叫作
`SshConfigParser`，位于 `parser` 模块中。

## 实现解析器

先搭出 `parse` 函数：

```rust
pub fn parse(
    config: &mut SshConfig,
    reader: &mut impl BufRead,
) -> SshParserResult<()> {
  // ...
}
```

解析过程需要逐行读取文件。任何包含有效参数的行，都必须归到当前
`Host` 的参数里。

所以第一步是创建初始的 `Host`。由于它不属于任何 `Host` 块，匹配模式应该是
`*`，也就是匹配所有内容：

```rust
config.hosts.push(Host::new(
    vec![HostClause::new(String::from("*"), false)],
    HostParams::new(),
));

// 取得当前主机的指针。
let mut current_host = config.hosts.last_mut().unwrap();
```

接着开始逐行遍历：

```rust
let mut lines = reader.lines();
// 遍历每一行。
loop {
    let line = match lines.next() {
        None => break,
        Some(Err(err)) => return Err(SshParserError::Io(err)),
        Some(Ok(line)) => Self::strip_comments(line.trim()),
    };
    if line.is_empty() {
        continue;
    }
    // 分词。
    let (field, args) = match Self::tokenize_line(&line) {
        Ok((field, args)) => (field, args),
        Err(SshParserError::UnknownField(field, args))
            if rules.intersects(ParseRule::ALLOW_UNKNOWN_FIELDS)
                || current_host.params.ignored(&field) =>
        {
            current_host.params.ignored_fields.insert(field, args);
            continue;
        }
        Err(SshParserError::UnknownField(field, args)) => {
            return Err(SshParserError::UnknownField(field, args));
        }
        Err(err) => return Err(err),
    };
    // 如果字段开启了新块，就初始化这个块。
    if field == Field::Host {
        // 把全局覆盖项中的 `ignore_unknown` 继续传给分词器。
        let mut params = HostParams::new(&config.default_algorithms);
        params.ignore_unknown = config.hosts[0].params.ignore_unknown.clone();
        let pattern = Self::parse_host(args)?;
        trace!("Adding new host: {pattern:?}",);

        // 添加新主机。
        config.hosts.push(Host::new(pattern, params));
        // 更新当前主机的指针。
        current_host = config.hosts.last_mut().unwrap();
    } else {
        // 更新字段。
        match Self::update_host(
            field,
            args,
            current_host,
            rules,
            &config.default_algorithms,
        ) {
            Ok(()) => Ok(()),
            // 如果允许解析不支持的字段，就把它们加入映射。
            Err(SshParserError::UnsupportedField(field, args))
                if rules.intersects(ParseRule::ALLOW_UNSUPPORTED_FIELDS) =>
            {
                current_host.params.unsupported_fields.insert(field, args);
                Ok(())
            }
            // 在这里吞掉错误，避免这次修改破坏 API。
            // 仅仅因为库不支持某个字段，就对正确的 ssh_config 报错也很奇怪。
            Err(SshParserError::UnsupportedField(_, _)) => Ok(()),
            e => e,
        }?;
    }
}

// 最后返回 Ok。
Ok(())
```

### 对配置行分词

配置行的分词比看起来更麻烦，因为下面这些参数写法都必须支持：

- `Field value`
- `Field=value`
- `Field = value`
- `Field "hello world"`，用引号转义空格
- `Field="hello world"`

也就是说，字段和值之间可以用等号、空格，或者两者一起分隔。
而且字段前面还可能带任意缩进。

````rust
/// 尽可能对一行分词，返回 [`Field`] 名称和由 [`String`] 组成的参数 [`Vec`]。
///
/// 下面这些行都可以正确分词。
///
/// ```txt
/// IgnoreUnknown=Pippo,Pluto
/// ConnectTimeout = 15
/// Ciphers "Pepperoni Pizza,Margherita Pizza,Hawaiian Pizza"
/// Macs="Pasta Carbonara,Pasta con tonno"
/// ```
///
/// 因此行语法包括 `field args...`、`field=args...`、`field "args"`
/// 和 `field="args"`。
fn tokenize_line(line: &str) -> SshParserResult<(Field, Vec<String>)> {
    // 看空格和 `=` 哪一个先出现。
    let trimmed_line = line.trim();
    // 第一个词元是字段，可以由空格或 `=` 与后续内容分隔。
    let (field, other_tokens) = if trimmed_line.find('=').unwrap_or(usize::MAX)
        < trimmed_line.find(char::is_whitespace).unwrap_or(usize::MAX)
    {
        trimmed_line
            .split_once('=')
            .ok_or(SshParserError::MissingArgument)?
    } else {
        trimmed_line
            .split_once(char::is_whitespace)
            .ok_or(SshParserError::MissingArgument)?
    };

    trace!("tokenized line '{line}' - field '{field}' with args '{other_tokens}'",);

    // 其他词元需要去掉 `=` 和空白。
    let other_tokens = other_tokens.trim().trim_start_matches('=').trim();
    trace!("other tokens trimmed: '{other_tokens}'",);

    // 参数被引号包围时，不要再拆分。
    let args = if other_tokens.starts_with('"') && other_tokens.ends_with('"') {
        trace!("quoted args: '{other_tokens}'",);
        vec![other_tokens[1..other_tokens.len() - 1].to_string()]
    } else {
        trace!("splitting args (non-quoted): '{other_tokens}'",);
        // 按空白拆分。
        let tokens = other_tokens.split_whitespace();

        tokens
            .map(|x| x.trim().to_string())
            .filter(|x| !x.is_empty())
            .collect()
    };

    match Field::from_str(field) {
        Ok(field) => Ok((field, args)),
        Err(_) => Err(SshParserError::UnknownField(field.to_string(), args)),
    }
}
````

是不是很有趣？

接下来还要实现 `update_host`，用新读到的参数更新当前主机：

```rust
fn update_host(
    field: Field,
    args: Vec<String>,
    host: &mut Host,
    rules: ParseRule,
    default_algos: &DefaultAlgorithms,
) -> SshParserResult<()> {
    trace!("parsing field {field:?} with args {args:?}",);
    let params = &mut host.params;
    match field {
        Field::BindAddress => {
            let value = Self::parse_string(args)?;
            trace!("bind_address: {value}",);
            params.bind_address = Some(value);
        }
        // ...
    }
}
```

每种参数还需要一个解析函数，把 `Vec<String>` 转成对应类型。
例如 `BindAddress` 只需要一个简单的字符串：

```rust
/// 解析字符串参数。
fn parse_string(args: Vec<String>) -> SshParserResult<String> {
    if let Some(s) = args.into_iter().next() {
        Ok(s)
    } else {
        Err(SshParserError::MissingArgument)
    }
}
```

其他类型也各有各的处理方式。例如布尔值需要把 `yes` 解析成 `true`，
把 `no` 解析成 `false`。做到这里，我们已经可以读取 SSH 配置文件，
并查询某个主机对应的参数了。

可惜还有一个问题：`Include` 指令。

## `Include` 指令

`Include` 是一条特殊指令，它允许主配置文件引入其他 SSH 配置文件。

它接受文件路径或 glob 模式，然后引入所有匹配的文件。至于这些参数怎么生效，
好消息也好，坏消息也罢，它的行为就像被引入文件中的内容原地替换了
`Include` 指令。

因此，在 `update_host` 中遇到 `Include` 时，可以这样处理：

```rust
Field::Include => {
    Self::include_files(args, host, rules)?;
}
```

具体做法是逐个打开匹配的文件，把它解析成新的 `SshConfig`，
再将其中的参数合并到当前主机：

```rust
/// 解析并引入文件，再把读到的配置合并到当前主机的规则中。
fn include_files(
    args: Vec<String>,
    host: &mut Host,
    rules: ParseRule,
) -> SshParserResult<()> {
    let path_match = Self::parse_string(args)?;
    trace!("include files: {path_match}",);
    let files = glob(&path_match)?;

    for file in files {
        let file = file?;
        trace!("including file: {}", file.display());
        let mut reader = BufReader::new(File::open(file)?);
        let mut sub_config = SshConfig::default();
        Self::parse(&mut sub_config, &mut reader, rules)?;

        // 把子配置合并到当前主机。
        for pattern in &host.pattern {
            if pattern.negated {
                trace!("excluding sub-config for pattern: {pattern:?}",);
                continue;
            }
            trace!("merging sub-config for pattern: {pattern:?}",);
            let params = sub_config.query(&pattern.pattern);
            host.params.overwrite_if_none(&params);
        }
    }

    Ok(())
}
```

## 还有哪些内容没展开

有两部分实现没有在本文细讲：

- `Algorithms` 结构体封装了 `Vec<String>`，并提供了一些辅助方法，
  用于解析 SSH 配置中的算法。SSH 配置会把算法写成逗号分隔的列表，
  还可以通过前缀指定这些算法是替换默认列表、插到开头、追加到末尾，
  还是从默认列表中排除。
- **默认算法**也是绕不开的问题。只要处理 SSH 配置中的算法，就必须知道默认值。
  可是没有任何与 OpenSSH 交互的 Rust 库会暴露这些信息。我的解决办法是再写一个
  C 头文件解析器，从 OpenSSH 仓库解析最新的宏定义。这个办法有点取巧，
  但确实能用，而且我认为这是唯一可行的做法。

## 结语

这篇文章梳理了用 Rust 实现 SSH 配置解析器时最关键的部分：主机规则并不按具体程度
决定优先级，解析器必须保留文件顺序并坚持“最先取得的值优先”；配置行又允许多种
分隔与引号写法，`Include` 还要求把其他文件的内容视为在当前位置展开。

希望这些实现细节对你有用，也希望你不必再像我一样，把同一条规则踩到第 4 个大版本
才真正弄明白。
