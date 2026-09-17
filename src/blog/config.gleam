import blog/components/md_components
import blog/components/syntax_highlighting
import blog/pages/blog
import blog/pages/home
import blog/pages/not_found
import blog/pages/privacy
import blog/site
import blog/template/blog as blog_template
import blogatto/config
import blogatto/config/feed
import blogatto/config/feed/atom as atom_feed
import blogatto/config/feed/rss as rss_feed
import blogatto/config/post
import blogatto/config/robots
import blogatto/config/sitemap
import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import gleam/time/timestamp
import marceau

pub fn config() -> config.Config(Nil) {
  let md =
    post.default()
    |> post.path("./blog")
    |> post.route_prefix("blog")
    |> post.template(blog_template.template)
    |> post.components(md_components.components())
    |> post.syntax_highlighting(syntax_highlighting.config())

  let rss =
    rss_feed.new(site.feed_title, site.origin, site.feed_description)
    |> rss_feed.language(site.language)
    |> rss_feed.output("/rss.xml")
    |> rss_feed.serialize(serialize_rss_feed_item)

  let atom =
    atom_feed.new(
      site.origin <> "/",
      atom_feed.PlainText(site.feed_title),
      timestamp.system_time(),
    )
    |> atom_feed.subtitle(site.feed_description)
    |> atom_feed.link(atom_feed.Link(
      href: site.origin <> "/atom.xml",
      rel: option.Some("self"),
      content_type: option.Some("application/atom+xml"),
      hreflang: option.Some(site.language),
      title: option.None,
      length: option.None,
    ))
    |> atom_feed.author(atom_feed.Person(
      name: site.author_name,
      email: option.Some(site.author_email),
      uri: option.Some("https://www.veeso.me/"),
    ))
    |> atom_feed.output("/atom.xml")
    |> atom_feed.serialize(serialize_atom_feed_item)
    |> atom_feed.rights(atom_feed.PlainText(
      "© 2026 春晏

文章采用 CC BY-NC-ND 4.0 许可协议。",
    ))

  site.origin
  |> config.new()
  |> config.output_dir("./dist")
  |> config.static_dir("./static")
  |> config.post(md)
  |> config.atom_feed(atom)
  |> config.rss_feed(rss)
  |> config.sitemap(
    sitemap.new("/sitemap.xml")
    |> sitemap.filter(fn(url) {
      url != site.origin <> "/404" && url != site.origin <> "/404/"
    })
    |> sitemap.serialize(fn(url) {
      sitemap.SitemapEntry(
        url: canonical_sitemap_url(url),
        priority: option.None,
        last_modified: option.None,
        change_frequency: option.None,
      )
    }),
  )
  |> config.route("/", home.home)
  |> config.route("/blog/", blog.blog)
  |> config.route("/privacy/", privacy.privacy)
  |> config.route("/404/", not_found.not_found)
  |> config.robots(
    robots.RobotsConfig(sitemap_url: site.origin <> "/sitemap.xml", robots: [
      robots.Robot(
        user_agent: "*",
        allowed_routes: ["/"],
        disallowed_routes: [],
      ),
    ]),
  )
}

fn serialize_rss_feed_item(
  metadata: feed.FeedMetadata(msg),
) -> rss_feed.RssFeedItem {
  let enclosure = case metadata.post.featured_image {
    option.None -> option.None
    option.Some(featured_image) -> {
      let url = case featured_image {
        "http" <> _ -> featured_image
        path -> site.origin <> "/blog/" <> metadata.post.slug <> "/" <> path
      }
      let mime = image_mime_type(featured_image)
      option.Some(rss_feed.Enclosure(url:, length: 0, enclosure_type: mime))
    }
  }

  let categories =
    metadata.post.extras
    |> dict.get("category")
    |> option.from_result
    |> option.map(fn(x) { [x] })
    |> option.unwrap(or: [])

  rss_feed.RssFeedItem(
    title: metadata.post.title,
    description: metadata.post.excerpt,
    link: option.Some(metadata.url),
    author: option.Some(site.author_email),
    comments: option.None,
    source: option.None,
    pub_date: option.Some(metadata.post.date),
    categories:,
    enclosure:,
    guid: option.Some(metadata.url),
  )
}

fn serialize_atom_feed_item(
  metadata: feed.FeedMetadata(msg),
) -> atom_feed.AtomFeedItem {
  let categories =
    metadata.post.extras
    |> dict.get("category")
    |> option.from_result
    |> option.map(fn(x) {
      [atom_feed.Category(term: x, scheme: option.None, label: option.Some(x))]
    })
    |> option.unwrap(or: [])

  atom_feed.AtomFeedItem(
    id: metadata.url,
    title: atom_feed.PlainText(metadata.post.title),
    updated: metadata.post.date,
    authors: [
      atom_feed.Person(
        name: site.author_name,
        email: option.Some(site.author_email),
        uri: option.Some("https://www.veeso.me/"),
      ),
    ],
    content: option.None,
    link: option.Some(atom_feed.Link(
      href: metadata.url,
      rel: option.Some("alternate"),
      content_type: option.None,
      hreflang: option.Some(site.language),
      title: option.None,
      length: option.None,
    )),
    summary: option.Some(atom_feed.PlainText(metadata.post.excerpt)),
    categories:,
    contributors: [],
    published: option.Some(metadata.post.date),
    rights: option.None,
    source: option.None,
  )
}

fn image_mime_type(filename: String) -> String {
  let name = string.lowercase(filename)
  let extension =
    name
    |> string.split(".")
    |> list.last()
    |> option.from_result()
    |> option.unwrap("")

  marceau.extension_to_mime_type(extension)
}

fn canonical_sitemap_url(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> url
    False -> url <> "/"
  }
}
