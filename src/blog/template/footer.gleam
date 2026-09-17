//// Site footer with copyright notice.

import blog/components
import blog/components/container
import blog/site
import gleam/int
import gleam/time/duration
import gleam/time/timestamp
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// Render the site footer with copyright and the current year.
pub fn footer() -> Element(msg) {
  html.footer([], [
    container.col(
      [
        "bg-brand",
        "text-white",
        "py-10",
        "items-center",
        "justify-center",
        "gap-4",
      ],
      [built_with_blogatto(), privacy_line(), copyright_line()],
    ),
  ])
}

fn built_with_blogatto() -> Element(msg) {
  html.div(
    [
      components.classes([
        "text-center",
        "text-sm",
        "text-gray-300",
      ]),
    ],
    [
      element.text("由 "),
      html.a(
        [
          components.classes(["underline"]),
          attribute.href("https://blogat.to"),
        ],
        [
          element.text("Blogatto"),
          html.img([
            attribute.src("/blogatto.svg"),
            attribute.alt("Blogatto 标志"),
            components.classes(["inline", "h-8", "ml-1"]),
          ]),
        ],
      ),
      element.text(" 驱动"),
    ],
  )
}

fn privacy_line() -> Element(msg) {
  html.div([components.classes(["text-center", "text-sm", "text-gray-300"])], [
    html.a([components.classes(["underline"]), attribute.href("/privacy/")], [
      element.text("隐私政策"),
    ]),
  ])
}

fn copyright_line() -> Element(msg) {
  html.div([components.classes(["text-center", "text-sm", "text-gray-300"])], [
    element.text("© " <> current_year() <> " " <> site.author_name <> " · "),
    html.a(
      [
        attribute.href("https://creativecommons.org/licenses/by-nc-nd/4.0/"),
        attribute.target("_blank"),
        attribute.rel("noopener noreferrer"),
        components.classes(["underline"]),
      ],
      [element.text("文章采用 CC BY-NC-ND 4.0 许可协议")],
    ),
  ])
}

fn current_year() -> String {
  let #(date, _time) =
    timestamp.system_time()
    |> timestamp.to_calendar(duration.seconds(0))
  int.to_string(date.year)
}
