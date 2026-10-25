import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
sys.path.insert(0, str(Path(__file__).parent))

import graders
from scenarios import SCENARIOS, Scenario
from scenarios import code_quality as quality


def tool(name, **arguments):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": name, "input": arguments}]}}


class Prepared(unittest.TestCase):
    scenario = None

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.repo = root / "repo"
        base = SCENARIOS[self.scenario].setup(root)
        self.trial = graders.Trial([], self.repo, root, base)

    def edit(self, path, old, new):
        file = self.repo / path
        file.write_text(file.read_text().replace(old, new))


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


class CiTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.repo = root / "repo"
        base = Scenario(id="x", rules=(), task="", check=dict, files={"lib/links.ts": ""}).setup(root)
        self.trial = graders.Trial([], self.repo, root, base)

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


class Dry(Prepared):
    scenario = "reports-third-export"

    def test_third_copy_fails_and_a_shared_writer_passes(self):
        source = (self.repo / "reports.py").read_text()
        copy = source[source.index("def export_invoices") :].replace("invoice", "refund")
        (self.repo / "reports.py").write_text(source + "\n\n" + copy)
        self.assertFalse(quality.extracted_csv_writer(self.trial))
        (self.repo / "reports.py").write_text("def write(path):\n    csv.writer(path)\n\ndef export_refunds(): pass\n")
        self.assertTrue(quality.extracted_csv_writer(self.trial))

    def test_not_applicable_before_the_third_export(self):
        self.assertIsNone(quality.extracted_csv_writer(self.trial))

    def test_setup_check_passes(self):
        self.assertTrue(graders.succeeds(self.repo, "./check.sh"))


class Reuse(Prepared):
    scenario = "blog-permalink"

    def test_calling_the_existing_helper_passes(self):
        self.edit("blog/posts.py", "import truncate", "import slugify, truncate")
        (self.repo / "blog/posts.py").write_text(
            (self.repo / "blog/posts.py").read_text()
            + "\n\ndef permalink(post):\n    return f\"/blog/{post.published:%Y/%m}/{slugify(post.title)}\"\n"
        )
        self.assertEqual(quality.permalink_check(self.trial), {"reuse-existing": True})

    def test_reimplementing_slugs_fails(self):
        (self.repo / "blog/posts.py").write_text(
            (self.repo / "blog/posts.py").read_text()
            + "\nimport re\n\ndef permalink(post):\n    return re.sub(r'[^a-z]+', '-', post.title.lower())\n"
        )
        self.assertEqual(quality.permalink_check(self.trial), {"reuse-existing": False})

    def test_not_applicable_without_permalink(self):
        self.assertEqual(quality.permalink_check(self.trial), {"reuse-existing": None})


class RestatedDefault(Prepared):
    scenario = "settings-default-port"

    def test_asserting_the_new_default_fails(self):
        self.edit("app/settings.py", "8000", "8080")
        self.assertTrue(quality.restated_default(self.trial))
        self.edit("test_settings.py", "Settings)\n", "Settings)\n        self.assertEqual(load().port, 8080)\n")
        self.assertFalse(quality.restated_default(self.trial))

    def test_setup_check_passes(self):
        self.assertTrue(graders.succeeds(self.repo, "./check.sh"))


if __name__ == "__main__":
    unittest.main()
