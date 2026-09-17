#!/usr/bin/env python3
"""Add reproducible mixed-language reading-time estimates to blog posts.

The estimate counts CJK characters at 400 per minute and Latin words or code
tokens at 225 per minute. It is an editorial estimate, not a measured reading
speed claim. Markdown markup and link destinations are ignored, while inline
and fenced code content remains part of the estimate.
"""

import math
import pathlib
import re
import sys

CJK_CHARACTERS_PER_MINUTE = 400
LATIN_TOKENS_PER_MINUTE = 225
BLOG_DIR = pathlib.Path(__file__).resolve().parent.parent / "blog"
FRONTMATTER_RE = re.compile(r"^---\n(.*?\n)---\n", re.DOTALL)
CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
MARKDOWN_LINK_RE = re.compile(
    r"!?\[([^\]]*)\]\((?:[^()]|\([^)]*\))*\)",
)
HTML_TAG_RE = re.compile(r"<[^>]+>")
FENCED_CODE_RE = re.compile(
    r"(?ms)^\s{0,3}(?P<fence>`{3,}|~{3,})[^\n]*\n"
    r"(?P<code>.*?)(?:^\s{0,3}(?P=fence)[ \t]*$|\Z)",
)
INLINE_CODE_RE = re.compile(r"(?s)`+(?P<code>.+?)`+")
LATIN_TOKEN_RE = re.compile(
    r"[A-Za-z]+(?:[0-9][A-Za-z0-9_-]*|[_-][A-Za-z0-9]+)*|[0-9]+",
)


def _plain_markdown(body: str) -> str:
    """Remove Markdown syntax while retaining prose and code content."""

    code_fragments = []

    def protect_code(match: re.Match[str]) -> str:
        code_fragments.append(match.group("code"))
        return f"\x00CODE{len(code_fragments) - 1}\x00"

    text = FENCED_CODE_RE.sub(protect_code, body)
    text = INLINE_CODE_RE.sub(protect_code, text)
    text = MARKDOWN_LINK_RE.sub(r"\1", text)
    text = HTML_TAG_RE.sub(" ", text)

    for index, code in enumerate(code_fragments):
        text = text.replace(f"\x00CODE{index}\x00", code)
    return text


def calculate_reading_time(body: str) -> int:
    """Return a minimum-one-minute mixed CJK and Latin reading estimate."""

    text = _plain_markdown(body)
    cjk_count = len(CJK_RE.findall(text))
    latin_text = CJK_RE.sub(" ", text)
    latin_count = len(LATIN_TOKEN_RE.findall(latin_text))
    minutes = (
        cjk_count / CJK_CHARACTERS_PER_MINUTE
        + latin_count / LATIN_TOKENS_PER_MINUTE
    )
    return max(1, math.ceil(minutes))


def process_file(path: pathlib.Path) -> None:
    """Update one Markdown file while preserving its body and other fields."""

    text = path.read_text(encoding="utf-8")

    match = FRONTMATTER_RE.match(text)
    if not match:
        print(f"  SKIP (no frontmatter): {path}")
        return

    frontmatter = match.group(1)
    body = text[match.end() :]
    minutes = calculate_reading_time(body)

    frontmatter = re.sub(r"^reading_time:.*\n", "", frontmatter, flags=re.MULTILINE)
    new_frontmatter = frontmatter.rstrip("\n") + f"\nreading_time: '{minutes}'\n"
    new_text = f"---\n{new_frontmatter}---\n{body}"

    path.write_text(new_text, encoding="utf-8")
    print(f"  {path.name}: {minutes} min")


def main() -> None:
    """Update Markdown files in this repository's blog directory."""

    if not BLOG_DIR.is_dir():
        print(f"Blog directory not found: {BLOG_DIR}", file=sys.stderr)
        sys.exit(1)

    for post_dir in sorted(BLOG_DIR.iterdir()):
        if not post_dir.is_dir():
            continue
        print(post_dir.name)
        for md_file in sorted(post_dir.glob("*.md")):
            process_file(md_file)


if __name__ == "__main__":
    main()
