import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from add_reading_time import calculate_reading_time, process_file


class ReadingTimeTests(unittest.TestCase):
    def test_empty_text_is_one_minute(self):
        self.assertEqual(calculate_reading_time(""), 1)

    def test_chinese_without_spaces(self):
        self.assertEqual(calculate_reading_time("中" * 800), 2)

    def test_latin_words(self):
        text = " ".join(["Rust"] * 450)
        self.assertEqual(calculate_reading_time(text), 2)

    def test_mixed_prose(self):
        text = "中" * 400 + " " + " ".join(["Rust"] * 225)
        self.assertEqual(calculate_reading_time(text), 2)

    def test_rounding(self):
        self.assertEqual(calculate_reading_time("中" * 401), 2)

    def test_markup_and_link_destinations_are_ignored(self):
        text = "**Rust** [文档](https://example.com/very-long-destination)"
        self.assertEqual(calculate_reading_time(text), 1)

    def test_inline_and_fenced_code_are_counted(self):
        inline = "`borrow_checker`"
        fenced = "```rust\n" + " ".join(["Rust"] * 225) + "\n```"
        self.assertEqual(calculate_reading_time(inline), 1)
        self.assertEqual(calculate_reading_time(fenced), 1)

    def test_markup_like_code_content_is_preserved(self):
        code = " ".join(["[Rust](https://example.com)"] * 225)
        self.assertEqual(calculate_reading_time(f"`{code}`"), 4)

    def test_second_pass_is_idempotent_and_preserves_content(self):
        body = "\n一段中文，包含 `borrow_checker` 和一个链接。\n"
        source = (
            "---\n"
            'date: "2026-09-17 08:00:00 +08:00"\n'
            'title: "测试文章"\n'
            'description: "测试描述"\n'
            'author: "春晏"\n'
            'category: "rust"\n'
            'reading_time: "99"\n'
            'custom: "保持不变"\n'
            "---\n"
            + body
        )

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "index.md"
            path.write_text(source, encoding="utf-8")

            process_file(path)
            first_pass = path.read_text(encoding="utf-8")
            process_file(path)
            second_pass = path.read_text(encoding="utf-8")

        self.assertEqual(first_pass, second_pass)
        self.assertTrue(second_pass.endswith(body))
        self.assertIn('date: "2026-09-17 08:00:00 +08:00"', second_pass)
        self.assertIn('title: "测试文章"', second_pass)
        self.assertIn('description: "测试描述"', second_pass)
        self.assertIn('author: "春晏"', second_pass)
        self.assertIn('category: "rust"', second_pass)
        self.assertIn('custom: "保持不变"', second_pass)
        self.assertIn("reading_time: '1'", second_pass)


if __name__ == "__main__":
    unittest.main()
