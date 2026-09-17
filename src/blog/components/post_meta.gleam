//// Shared post metadata components used by post previews and blog templates.

import blogatto/post
import gleam/dict
import gleam/int
import gleam/result
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// Render a post's date in UTC+8 with a machine-readable timestamp.
pub fn formatted_date(date: timestamp.Timestamp) -> Element(msg) {
  let #(calendar_date, _time) = timestamp.to_calendar(date, duration.hours(8))
  let formatted_date =
    int.to_string(calendar_date.year)
    <> "年"
    <> int.to_string(calendar.month_to_int(calendar_date.month))
    <> "月"
    <> int.to_string(calendar_date.day)
    <> "日"
  let machine_date = timestamp.to_rfc3339(date, duration.seconds(0))

  html.time([attribute.attribute("datetime", machine_date)], [
    element.text(formatted_date),
  ])
}

/// Render a post's estimated reading time in Chinese.
pub fn reading_time(post: post.Post(msg)) -> Element(msg) {
  let minutes =
    post.extras
    |> dict.get("reading_time")
    |> result.try(int.parse)
    |> result.map(clamp_minutes)
    |> result.unwrap(or: 1)

  element.text("约 " <> int.to_string(minutes) <> " 分钟阅读")
}

fn clamp_minutes(minutes: Int) -> Int {
  case minutes > 0 {
    True -> minutes
    False -> 1
  }
}
