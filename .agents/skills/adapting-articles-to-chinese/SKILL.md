---
name: adapting-articles-to-chinese
description: Use when asked to translate, port, adapt, or localize an English blog article (e.g. from ../blog.veeso.dev or any other source) into a new Simplified Chinese post for this blog (blog.chunyan.dev), or when asked to "翻译文章" / "本地化文章" / write a Chinese version of an existing post.
license: MIT
metadata:
  author: veeso
  version: "1.0.0"
  tags:
    - i18n
    - translation
    - content
    - seo
---

# Adapting Articles to Chinese for chunyan.dev

This blog only publishes Rust content in Simplified Chinese (see project
`CLAUDE.md`). Adapting a source article means rewriting it as a new post that
reads as if `春晏` wrote it directly in Chinese for a mainland Chinese
audience — not translating it sentence by sentence.

## Scope check first

Only adapt articles whose subject is Rust (ownership, borrowing, lifetimes,
traits, async Rust, performance, Cargo, tooling, crates, real Rust project
experience). If the source article isn't about Rust, stop and tell the user —
this blog doesn't take non-Rust posts even if the source blog does.

## Process

1. **Read the source article fully**, plus its frontmatter and any local
   assets (images) in its post directory.
2. **Read `blog/post-1/index.md`** — this is the canonical frontmatter and
   body template. Match its field set and shape exactly:
   - `date`: new date, format `"YYYY-MM-DD HH:MM:SS +02:00"` (CEST, per
     project convention — do not carry over the source's UTC/other offset).
   - `slug`: new, ASCII, stable, not a copy of the English slug.
   - `title`: plain Chinese title, no `| chunyan.dev` suffix (the template
     appends that).
   - `description`: plain Chinese, written for a Chinese search snippet, not
     a literal translation of the English description.
   - `author: "春晏"` (never `veeso` — this is a distinct byline for this
     blog).
   - `featured_image`: copy/adapt the source's image into the new post
     directory if one exists, keep the filename `featured.jpeg` (or whatever
     extension the asset uses) matching the existing convention.
   - `category`: pick from this blog's existing Rust-scoped categories; don't
     invent a new taxonomy from the source blog's categories.
   - `reading_time`: leave any placeholder value — it gets overwritten in
     step 4. Never hand-estimate this number in the final file.
   - No H1 in the body — the template renders the H1 from `title`. Start
     the body straight into prose.
3. **Pick the post directory name** by scanning existing `blog/post-*`
   directories and using the next sequential number (e.g. if `post-1` is the
   highest, the new post is `blog/post-2/`). Never name the directory after
   the slug or the task at hand.
4. **Write the adaptation**, not a translation:
   - Rewrite paragraph structure, transitions, and examples in natural
     Chinese technical writing — restructure sentences instead of mapping
     them 1:1 from English.
   - Keep full technical fidelity: same code, same crate names, same
     function signatures, same conclusions and caveats as the source. Code
     identifiers and crate names stay in English; code comments and
     doc-comments get translated to Chinese; inline Rust doc-tests keep
     working syntax.
   - Follow this project's writing-style rules from `CLAUDE.md`: natural
     first-person 我/你, no corporate tone, no forced internet slang, never
     translate "Rust" as "铁锈". Gloss `所有权（ownership）`,
     `借用检查器（borrow checker）`, `异步 Rust（async Rust）` on first use
     only if the article actually introduces those concepts — don't add
     glosses that aren't earned by the content.
   - Optimize for Chinese search (Baidu/搜狗), not literal keyword
     translation: use terms Chinese Rust developers actually search for,
     keep the title concise and front-loaded with the key topic, avoid
     keyword stuffing.
5. **Run the reading-time script** from the repo root after writing the
   file — never guess this number:
   ```sh
   python3 scripts/add_reading_time.py
   ```
   This rewrites `reading_time` for every post from the actual Chinese body
   text; the estimate in step 2 is a placeholder only, this is the ground
   truth.
6. **Verify before reporting done**:
   ```sh
   gleam format --check src test
   gleam test
   gleam run
   ```
   Confirm the new post builds and renders under `./dist`.

## Boundaries

- Never modify anything under `../blog.veeso.dev/` — it's a read-only
  reference for source articles, per project `CLAUDE.md`.
- Never commit, push, or open a PR for the new post unless the user
  explicitly asks — adapting the article is a file-writing task, not a
  publishing one.
- Don't batch-adapt multiple articles unless asked; one article per
  invocation unless told otherwise.

## Common mistakes

| Mistake | Fix |
|---|---|
| Hand-guessing `reading_time` | Always run `scripts/add_reading_time.py` after writing the file |
| Directory named after the slug or task (`post-lego-gameboy`, `post-baseline-test`) | Use the next sequential `post-N` |
| Sentence-by-sentence translation | Rewrite structure and phrasing in native Chinese; keep only technical substance 1:1 |
| Copying the source's category taxonomy verbatim | Map to this blog's existing categories |
| Adapting a non-Rust article | Stop and flag scope mismatch to the user first |
| `author: "veeso"` carried over from source | Always `"春晏"` on this blog |
