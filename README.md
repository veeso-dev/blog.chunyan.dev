# chunyan.dev

你好，我是春晏。这是一个专门聊 Rust 的简体中文个人博客，记录实际开发中的
经验、踩坑和技术思考。

网站使用 [Gleam](https://gleam.run/)、[Lustre](https://lustre.dev/) 和
[Blogatto](https://github.com/veeso/blogatto) 构建，由 Gleam/OTP 生成纯静态站点，
托管在 [Vercel](https://vercel.com/)。

## 技术栈

| 技术                                            | 用途                  |
| --------------------------------------------- | ------------------- |
| [Gleam](https://gleam.run/)                   | 编程语言，编译为 Erlang/OTP |
| [Lustre](https://lustre.dev/)                 | UI 组件框架             |
| [Blogatto](https://github.com/veeso/blogatto) | 静态站点生成器             |
| [Tailwind CSS](https://tailwindcss.com/)      | 样式                  |
| [Vercel](https://vercel.com/)                 | 静态站点托管              |

## 项目结构

```text
blog.chunyan.dev/
├── src/blog.gleam           # 构建入口
├── src/blog/config.gleam    # Blogatto 配置
├── src/blog/site.gleam      # 共享站点身份
├── src/blog/components/     # 可复用 UI 和 Markdown 组件
├── src/blog/pages/          # 首页、文章列表、隐私政策和 404
├── src/blog/template/       # 页面模板、顶栏和页脚
├── blog/                    # Markdown 文章和 frontmatter
├── assets/                  # Tailwind CSS 输入
├── static/                  # favicon、头像和社交预览图
└── dist/                    # 构建输出
```

## 开发

### 前置条件

- [Gleam](https://gleam.run/) 1.18.1 或更高版本。
- [Erlang/OTP](https://www.erlang.org/) 28 或更高版本。
- [just](https://github.com/casey/just)（可选的任务运行器）。

### 命令

```sh
gleam deps download
gleam format --check src test
gleam test
gleam run
just dev
python3 -m unittest discover -s scripts -p 'test_*.py'
```

`gleam run` 会把站点生成到 `./dist`。文章使用
`blog/<post-name>/index.md`，并通过 `/blog/<slug>/` 访问。网站只生成一个简体
中文版本，Rust 语法、crate 名称和命令保持原样。

## 部署

本次内容迁移不改变现有的 Vercel 项目、凭据或部署方式。GitHub Actions 仍沿用
`.github/workflows/deploy.yml` 中已有的构建和部署流程。重新设计部署产物或切换项目
前，应先确认目标项目、域名和 secrets 属于这个中文博客，不要读取或提交 `.env.local`、
token 或其他凭据。

## 许可证

- 代码：[MIT](https://opensource.org/licenses/MIT)。
- 文章和图片：[CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/)。

## 参考资源

- [A Blog in Gleam](https://gearsco.de/blog/blog-in-gleam/)。
- [Blogatto](https://github.com/veeso/blogatto)：使用 Gleam 编写的博客引擎。
- [glailglind](https://hexdocs.pm/glailglind/)：Gleam 的 Tailwind CSS 安装器。
- [webls](https://hexdocs.pm/webls/)：网站地图、robots 和 RSS 工具。
