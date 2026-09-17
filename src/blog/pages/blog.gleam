//// Blog listing page showing all published Rust posts.

import blog/components
import blog/components/heading
import blog/components/post_preview
import blog/site
import blog/template/page
import blogatto/post
import gleam/dict
import gleam/list
import gleam/option
import lustre/element.{type Element}
import lustre/element/html

/// Render the blog listing page with all published posts in a responsive grid.
pub fn blog(posts: List(post.Post(Nil))) -> Element(Nil) {
  let url = site.origin <> "/blog/"
  let config =
    page.PageConfig(
      title: "Rust 文章 | chunyan.dev",
      description: "阅读春晏的 Rust 文章，了解实际开发中的问题、解决思路和项目经验。",
      url:,
      featured_image: option.Some(site.origin <> "/og_preview.jpeg"),
      page_type: "website",
      structured_data: option.None,
      noindex: False,
    )

  page.page(config, [page_content(posts)], element.none())
}

fn page_content(posts: List(post.Post(Nil))) -> Element(Nil) {
  element.fragment([
    heading.h1(dict.new(), "", [element.text("全部 Rust 文章")]),
    html.div(
      [
        components.classes([
          "grid",
          "grid-cols-2",
          "gap-4",
          "sm:grid-cols-1",
          "items-start",
          "justify-start",
        ]),
      ],
      list.map(posts, post_preview.post_preview),
    ),
  ])
}
