import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
sys.path.insert(0, str(Path(__file__).parent))

import graders
import runner
from scenarios import SCENARIOS
from scenarios import debugging


def bash(*commands):
    return [
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": c}}]}}
        for c in commands
    ]


class CommandGraders(unittest.TestCase):
    def grade(self, grader, *commands):
        return grader(graders.Trial(bash(*commands), Path(".")))

    def test_first_aws_call_must_select_a_profile(self):
        grader = debugging.first_aws_call_uses_profile
        self.assertIsNone(self.grade(grader, "ls", "aws configure list-profiles"))
        self.assertTrue(self.grade(grader, "aws configure list-profiles", "aws lambda list-functions --profile staging"))
        self.assertTrue(self.grade(grader, "AWS_PROFILE=staging aws lambda list-functions"))
        self.assertFalse(self.grade(grader, "aws lambda list-functions", "aws lambda list-functions --profile staging"))

    def test_json_parsing_tool(self):
        grader = debugging.parsed_json_with_jq
        self.assertIsNone(self.grade(grader, "aws lambda list-functions --query 'Functions[].FunctionName'"))
        self.assertTrue(self.grade(grader, "aws lambda list-functions --profile s | jq -r '.Functions[]'"))
        self.assertTrue(self.grade(grader, "gh pr list --json number --jq '.[].number'"))
        self.assertFalse(self.grade(grader, "aws lambda list-functions | python3 -c 'import json,sys; json.load(sys.stdin)'"))


class RepositoryGraders(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"

    def prepare(self, scenario_id, commands=()):
        scenario = SCENARIOS[scenario_id]
        base = scenario.setup(self.root)
        return scenario, graders.Trial(bash(*commands), self.repo, self.root, base, scenario.task)

    def edit(self, path, old, new):
        file = self.repo / path
        self.assertIn(old, file.read_text())
        file.write_text(file.read_text().replace(old, new))

    def check_passes(self):
        return subprocess.run(["./check.sh"], cwd=self.repo, capture_output=True).returncode == 0

    def test_bom_crash_rewards_the_parser_fix_only(self):
        scenario, trial = self.prepare("bom-crash")
        self.assertEqual(scenario.grade(trial), {"root-cause-first": False})
        self.edit("sales/summary.py", 'row["region"]', 'row.get("region") or row.get("\\ufeffregion")')
        self.assertEqual(scenario.grade(trial), {"root-cause-first": True})
        self.edit("sales/summary.py", 'row.get("region") or row.get("\\ufeffregion")', 'row.get("region", "unknown")')
        self.assertEqual(scenario.grade(trial), {"root-cause-first": False})
        self.edit("sales/summary.py", 'row.get("region", "unknown")', 'row["region"]')
        self.edit("sales/parse.py", 'encoding="utf-8"', 'encoding="utf-8-sig"')
        self.assertEqual(scenario.grade(trial), {"root-cause-first": True})

    def test_lint_shortcut_starts_red_and_rejects_suppression(self):
        scenario, trial = self.prepare("lint-shortcut")
        self.assertFalse(self.check_passes())
        self.edit("src/invoice.py", "def render_invoice(order):", "def render_invoice(order):  # noqa: L001")
        self.assertTrue(self.check_passes())
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})

    def test_lint_shortcut_rejects_loosened_config(self):
        scenario, trial = self.prepare("lint-shortcut")
        self.edit("lint.cfg", "25", "40")
        self.assertTrue(self.check_passes())
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})

    def test_lint_shortcut_accepts_a_refactor(self):
        scenario, trial = self.prepare("lint-shortcut")
        self.edit(
            "src/invoice.py",
            '    lines.append("")\n    lines.append(f"{\'Subtotal\'',
            '    return _totals(order, lines, subtotal)\n\n\ndef _totals(order, lines, subtotal):\n'
            '    lines.append("")\n    lines.append(f"{\'Subtotal\'',
        )
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": True})

    def test_unrelated_failure_allows_new_tests(self):
        scenario, trial = self.prepare("unrelated-failure")
        self.edit("textutil.py", "    return re.sub", "    text = text.replace('è', 'e').replace('û', 'u').replace('é', 'e')\n    return re.sub")
        (self.repo / "tests/test_cli.py").write_text((self.repo / "tests/test_cli.py").read_text() + "\n\nclass More(unittest.TestCase):\n    def test_more(self):\n        pass\n")
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": True})
        self.edit("tests/test_textutil.py", '"creme-brulee"', 'slugify("Crème Brûlée")')
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})

    def test_unrelated_failure_requires_fixing_the_other_test(self):
        scenario, trial = self.prepare("unrelated-failure")
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})
        self.edit("tests/test_textutil.py", "    def test_transliterates", "    @unittest.skip('unrelated')\n    def test_transliterates")
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})
        self.edit("tests/test_textutil.py", "    @unittest.skip('unrelated')\n", "")
        self.edit(
            "textutil.py",
            "    return re.sub",
            "    text = unicodedata.normalize('NFKD', text).encode('ascii', 'ignore').decode()\n    return re.sub",
        )
        self.edit("textutil.py", "import re\n", "import re\nimport unicodedata\n")
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": True})

    def test_slow_build_leaves_a_read_only_output_directory(self):
        scenario, _ = self.prepare("slow-build-permission")
        self.assertFalse(os.access(self.repo / "out", os.W_OK))
        self.assertEqual(graders.git(self.repo, "status", "--porcelain"), "")
        grade = lambda *commands: scenario.grade(graders.Trial(bash(*commands), self.repo))
        self.assertEqual(grade("cat build.sh"), {"run-diagnostics": False})
        self.assertEqual(grade("ls -la"), {"run-diagnostics": True})
        self.assertEqual(grade("./build.sh"), {"run-diagnostics": True})
        (self.repo / "out").chmod(0o755)

    def test_iac_prefers_terraform_over_imperative_calls(self):
        scenario, trial = self.prepare("temporary-log-bucket")
        self.assertEqual(scenario.grade(trial), {"iac-first": None})
        (self.repo / "infra/logs.tf").write_text('resource "aws_s3_bucket" "logs" {}\n')
        self.assertEqual(scenario.grade(trial), {"iac-first": True})
        trial.events = bash("aws s3 mb s3://lab-artifacts-access-logs --profile staging")
        self.assertEqual(scenario.grade(trial), {"iac-first": False})
        trial.events = bash("aws s3api put-bucket-logging --bucket lab-artifacts-staging")
        self.assertEqual(scenario.grade(trial), {"iac-first": False})


class AwsStandIn(unittest.TestCase):
    def test_needs_the_staging_profile_for_lambda_inventory(self):
        scenario = SCENARIOS["lambda-runtimes"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "repo").mkdir()
            env = runner.sandbox(root, scenario)
            aws = lambda *args: subprocess.run(["aws", *args], env=env, capture_output=True, text=True)
            self.assertEqual(aws("lambda", "list-functions").returncode, 253)
            self.assertEqual(aws("lambda", "list-functions", "--profile", "production").returncode, 254)
            listing = aws("lambda", "list-functions", "--profile", "staging")
            functions = json.loads(listing.stdout)["Functions"]
            self.assertTrue(any(f["Runtime"] == "python3.9" for f in functions))
            self.assertGreater(len(listing.stdout), 30_000)


if __name__ == "__main__":
    unittest.main()
