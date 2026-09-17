//// Full HTML page template with SEO metadata, theme support, and site layout.

import blog/components
import blog/components/container
import blog/site
import blog/template/footer
import blog/template/topbar
import gleam/json
import gleam/option.{type Option}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

const umami_website_id = "28aae568-00c2-42cc-b624-3b37166c558e"

/// Configuration for rendering a page.
pub type PageConfig {
  PageConfig(
    /// Page title shown in the browser tab and meta tags.
    title: String,
    /// Page description for SEO meta tags.
    description: String,
    /// Canonical URL for this page.
    url: String,
    /// Optional featured image URL for OG/Twitter card tags.
    featured_image: Option(String),
    /// Open Graph page type, either `website` or `article`.
    page_type: String,
    /// Optional serialized JSON-LD structured data.
    structured_data: Option(String),
    /// Whether search engines should keep this page out of their index.
    noindex: Bool,
  )
}

/// Render a full HTML page with the given configuration and body children.
pub fn page(
  config: PageConfig,
  children: List(Element(msg)),
  before_footer: Element(msg),
) -> Element(msg) {
  html.html([attribute.lang(site.language)], [
    head(config),
    body(children, before_footer),
  ])
}

/// Serialize the site's homepage structured data.
pub fn website_structured_data(url: String) -> String {
  json.object([
    #("@context", json.string("https://schema.org")),
    #("@type", json.string("WebSite")),
    #("name", json.string(site.name)),
    #("url", json.string(url)),
    #("inLanguage", json.string(site.language)),
    #(
      "author",
      json.object([
        #("@type", json.string("Person")),
        #("name", json.string(site.author_name)),
      ]),
    ),
  ])
  |> json.to_string
  |> escape_script_data
}

fn head(config: PageConfig) -> Element(msg) {
  html.head([], [
    html.meta([attribute.charset("UTF-8")]),
    html.meta([
      attribute.name("viewport"),
      attribute.content("width=device-width, initial-scale=1.0"),
    ]),
    html.title([], config.title),
    html.meta([
      attribute.name("description"),
      attribute.content(config.description),
    ]),
    noindex_meta(config.noindex),
    html.link([
      attribute.rel("canonical"),
      attribute.href(config.url),
    ]),
    og_meta("og:title", config.title),
    og_meta("og:description", config.description),
    og_meta("og:type", config.page_type),
    og_meta("og:url", config.url),
    og_meta("og:site_name", site.name),
    og_meta("og:locale", site.og_locale),
    html.meta([
      attribute.name("twitter:creator"),
      attribute.content("@veeso_dev"),
    ]),
    html.meta([
      attribute.name("twitter:title"),
      attribute.content(config.title),
    ]),
    html.meta([
      attribute.name("twitter:description"),
      attribute.content(config.description),
    ]),
    html.meta([
      attribute.name("fediverse:creator"),
      attribute.content("@veeso_dev@hachyderm.io"),
    ]),
    featured_image_meta(config.featured_image),
    feed_discovery_links(),
    html.link([
      attribute.rel("icon"),
      attribute.type_("image/x-icon"),
      attribute.href("/favicon.ico"),
    ]),
    html.link([
      attribute.rel("icon"),
      attribute.type_("image/png"),
      attribute.attribute("sizes", "16x16"),
      attribute.href("/favicon-16x16.png"),
    ]),
    html.link([
      attribute.rel("icon"),
      attribute.type_("image/png"),
      attribute.attribute("sizes", "32x32"),
      attribute.href("/favicon-32x32.png"),
    ]),
    html.link([
      attribute.rel("icon"),
      attribute.type_("image/png"),
      attribute.attribute("sizes", "96x96"),
      attribute.href("/favicon-96x96.png"),
    ]),
    html.link([
      attribute.rel("stylesheet"),
      attribute.href("/blog.css"),
    ]),
    structured_data(config.structured_data),
    html.script(
      [
        attribute.attribute("defer", ""),
        attribute.src("https://cloud.umami.is/script.js"),
        attribute.attribute("data-website-id", umami_website_id),
        attribute.attribute("data-do-not-track", "true"),
        attribute.attribute("data-auto-track", "true"),
      ],
      "",
    ),
    html.script([], dark_mode_js),
  ])
}

fn noindex_meta(noindex: Bool) -> Element(msg) {
  case noindex {
    True ->
      html.meta([
        attribute.name("robots"),
        attribute.content("noindex, nofollow"),
      ])
    False -> element.none()
  }
}

fn feed_discovery_links() -> Element(msg) {
  element.fragment([
    html.link([
      attribute.rel("alternate"),
      attribute.type_("application/rss+xml"),
      attribute.title(site.feed_title <> "（RSS）"),
      attribute.href("/rss.xml"),
    ]),
    html.link([
      attribute.rel("alternate"),
      attribute.type_("application/atom+xml"),
      attribute.title(site.feed_title <> "（Atom）"),
      attribute.href("/atom.xml"),
    ]),
  ])
}

fn structured_data(data: Option(String)) -> Element(msg) {
  case data {
    option.Some(json) ->
      html.script([attribute.type_("application/ld+json")], json)
    option.None -> element.none()
  }
}

fn body(
  children: List(Element(msg)),
  before_footer: Element(msg),
) -> Element(msg) {
  html.body([], [
    html.div([], [
      container.col(
        [
          "bg-page",
          "dark:bg-zinc-900",
          "items-center",
          "justify-center",
          "pt-4",
          "pb-12",
          "sm:pt-0",
        ],
        [
          container.col(
            [
              "items-center",
              "bg-white",
              "dark:bg-brand",
              "text-brand",
              "dark:text-white",
              "rounded",
              "shadow-xl",
              "dark:shadow-none",
              "justify-center",
              "w-fit",
              "sm:w-full",
              "sm:rounded-none",
            ],
            [
              html.div(
                [
                  components.classes([
                    "m-4",
                    "max-w-screen-md",
                    "w-auto",
                    "sm:max-w-full",
                    "p-2",
                  ]),
                ],
                [topbar.topbar(), html.main([], children)],
              ),
            ],
          ),
          html.div(
            [
              components.classes([
                "max-w-screen-md",
                "w-auto",
                "sm:max-w-full",
                "py-4",
              ]),
            ],
            [before_footer],
          ),
        ],
      ),
    ]),
    footer.footer(),
  ])
}

fn featured_image_meta(image: Option(String)) -> Element(msg) {
  case image {
    option.Some(url) ->
      element.fragment([
        og_meta("og:image", url),
        og_meta("og:image:alt", site.preview_image_alt),
        html.meta([
          attribute.name("twitter:card"),
          attribute.content("summary_large_image"),
        ]),
        html.meta([attribute.name("twitter:image"), attribute.content(url)]),
        html.link([
          attribute.rel("preload"),
          attribute.as_("image"),
          attribute.href(url),
        ]),
      ])
    option.None ->
      html.meta([
        attribute.name("twitter:card"),
        attribute.content("summary"),
      ])
  }
}

fn og_meta(property: String, content: String) -> Element(msg) {
  html.meta([
    attribute.attribute("property", property),
    attribute.content(content),
  ])
}

fn escape_script_data(json: String) -> String {
  string.replace(json, "<", "\\u003c")
}

const dark_mode_js = "(function(){try{var t=window.localStorage.getItem('theme');var d=t==='dark'||(!t&&window.matchMedia('(prefers-color-scheme:dark)').matches);if(d)document.documentElement.classList.add('dark')}catch(_){}})()"
