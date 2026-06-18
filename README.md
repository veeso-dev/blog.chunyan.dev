# blog.chunyan.dev

我的个人博客，使用 [Gleam](https://gleam.run/) 和 [Lustre](https://lustre.dev/) 构建，由 [Blogatto](https://github.com/veeso/blogatto) 驱动。

最初使用 Gatsby 构建，现已迁移为由 Gleam/OTP 生成的纯静态站点。

## 技术栈

| 技术                                            | 用途                   |
| --------------------------------------------- | -------------------- |
| [Gleam](https://gleam.run/)                   | 编程语言（编译为 Erlang/OTP） |
| [Lustre](https://lustre.dev/)                 | UI 组件框架              |
| [Blogatto](https://github.com/veeso/blogatto) | 博客引擎 / 静态站点生成器       |
| [Tailwind CSS](https://tailwindcss.com/)      | 样式                   |
| [Vercel](https://vercel.com/)                 | 托管                   |

## 项目结构

```txt
blog.chunyan.dev/
├── src/blog/                # Gleam 源代码
│   ├── blog.gleam           # 入口与 Blogatto 配置
│   ├── components/          # 可复用 UI 组件
│   ├── pages/               # 首页与博客列表页
│   └── template/            # 页面模板、顶栏、页脚
├── blog/                    # Markdown 文章（含 frontmatter）
├── assets/                  # CSS 源文件（Tailwind 输入）
├── static/                  # 静态文件（favicon、头像、OG 图片）
└── dist/                    # 构建输出（构建后生成）
```

## 开发

### 前置条件

- [Gleam](https://gleam.run/) >= 1.14.0
- [Erlang/OTP](https://www.erlang.org/) >= 28
- [Docker](https://www.docker.com/)（用于本地预览）
- [just](https://github.com/casey/just)（可选的任务运行器）

### 命令

```sh
gleam run       # 将静态站点构建到 ./dist
gleam test      # 运行测试
gleam format    # 格式化代码
just dev        # 启动开发服务器，端口 3000，支持热重载
```

## 部署

站点通过 GitHub Actions 部署到 Vercel：

- **推送到 `main`**：生产环境部署
- **拉取请求（Pull Request）**：预览环境部署

## 许可证

- 代码：[MIT](https://opensource.org/licenses/MIT)
- 内容：[CC-BY-NC-ND-4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/)

## 资源

- [A Blog in Gleam](https://gearsco.de/blog/blog-in-gleam/)
- [blogatto](https://github.com/veeso/blogatto)：使用 Gleam 编写的博客引擎
- [glailglind](https://hexdocs.pm/glailglind/)：Gleam 的 Tailwind CSS 安装器
- [webls](https://hexdocs.pm/webls/)：网站的 Sitemap、robots 与 RSS 订阅源
