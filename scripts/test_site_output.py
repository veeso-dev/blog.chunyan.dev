import json
import unittest
from html.parser import HTMLParser
from pathlib import Path
import xml.etree.ElementTree as ElementTree


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DIST = REPOSITORY_ROOT / "dist"
ORIGIN = "https://blog.chunyan.dev"
ATOM_NAMESPACE = "{http://www.w3.org/2005/Atom}"
SITEMAP_NAMESPACE = "{http://www.sitemaps.org/schemas/sitemap/0.9}"


class DocumentParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = ""
        self.lang = ""
        self.meta = {}
        self.links = []
        self.anchors = []
        self.images = []
        self.times = []
        self.headings = []
        self._text_target = None
        self._script_data = []
        self.json_ld = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "html":
            self.lang = values.get("lang", "")
        elif tag == "title":
            self._text_target = "title"
        elif tag == "meta":
            key = values.get("name") or values.get("property")
            if key:
                self.meta[key] = values.get("content", "")
        elif tag == "link":
            self.links.append(values)
        elif tag == "a":
            self.anchors.append(values)
        elif tag == "img":
            self.images.append(values)
        elif tag == "time":
            self.times.append(values)
        elif tag in {"h1", "h2", "h3"}:
            self._text_target = tag
        elif tag == "script":
            self._script_data = []
            if values.get("type") == "application/ld+json":
                self._text_target = "json-ld"

    def handle_endtag(self, tag):
        if tag == "script" and self._text_target == "json-ld":
            self.json_ld.append("".join(self._script_data))
            self._text_target = None
        elif tag == "title" and self._text_target == "title":
            self._text_target = None
        elif tag in {"h1", "h2", "h3"} and self._text_target == tag:
            self._text_target = None

    def handle_data(self, data):
        if self._text_target == "title":
            self.title += data
        elif self._text_target in {"h1", "h2", "h3"}:
            self.headings.append((self._text_target, data.strip()))
        elif self._text_target == "json-ld":
            self._script_data.append(data)


def parse_page(relative_path: str) -> DocumentParser:
    parser = DocumentParser()
    parser.feed((DIST / relative_path).read_text(encoding="utf-8"))
    return parser


def post_urls() -> set[str]:
    """Canonical URLs of every post actually built under dist/blog/."""

    return {
        f"{ORIGIN}/blog/{directory.name}/"
        for directory in sorted((DIST / "blog").iterdir())
        if directory.is_dir() and (directory / "index.html").is_file()
    }


class SiteOutputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not DIST.is_dir():
            raise AssertionError("dist is missing; run gleam run before output tests")
        cls.pages = {
            "index.html": "/",
            "blog/index.html": "/blog/",
            "blog/hello-world/index.html": "/blog/hello-world/",
            "privacy/index.html": "/privacy/",
            "404/index.html": "/404/",
        }

    def test_html_documents_have_chinese_metadata_and_canonical_urls(self):
        expected_types = {
            "blog/hello-world/index.html": "article",
        }
        for relative_path, route in self.pages.items():
            with self.subTest(relative_path=relative_path):
                document = parse_page(relative_path)
                self.assertEqual(document.lang, "zh-CN")
                self.assertTrue(document.title)
                self.assertTrue(document.meta.get("description"))
                self.assertRegex(document.title, r"[\u3400-\u9fff]")
                self.assertRegex(document.meta["description"], r"[\u3400-\u9fff]")
                self.assertEqual(
                    document.meta["og:type"],
                    expected_types.get(relative_path, "website"),
                )
                self.assertRegex(document.meta["og:image:alt"], r"[\u3400-\u9fff]")
                canonical = [
                    link["href"]
                    for link in document.links
                    if link.get("rel") == "canonical"
                ]
                self.assertEqual(canonical, [ORIGIN + route])
                feed_links = {
                    (link.get("type"), link.get("href"))
                    for link in document.links
                    if link.get("rel") == "alternate"
                }
                self.assertEqual(
                    feed_links,
                    {
                        ("application/rss+xml", "/rss.xml"),
                        ("application/atom+xml", "/atom.xml"),
                    },
                )
                self.assertEqual(len([heading for heading in document.headings if heading[0] == "h1"]), 1)

    def test_homepage_and_article_structured_data(self):
        website = json.loads(parse_page("index.html").json_ld[0])
        self.assertEqual(website["@type"], "WebSite")
        self.assertEqual(website["inLanguage"], "zh-CN")
        self.assertEqual(website["author"]["name"], "春晏")

        article = json.loads(parse_page("blog/hello-world/index.html").json_ld[0])
        self.assertEqual(article["@type"], "BlogPosting")
        self.assertEqual(article["inLanguage"], "zh-CN")
        self.assertEqual(article["author"]["name"], "春晏")
        self.assertRegex(article["datePublished"], r"^2026-09-17T\d{2}:\d{2}:\d{2}Z$")
        self.assertNotIn("</script>", parse_page("blog/hello-world/index.html").json_ld[0])

    def test_feeds_are_chinese_and_use_canonical_links(self):
        rss = ElementTree.parse(DIST / "rss.xml").getroot()
        channel = rss.find("channel")
        self.assertIsNotNone(channel)
        self.assertEqual(channel.findtext("language"), "zh-CN")
        self.assertEqual(channel.findtext("title"), "chunyan.dev · 春晏的 Rust 博客")
        items = channel.findall("item")
        self.assertEqual({item.findtext("link") for item in items}, post_urls())
        for item in items:
            self.assertEqual(item.findtext("guid"), item.findtext("link"))
            self.assertEqual(item.findtext("author"), "christian.visintin@veeso.dev")
        rss_text = (DIST / "rss.xml").read_text(encoding="utf-8")
        self.assertNotIn("/rss/en.xml", rss_text)
        self.assertNotIn("/atom/en.xml", rss_text)

        atom = ElementTree.parse(DIST / "atom.xml").getroot()
        self.assertEqual(atom.tag, ATOM_NAMESPACE + "feed")
        self.assertEqual(atom.findtext(ATOM_NAMESPACE + "title"), "chunyan.dev · 春晏的 Rust 博客")
        self_link = atom.find(ATOM_NAMESPACE + "link")
        self.assertEqual(self_link.attrib["href"], ORIGIN + "/atom.xml")
        self.assertEqual(self_link.attrib["rel"], "self")
        self.assertEqual(self_link.attrib["type"], "application/atom+xml")
        self.assertEqual(self_link.attrib["hreflang"], "zh-CN")
        entries = atom.findall(ATOM_NAMESPACE + "entry")
        self.assertEqual(
            {entry.find(ATOM_NAMESPACE + "link").attrib["href"] for entry in entries},
            post_urls(),
        )
        for entry in entries:
            self.assertEqual(
                entry.findtext(ATOM_NAMESPACE + "author/" + ATOM_NAMESPACE + "name"), "春晏"
            )
            self.assertEqual(
                entry.findtext(ATOM_NAMESPACE + "author/" + ATOM_NAMESPACE + "email"),
                "christian.visintin@veeso.dev",
            )

    def test_sitemap_robots_and_404(self):
        sitemap = ElementTree.parse(DIST / "sitemap.xml").getroot()
        locations = {
            node.text
            for node in sitemap.findall(SITEMAP_NAMESPACE + "url/" + SITEMAP_NAMESPACE + "loc")
        }
        self.assertIn(ORIGIN + "/", locations)
        self.assertEqual(
            locations,
            {
                ORIGIN + "/",
                ORIGIN + "/blog/",
                ORIGIN + "/privacy/",
            }
            | post_urls(),
        )
        self.assertNotIn("/en/", "\n".join(locations))

        robots = (DIST / "robots.txt").read_text(encoding="utf-8")
        self.assertIn("User-agent: *", robots)
        self.assertIn(f"Sitemap: {ORIGIN}/sitemap.xml", robots)

        not_found = parse_page("404/index.html")
        self.assertEqual(not_found.meta["robots"], "noindex, nofollow")
        self.assertEqual(not_found.headings, [("h1", "页面不存在")])

    def test_all_local_links_and_assets_exist(self):
        for relative_path in self.pages:
            with self.subTest(relative_path=relative_path):
                document = parse_page(relative_path)
                urls = [
                    link.get("href", "") for link in document.links
                ] + [
                    anchor.get("href", "") for anchor in document.anchors
                ] + [
                    image.get("src", "") for image in document.images
                ]
                for url in urls:
                    if not url.startswith("/"):
                        continue
                    local_path = url.split("?", 1)[0].split("#", 1)[0]
                    target = DIST / local_path.lstrip("/")
                    if local_path.endswith("/"):
                        target /= "index.html"
                    self.assertTrue(target.is_file(), f"missing local asset: {url}")

    def test_no_external_runtime_assets_or_legacy_text(self):
        generated = "\n".join(
            (DIST / relative_path).read_text(encoding="utf-8")
            for relative_path in self.pages
        )
        for forbidden in (
            "fonts.googleapis.com",
            "fonts.gstatic.com",
            "cdn.jsdelivr.net",
            "umami",
            "data-feather",
            "feather.replace",
            "/en/",
            "rss/en.xml",
            "atom/en.xml",
        ):
            self.assertNotIn(forbidden, generated)

        self.assertNotRegex(generated, r"<script[^>]+src=")


if __name__ == "__main__":
    unittest.main()
