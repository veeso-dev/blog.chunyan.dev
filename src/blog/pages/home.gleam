//// Homepage with the author's bio and latest Rust posts.

import blog/components
import blog/components/container
import blog/components/heading
import blog/components/post_preview
import blog/site
import blog/template/page
import blogatto/post
import gleam/dict
import gleam/list
import gleam/option
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// Render the homepage with the author's bio and the four latest posts.
pub fn home(posts: List(post.Post(Nil))) -> Element(Nil) {
  let url = site.origin <> "/"
  let config =
    page.PageConfig(
      title: "春晏的 Rust 博客 | chunyan.dev",
      description: "春晏的 Rust 开发笔记：从所有权、异步编程到性能优化，分享实际项目中的经验、踩坑和解决办法。",
      url:,
      featured_image: option.Some(site.origin <> "/og_preview.jpeg"),
      page_type: "website",
      structured_data: option.Some(page.website_structured_data(url)),
      noindex: False,
    )

  page.page(config, [page_content(posts)], element.none())
}

fn page_content(posts: List(post.Post(Nil))) -> Element(Nil) {
  element.fragment([
    heading.h1(dict.new(), "", [element.text("春晏的 Rust 开发笔记")]),
    bio(),
    latest_posts(posts),
  ])
}

fn bio() -> Element(Nil) {
  container.responsive_row(
    ["items-center", "justify-between", "gap-8", "p-10"],
    [
      html.div([], [
        html.img([
          attribute.src("/avatar.webp"),
          attribute.alt("春晏的头像"),
          attribute.loading("eager"),
          components.classes(["rounded-full", "h-auto", "w-[128px]"]),
        ]),
      ]),
      html.div([attribute.class("flex-1")], [
        html.p(
          [
            components.classes([
              "text-brand",
              "w-full",
              "mb-3",
              "text-justify",
              "dark:text-gray-200",
            ]),
          ],
          [
            element.text(
              "你好，我是春晏（Christian Visintin），住在意大利乌迪内，是一名自由软件工程师，也做开源项目。这里专门聊 Rust：写代码时踩过的坑、折腾出来的东西，还有一些可能没必要、但我还是想说的看法。",
            ),
          ],
        ),
      ]),
    ],
  )
}

fn latest_posts(posts: List(post.Post(Nil))) -> Element(Nil) {
  let latest_posts = list.take(posts, 4)

  html.div([], [
    heading.h2(dict.new(), "", [element.text("最新文章")]),
    html.div(
      [components.classes(["grid", "grid-cols-2", "gap-x-4", "sm:grid-cols-1"])],
      list.map(latest_posts, post_preview.post_preview),
    ),
  ])
}
