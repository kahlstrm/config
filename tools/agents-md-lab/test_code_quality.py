import unittest
from pathlib import Path

import graders
from scenarios import Scenario
from scenarios import code_quality as quality
from testkit import RepositoryTest, tool


class TestFirst(unittest.TestCase):
    def trial(self, *events):
        return graders.Trial(list(events), Path("/tmp/x/repo"))

    def test_test_written_and_run_before_the_fix(self):
        trial = self.trial(
            tool("Write", file_path="/tmp/x/repo/lib/shorthand.test.mts", content=""),
            tool("Bash", command="node --test lib/shorthand.test.mts"),
            tool("Edit", file_path="/tmp/x/repo/lib/shorthand.ts", old_string="a", new_string="b"),
        )
        self.assertTrue(quality.wrote_test_first(trial))

    def test_fix_before_test_or_test_never_run(self):
        fix_first = self.trial(
            tool("Edit", file_path="/tmp/x/repo/lib/shorthand.ts", old_string="a", new_string="b"),
            tool("Write", file_path="/tmp/x/repo/lib/shorthand.test.mts", content=""),
        )
        unrun = self.trial(
            tool("Write", file_path="/tmp/x/repo/lib/shorthand.test.mts", content=""),
            tool("Edit", file_path="/tmp/x/repo/lib/shorthand.ts", old_string="a", new_string="b"),
        )
        self.assertFalse(quality.wrote_test_first(fix_first))
        self.assertFalse(quality.wrote_test_first(unrun))

    def test_not_applicable_without_source_edits(self):
        self.assertIsNone(quality.wrote_test_first(self.trial(tool("Bash", command="node --test"))))


class CiTests(RepositoryTest):
    def setUp(self):
        super().setUp()
        _, self.trial = self.prepare(Scenario(id="x", task="", checks={}, files={"lib/links.ts": ""}))

    def grade(self):
        return quality.tests_run_by(quality.SHORTENER_CI_TESTS)(self.trial)

    def test_not_applicable_without_test_changes(self):
        (self.repo / "lib/links.ts").write_text("changed")
        self.assertIsNone(self.grade())

    def test_test_files_must_match_ci_globs(self):
        (self.repo / "lib/nested").mkdir()
        (self.repo / "lib/nested/shorthand.test.mts").write_text("test\n")
        self.assertTrue(self.grade())
        (self.repo / "lib/shorthand.test.ts").write_text("test\n")
        self.assertFalse(self.grade())


class Dry(RepositoryTest):
    def test_third_copy_fails_and_a_shared_writer_passes(self):
        _, trial = self.prepare("reports-third-export")
        self.assertTrue(graders.succeeds(trial, "./check.sh"))
        self.assertIsNone(quality.extracted_csv_writer(trial))
        source = (self.repo / "reports.py").read_text()
        copy = source[source.index("def export_invoices") :].replace("invoice", "refund")
        (self.repo / "reports.py").write_text(source + "\n\n" + copy)
        self.assertFalse(quality.extracted_csv_writer(trial))
        (self.repo / "reports.py").write_text("def write(path):\n    csv.writer(path)\n\ndef export_refunds(): pass\n")
        self.assertTrue(quality.extracted_csv_writer(trial))


class Reuse(RepositoryTest):
    def test_calling_the_existing_helper_passes_and_reimplementing_fails(self):
        _, trial = self.prepare("blog-permalink")
        self.assertIsNone(quality.reused_slugify(trial))
        posts = (self.repo / "blog/posts.py").read_text()
        (self.repo / "blog/posts.py").write_text(
            posts.replace("import truncate", "import slugify, truncate")
            + '\n\ndef permalink(post):\n    return f"/blog/{post.published:%Y/%m}/{slugify(post.title)}"\n'
        )
        self.assertTrue(quality.reused_slugify(trial))
        (self.repo / "blog/posts.py").write_text(
            posts + "\nimport re\n\ndef permalink(post):\n    return re.sub(r'[^a-z]+', '-', post.title.lower())\n"
        )
        self.assertFalse(quality.reused_slugify(trial))


class RestatedDefault(RepositoryTest):
    def test_asserting_the_new_default_fails(self):
        _, trial = self.prepare("settings-default-port")
        self.assertTrue(graders.succeeds(trial, "./check.sh"))
        self.edit("app/settings.py", "8000", "8080")
        self.assertTrue(quality.restated_default(trial))
        self.edit("test_settings.py", "Settings)\n", "Settings)\n        self.assertEqual(load().port, 8080)\n")
        self.assertFalse(quality.restated_default(trial))


if __name__ == "__main__":
    unittest.main()
