//// Privacy information for the static blog.

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

/// VAT number of the data controller.
const author_vat = "IT03104140300"

/// Contact email for privacy-related requests.
const contact_email = "christian.visintin@veeso.dev"

/// Render the privacy information page.
pub fn privacy(_posts: List(post.Post(Nil))) -> Element(Nil) {
  let url = site.origin <> "/privacy/"
  let config =
    page.PageConfig(
      title: "隐私政策 | chunyan.dev",
      description: "了解 chunyan.dev 的网站托管、主题偏好存储和数据处理方式。",
      url:,
      featured_image: option.Some(site.origin <> "/og_preview.jpeg"),
      page_type: "website",
      structured_data: option.None,
      noindex: False,
    )

  page.page(config, [page_content()], element.none())
}

fn page_content() -> Element(Nil) {
  html.div([components.classes(["flex", "flex-col", "gap-2"])], [
    heading.h1(dict.new(), "", [element.text("隐私政策")]),
    last_updated(),
    overview(),
    data_controller(),
    cookies(),
    hosting(),
    analytics(),
    third_party_resources(),
    international_transfers(),
    your_rights(),
    external_links(),
    changes(),
  ])
}

fn last_updated() -> Element(msg) {
  html.p(
    [
      components.classes([
        "text-sm",
        "text-gray-500",
        "dark:text-gray-400",
        "mb-4",
      ]),
    ],
    [element.text("最后更新：2026年9月17日")],
  )
}

fn overview() -> Element(msg) {
  section("概览", [
    paragraph([
      element.text(
        "这是 chunyan.dev 的个人 Rust 博客。网站不使用广告、跟踪 Cookie 或分析脚本，也不会通过本网站出售个人数据。为了提供网页并保障服务安全，托管服务商可能处理访问所必需的技术信息。本政策说明网站涉及的数据处理、用途以及你可以行使的权利，并参考欧盟《通用数据保护条例》（GDPR）和意大利数据保护法（D.Lgs. 196/2003，经 D.Lgs. 101/2018 修订）。",
      ),
    ]),
  ])
}

fn data_controller() -> Element(msg) {
  section("数据控制者和联系方式", [
    paragraph([
      element.text("数据控制者是 "),
      html.strong([], [element.text("veeso.dev di Christian Visintin")]),
      element.text("，增值税号为 "),
      element.text(author_vat),
      element.text("。如需咨询隐私问题或行使相关权利，请联系 "),
      mail_link(contact_email),
      element.text("。"),
    ]),
  ])
}

fn cookies() -> Element(msg) {
  section("Cookie 和本地存储", [
    paragraph([
      element.text(
        "本网站不使用 Cookie 来记录或分析你的行为，也不显示 Cookie 同意横幅。主题偏好（浅色或深色模式）会通过浏览器的 localStorage 保存在你的设备上。这项设置只用于记住显示偏好，不会发送给我，也不用于识别或跟踪你。",
      ),
    ]),
  ])
}

fn hosting() -> Element(msg) {
  section("网站托管和服务器日志", [
    paragraph([
      element.text(
        "本网站由 Vercel 提供托管。像其他网站服务器一样，托管服务可能为了传输页面、维护服务安全和防止滥用而处理访问请求所需的技术信息，例如 IP 地址、浏览器信息、请求地址、来源页面和时间戳。相关处理由托管服务商按照其自身的隐私政策和服务条款进行。",
      ),
    ]),
    paragraph([
      html.strong([], [element.text("处理依据：")]),
      element.text("运营网站、维护安全并处理滥用行为所需的合法利益。网站本身不会利用这些技术信息建立广告画像。"),
    ]),
  ])
}

fn analytics() -> Element(msg) {
  section("分析脚本", [
    paragraph([
      element.text(
        "本网站没有加载 Umami 或其他访问分析脚本，因此不会通过分析服务收集浏览量、来源或设备统计。若未来启用分析服务，我会在发布前更新本政策，准确说明实际使用的服务。",
      ),
    ]),
  ])
}

fn third_party_resources() -> Element(msg) {
  section("第三方资源", [
    paragraph([
      element.text(
        "网页的样式、字体回退、图标和代码高亮所需资源随网站一同提供或由浏览器完成，不依赖 Google Fonts、jsDelivr 或其他第三方 CDN。页面上的 GitHub、Mastodon、X 以及分享链接只有在你主动点击后才会打开；离开本站后，目标服务的隐私政策适用。",
      ),
    ]),
  ])
}

fn international_transfers() -> Element(msg) {
  section("跨境数据传输", [
    paragraph([
      element.text(
        "当你主动访问外部服务时，相关服务可能按照其自身政策在你所在国家或其他国家处理技术信息。本站不会为了分析或广告而主动把访客数据发送给这些服务。",
      ),
    ]),
  ])
}

fn your_rights() -> Element(msg) {
  section("你的权利", [
    paragraph([
      element.text(
        "在适用的法律范围内，你可以请求访问、更正、删除或限制处理与你有关的个人数据，也可以反对某些处理并请求数据可携带。由于本站不建立访客账户，也不运行分析脚本，我可能无法把匿名技术日志与具体个人对应起来。",
      ),
    ]),
    paragraph([
      element.text("如需行使权利，请通过 "),
      mail_link(contact_email),
      element.text(" 联系我。你也可以向意大利个人数据保护监管机构 "),
      external_link("https://www.garanteprivacy.it", "意大利个人数据保护机构"),
      element.text("或你居住地的数据保护机构投诉。"),
    ]),
  ])
}

fn external_links() -> Element(msg) {
  section("外部链接", [
    paragraph([
      element.text(
        "本网站包含 GitHub、Mastodon 和 X 等外部服务的链接。打开这些链接后，目标网站会按照自己的隐私政策处理数据；我不负责外部网站的内容或隐私实践。",
      ),
    ]),
  ])
}

fn changes() -> Element(msg) {
  section("政策变更", [
    paragraph([
      element.text("本隐私政策可能随网站功能或实际数据处理方式变化而更新。任何变更都会发布在本页面，并同步更新“最后更新”日期。"),
    ]),
  ])
}

fn section(title: String, body: List(Element(msg))) -> Element(msg) {
  html.section([components.classes(["mb-4"])], [
    heading.h2(dict.new(), "", [element.text(title)]),
    ..body
  ])
}

fn paragraph(children: List(Element(msg))) -> Element(msg) {
  html.p(
    [
      components.classes([
        "mb-3",
        "text-brand",
        "dark:text-gray-200",
        "text-justify",
      ]),
    ],
    children,
  )
}

fn mail_link(email: String) -> Element(msg) {
  html.a(
    [
      attribute.href("mailto:" <> email),
      components.classes([
        "text-brand",
        "dark:text-white",
        "underline",
        "font-medium",
      ]),
    ],
    [element.text(email)],
  )
}

fn external_link(href: String, label: String) -> Element(msg) {
  html.a(
    [
      attribute.href(href),
      attribute.target("_blank"),
      attribute.rel("noopener noreferrer"),
      components.classes([
        "text-brand",
        "dark:text-white",
        "underline",
        "font-medium",
      ]),
    ],
    [element.text(label)],
  )
}
