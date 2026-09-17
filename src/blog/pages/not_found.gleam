//// Chinese error page for paths that do not exist.

import blog/components
import blog/components/heading
import blog/site
import blog/template/page
import blogatto/post
import gleam/dict
import gleam/option
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// Render the internal page used as the site's HTTP 404 document.
pub fn not_found(_posts: List(post.Post(Nil))) -> Element(Nil) {
  let url = site.origin <> "/404/"
  let config =
    page.PageConfig(
      title: "页面不存在 | chunyan.dev",
      description: "这个页面可能已移动，或者地址有误。",
      url:,
      featured_image: option.Some(site.origin <> "/og_preview.jpeg"),
      page_type: "website",
      structured_data: option.None,
      noindex: True,
    )

  page.page(config, [page_content()], element.none())
}

fn page_content() -> Element(Nil) {
  html.div([components.classes(["flex", "flex-col", "gap-4", "p-8"])], [
    heading.h1(dict.new(), "", [element.text("页面不存在")]),
    html.p([], [element.text("这个页面可能已移动，或者地址有误。")]),
    html.div([components.classes(["flex", "gap-4", "sm:flex-col"])], [
      html.a(
        [
          attribute.href("/"),
          components.classes(["underline", "font-medium"]),
        ],
        [element.text("返回首页")],
      ),
      html.a(
        [
          attribute.href("/blog/"),
          components.classes(["underline", "font-medium"]),
        ],
        [element.text("浏览 Rust 文章")],
      ),
    ]),
  ])
}
