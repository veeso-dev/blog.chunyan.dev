import blog/components/post_meta
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

pub fn dates_use_utc_plus_eight_test() {
  let date = parse_date("2026-09-16T16:30:00Z")
  let rendered = date |> post_meta.formatted_date |> element.to_string

  assert string.contains(rendered, "2026年9月17日")
  assert string.contains(rendered, "datetime=\"2026-09-16T16:30:00Z\"")
}

pub fn dates_cross_new_year_test() {
  let date = parse_date("2026-12-31T16:00:00Z")
  let rendered = date |> post_meta.formatted_date |> element.to_string

  assert string.contains(rendered, "2027年1月1日")
}

pub fn missing_reading_time_is_one_minute_test() {
  assert reading_time_for(dict.new()) == "约 1 分钟阅读"
}

pub fn invalid_reading_time_is_one_minute_test() {
  let extras = dict.new() |> dict.insert("reading_time", "not-a-number")
  assert reading_time_for(extras) == "约 1 分钟阅读"
}

pub fn non_positive_reading_time_is_one_minute_test() {
  let zero = dict.new() |> dict.insert("reading_time", "0")
  let negative = dict.new() |> dict.insert("reading_time", "-2")

  assert reading_time_for(zero) == "约 1 分钟阅读"
  assert reading_time_for(negative) == "约 1 分钟阅读"
}

fn parse_date(value: String) -> timestamp.Timestamp {
  value
  |> timestamp.parse_rfc3339
  |> result.unwrap(or: timestamp.unix_epoch)
}

fn reading_time_for(extras: dict.Dict(String, String)) -> String {
  post.Post(
    title: "测试文章",
    slug: "test",
    url: "https://example.com/blog/test/",
    date: timestamp.unix_epoch,
    description: "测试",
    excerpt: "测试",
    language: option.None,
    featured_image: option.None,
    contents: [],
    extras: extras,
  )
  |> post_meta.reading_time
  |> element.to_string
}
