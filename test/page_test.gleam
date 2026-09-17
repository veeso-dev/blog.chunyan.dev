import blog/template/blog as blog_template
import blog/template/page
import blogatto/post
import gleam/dict
import gleam/option
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleeunit
import lustre/element

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn structured_data_escapes_script_delimiters_test() {
  let data =
    page.website_structured_data("https://blog.chunyan.dev/\"</script>")

  assert string.contains(data, "\\\"")
  assert string.contains(data, "\\u003c/script>")
  assert !string.contains(data, "</script>")
}

pub fn article_title_is_safe_in_structured_data_test() {
  let article =
    post.Post(
      title: "标题 \"引用\" </script>",
      slug: "test",
      url: "https://blog.chunyan.dev/blog/test/",
      date: timestamp.parse_rfc3339("2026-09-17T00:00:00Z")
        |> result.unwrap(or: timestamp.unix_epoch),
      description: "测试描述",
      excerpt: "测试摘要",
      language: option.None,
      featured_image: option.None,
      contents: [],
      extras: dict.new(),
    )

  let rendered = blog_template.template(article, []) |> element.to_string

  assert string.contains(rendered, "\\\"引用\\\"")
  assert string.contains(rendered, "\\u003c/script>")
}
