# 项目协作指南

这是 chunyan.dev 的简体中文 Rust 博客，使用 Gleam、Lustre 和 Blogatto
生成纯静态网站，部署到 Vercel。它是独立的中文版本，不是
[blog.veeso.dev](https://blog.veeso.dev/) 的自动镜像；后者只作为写作风格参考。

## 常用命令

```sh
gleam deps download
gleam run
gleam test
gleam format
gleam format --check src test
just dev
```

`gleam run` 将网站构建到 `./dist`，`just dev` 在 3000 端口启动带实时重载的
开发服务器。发布前需要同时运行 Gleam 测试、格式检查、构建和 Python 输出测试。

## 代码结构

- `src/blog.gleam` 是构建入口，负责安装 Tailwind、运行 Blogatto 并编译 CSS。
- `src/blog/config.gleam` 配置 Markdown 目录、静态资源、页面、RSS、Atom、站点地图和 robots.txt。
- `src/blog/site.gleam` 保存站点名称、作者显示名、规范域名、语言和订阅源信息。
- `src/blog/pages/` 包含首页、文章列表、隐私政策和中文 404 页面。
- `src/blog/template/` 包含页面外壳、顶栏、页脚和文章模板。
- `src/blog/components/` 包含布局、文章卡片、日期、图标和 Markdown 渲染组件。
- `blog/` 保存文章；静态资源在 `static/`，Tailwind 输入在 `assets/blog.css`。

## 内容、URL 和语言

文章使用 `blog/<post-name>/index.md` 和 YAML frontmatter。文章路由为
`/blog/<slug>/`，slug 使用稳定的 ASCII 字符串。站点只生成一个简体中文版本，
不要新增语言目录或翻译后缀。当前公开 URL 包括：

- `/`：首页。
- `/blog/`：全部文章。
- `/blog/hello-world/`：欢迎文章。
- `/privacy/`：隐私政策。
- `/rss.xml` 和 `/atom.xml`：订阅源。
- `/sitemap.xml` 和 `/robots.txt`：搜索发现文件。

所有规范 URL 都以 `https://blog.chunyan.dev` 为根，不要使用预览域名作为规范地址。
历史路径只在部署重定向规则中保留，不能把不存在的旧文章批量重定向到首页。

## Rust 编辑范围和写作风格

文章面向中国大陆的 Rust 开发者，从入门者到专家。主题应具体围绕所有权、借用、
生命周期、trait、异步 Rust、性能、Cargo、工具链、Rust 库或实际 Rust 项目经验。
Gleam 只是网站的实现技术，不是博客文章的编辑主题。

写作使用自然的简体中文，直接说明问题，再介绍抽象概念。可以使用“我”和“你”，
保留实验、失败和限制，避免企业宣传、夸张权威、强行网络用语和把 Rust 翻译成
“铁锈”。必要时可首次写成“所有权（ownership）”“借用检查器（borrow checker）”
或“异步 Rust（async Rust）”，crate 名称、命令和代码保持原样。

页面标题、description、图片 alt、导航、订阅源、错误页面和隐私政策都必须使用简体
中文。中文与 Latin 文本混排时检查标点、换行和长 Rust 标识符。注释和 API 标识符
可以保留英文，但面向读者的可见文字不能因此保留英文。

## 页面和元数据约定

- 每个页面只有一个 H1；首页的“最新文章”使用 H2，文章描述使用段落。
- 首页标题是“春晏的 Rust 博客 | chunyan.dev”，文章标题使用“文章标题 | chunyan.dev”。
- HTML 语言为 `zh-CN`，Open Graph locale 为 `zh_CN`，文章日期以 UTC+8 展示。
- 文章日期保留原始时间戳，并同时输出带 ISO 时间的 `time` 元素和 JSON-LD。
- JSON-LD 必须通过 JSON 序列化器生成，并转义脚本数据中的 `<`。
- 图标使用内联 SVG；SVG 图形标记为装饰性内容，图标链接必须有中文 aria-label。
- 文章采用 CC BY-NC-ND 4.0 许可协议，不能添加与它矛盾的“All rights reserved”文字。

代码高亮在构建时由 Blogatto 和 smalto 完成。浏览器端不依赖 Prism、Feather、Google
Fonts、jsDelivr 或分析脚本；深色模式可以使用 JavaScript，但页面正文、导航、日期、
代码和订阅源必须在禁用 JavaScript 时仍然可用。

## 依赖和版本

项目使用 Blogatto 7.x、Lustre 5.x、Tailwind CSS 4.2.1、Gleam 1.18.1 和
Erlang/OTP 28。新增直接依赖时要更新 `gleam.toml`，不要依赖传递导入；锁文件由
Gleam 管理。修改 Gleam、Markdown 或 GitHub Actions 文件时，遵循对应的本地协作
规范并运行完整检查。

## 部署

本次迁移不改变现有 Vercel 项目、凭据或部署方式。部署继续由
`.github/workflows/deploy.yml` 负责；修改部署产物、项目链接、域名或 secrets 前，先
确认目标是这个中文博客而不是旧项目。不要读取或提交 `.env.local`、token 或其他凭据。

## 安全和协作边界

不要修改 `../blog.veeso.dev/`，不要提交 `.superpowers/`、`.vercel/` 或本地环境文件。
不要未经确认打开 GitHub issue；如果创建 Pull Request，默认使用 draft。保留已有的
真实账户链接、邮箱、法律主体和 VAT 信息，不要用站点显示名机械替换它们。
