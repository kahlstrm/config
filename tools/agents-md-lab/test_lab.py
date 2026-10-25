import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
sys.path.insert(0, str(Path(__file__).parent))

import catalogue
import graders
import lab
import prompt
import report
import repos
import runner
import scenarios
from scenarios import Scenario

REPOSITORY = Path(__file__).parent.parent.parent

SAMPLE = """# Title

## Section

- First rule.
- Second rule
  continues here.
- Third rule. Fourth rule.

A paragraph with one sentence. And
another sentence.

## Other
"""


class PromptVariants(unittest.TestCase):
    def test_removes_a_whole_bullet_across_line_breaks(self):
        self.assertEqual(
            prompt.without(SAMPLE, "Second rule continues here."),
            SAMPLE.replace("- Second rule\n  continues here.\n", ""),
        )

    def test_removes_one_sentence_of_a_bullet(self):
        self.assertIn("\n- Fourth rule.\n", prompt.without(SAMPLE, "Third rule."))

    def test_removes_a_sentence_spanning_lines_of_a_paragraph(self):
        self.assertIn(
            "A paragraph with one sentence.\n\n## Other",
            prompt.without(SAMPLE, "And another sentence."),
        )

    def test_rejects_missing_and_ambiguous_text(self):
        with self.assertRaisesRegex(ValueError, "no text"):
            prompt.without(SAMPLE, "Nonexistent")
        with self.assertRaisesRegex(ValueError, "2 places"):
            prompt.without(SAMPLE, "sentence.")


class Catalogue(unittest.TestCase):
    def test_rules_cover_every_instruction_exactly_once(self):
        for source, path in catalogue.SOURCES.items():
            with self.subTest(source=source):
                remaining = (REPOSITORY / path).read_text()
                for rule in catalogue.RULES.values():
                    if rule.source == source:
                        remaining = prompt.without(remaining, rule.text)
                leftover = [line for line in remaining.splitlines() if line.strip() and not line.startswith("#")]
                self.assertEqual(leftover, [])

    def test_ablating_a_rule_removes_text_that_presupposes_it(self):
        instructions = (REPOSITORY / catalogue.SOURCES["global"]).read_text()
        ablated = lab.ablate(instructions, "pr-text-approval")
        self.assertNotIn("present the exact text", ablated)
        self.assertIn("Write ONLY concise oneliners", ablated)

    def test_untested_rules_give_a_reason(self):
        for rule in catalogue.RULES.values():
            with self.subTest(rule=rule.id):
                self.assertIn(rule.grading, {"script", "judge", "claim", "untested"})
                self.assertEqual(rule.grading == "untested", bool(rule.note))

    def test_every_scenario_rule_is_measurable_by_trials(self):
        for scenario in scenarios.SCENARIOS.values():
            for rule in scenario.rules:
                with self.subTest(scenario=scenario.id, rule=rule):
                    self.assertIn(catalogue.RULES[rule].grading, {"script", "judge"})

    def test_every_trial_rule_has_a_scenario(self):
        covered = {rule for scenario in scenarios.SCENARIOS.values() for rule in scenario.rules}
        measurable = {rule.id for rule in catalogue.RULES.values() if rule.grading in {"script", "judge"}}
        self.assertEqual(measurable - covered, set())


def events(*commands, result="done"):
    return [
        *(
            {
                "type": "assistant",
                "message": {
                    "content": [{"type": "tool_use", "name": "Bash", "input": {"command": command}}]
                },
            }
            for command in commands
        ),
        {"type": "result", "result": result},
    ]


class Graders(unittest.TestCase):
    def test_extracts_bash_commands_and_final_text(self):
        trial = graders.Trial(events("ls", "jq length x.json", result="Answer"), Path("."))
        self.assertEqual(graders.bash_commands(trial), ["ls", "jq length x.json"])
        self.assertEqual(graders.final_text(trial), "Answer")

    def test_jq_usage_is_not_applicable_without_shell(self):
        self.assertIsNone(graders.used("jq")(graders.Trial(events(), Path("."))))
        self.assertFalse(graders.used("jq")(graders.Trial(events("python3 -c 1"), Path("."))))
        self.assertTrue(graders.used("jq")(graders.Trial(events("cat a | jq ."), Path("."))))

    def test_running_a_script_differs_from_reading_it(self):
        ran = graders.ran("run.sh")
        self.assertTrue(ran(graders.Trial(events("cd /x && ./run.sh"), Path("."))))
        self.assertTrue(ran(graders.Trial(events("bash -x run.sh"), Path("."))))
        self.assertFalse(ran(graders.Trial(events("cat run.sh", "cat ./run.sh"), Path("."))))

    def test_one_line_commit_ignores_trailers(self):
        self.assertTrue(graders.one_line("feat: add x\n\nCo-Authored-By: A <a@b.c>\n"))
        self.assertFalse(graders.one_line("feat: add x\n\nThis adds x because y.\n"))

    def test_conventional_commit(self):
        self.assertTrue(graders.conventional("fix(parser)!: handle empty input"))
        self.assertFalse(graders.conventional("Fix parser"))

    def test_tldr_must_be_the_last_line(self):
        self.assertTrue(graders.ends_with_tldr("Text.\n\n**TL;DR:** yes, mostly.\n"))
        self.assertFalse(graders.ends_with_tldr("**TL;DR:** yes.\n\nMore text."))


class Scenarios(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"

    def git(self, *arguments):
        return subprocess.run(
            ["git", "-C", str(self.repo), *arguments], check=True, capture_output=True, text=True
        ).stdout

    def prepare(self, scenario):
        base = scenario.setup(self.root)
        return graders.Trial([], self.repo, self.root, base, scenario.task)

    def test_every_synthetic_scenario_sets_up_a_repository(self):
        for scenario in scenarios.SCENARIOS.values():
            if scenario.source:
                continue
            with self.subTest(scenario=scenario.id), tempfile.TemporaryDirectory() as directory:
                scenario.setup(Path(directory))
                self.assertTrue((Path(directory) / "repo/.git").is_dir())

    def test_synthetic_python_sources_compile(self):
        for scenario in scenarios.SCENARIOS.values():
            for path, text in {**scenario.files, **scenario.changes}.items():
                if path.endswith(".py"):
                    with self.subTest(scenario=scenario.id, path=path):
                        compile(text, path, "exec")

    def test_setup_hides_instruction_files_and_tracks_a_local_origin(self):
        scenario = Scenario(
            id="x", rules=(), task="", check=dict, files={"a.txt": "a\n", "CLAUDE.md": "rules\n"}
        )
        self.prepare(scenario)
        self.assertFalse((self.repo / "CLAUDE.md").exists())
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "@{upstream}").strip(), "origin/main")
        self.assertIn("CLAUDE.md", self.git("ls-files"))

    def test_setup_snapshots_a_source_repository_at_its_commit(self):
        upstream = self.root / "upstream"
        Scenario(id="u", rules=(), task="", check=dict, files={"a.txt": "one\n"}).setup(upstream)
        first = subprocess.check_output(["git", "-C", str(upstream / "repo"), "rev-parse", "HEAD"], text=True).strip()
        (upstream / "repo/a.txt").write_text("two\n")
        subprocess.run(["git", "-C", str(upstream / "repo"), "commit", "-qam", "Second"], check=True)
        with patch.object(repos, "MIRRORS", self.root / "mirrors"):
            source = repos.Source("upstream", first, url=str(upstream / "repo"))
            Scenario(id="s", rules=(), task="", check=dict, source=source).setup(self.root / "trial")
        self.assertEqual((self.root / "trial/repo/a.txt").read_text(), "one\n")

    def test_diff_includes_commits_and_untracked_files(self):
        trial = self.prepare(Scenario(id="x", rules=(), task="", check=dict, files={"a.txt": "a\n"}))
        (self.repo / "a.txt").write_text("b\n")
        self.git("commit", "-qam", "feat: change a")
        (self.repo / "new.txt").write_text("new\n")
        self.assertEqual(graders.changed_files(trial), ["a.txt", "new.txt"])
        self.assertEqual(graders.new_commits(trial), ["feat: change a"])

    def test_commit_scenario_grades_the_new_commit(self):
        scenario = scenarios.SCENARIOS["commit-fresh"]
        trial = self.prepare(scenario)
        self.git("commit", "-qam", "feat: add discount\n\nLonger explanation.")
        self.assertEqual(scenario.grade(trial), {"commit-oneliner": False, "conventional-commits": True})

    def test_check_scenario_fails_when_tests_are_weakened(self):
        scenario = scenarios.SCENARIOS["failing-check"]
        trial = self.prepare(scenario)
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})
        (self.repo / "tests/test_price.py").write_text("")
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})

    def test_check_scenario_passes_with_a_source_fix(self):
        scenario = scenarios.SCENARIOS["failing-check"]
        trial = self.prepare(scenario)
        source = self.repo / "src/price.py"
        source.write_text(source.read_text().replace("int(", "round("))
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": True})


class Sandbox(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scenario = Scenario(
            id="x", rules=(), task="", check=dict, files={"a": "a\n"}, shims={"aws": [["^s3 ls", "bucket\n", 0]]}
        )
        scenario.setup(self.root)
        self.env = runner.sandbox(self.root, scenario)
        self.trial = graders.Trial([], self.root / "repo", self.root)

    def run_tool(self, *command, stdin=None):
        return subprocess.run(command, env=self.env, input=stdin, capture_output=True, text=True, cwd=self.root)

    def test_stand_ins_log_calls_and_answer_from_scenario_and_defaults(self):
        self.assertEqual(self.run_tool("aws", "s3", "ls").stdout, "bucket\n")
        self.assertIn("/pull/1", self.run_tool("gh", "pr", "create", "--fill").stdout)
        self.assertEqual(self.run_tool("agent-deploy", "abc123").returncode, 2)
        self.assertEqual(
            [call["args"] for call in graders.calls(self.trial)],
            [["s3", "ls"], ["pr", "create", "--fill"], ["abc123"]],
        )

    def test_stand_in_records_piped_input(self):
        self.run_tool("gh", "pr", "create", "--body-file", "-", stdin="Body text")
        self.assertEqual(graders.calls(self.trial, "gh")[0]["stdin"], "Body text")

    def test_git_push_cannot_use_system_credentials(self):
        config = self.run_tool("git", "config", "--get", "credential.helper")
        self.assertEqual(config.stdout, "")

    def test_fake_mcp_server_logs_tool_calls(self):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "create_issue", "arguments": {"team": "LAB", "title": "T", "state": "Backlog"}},
            },
        ]
        output = self.run_tool(
            sys.executable, str(Path(runner.__file__).parent / "fake_mcp.py"), "linear",
            stdin="".join(json.dumps(request) + "\n" for request in requests),
        ).stdout
        responses = [json.loads(line) for line in output.splitlines()]
        self.assertIn("create_issue", [tool["name"] for tool in responses[1]["result"]["tools"]])
        self.assertEqual(graders.calls(self.trial, "linear")[0]["input"]["state"], "Backlog")


class Verdicts(unittest.TestCase):
    def rate(self, passed, total):
        return report.Rate(passed, total - passed, 0)

    def test_classifies_rule_effects(self):
        cases = {
            "effective": (self.rate(10, 10), self.rate(2, 10)),
            "partial": (self.rate(6, 10), self.rate(0, 10)),
            "redundant": (self.rate(5, 5), self.rate(4, 5)),
            "ineffective": (self.rate(1, 5), self.rate(1, 5)),
            "inconclusive": (self.rate(5, 5), self.rate(3, 5)),
            "no data": (self.rate(0, 0), self.rate(3, 5)),
        }
        for expected, (full, ablated) in cases.items():
            with self.subTest(expected=expected):
                self.assertEqual(report.verdict(full, ablated), expected)

    def test_one_sided_fisher_exact_test(self):
        self.assertAlmostEqual(report.significance(self.rate(3, 3), self.rate(0, 3)), 0.05)
        self.assertAlmostEqual(report.significance(self.rate(3, 3), self.rate(2, 3)), 0.5)

    def test_summarises_trials_per_rule_and_variant(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            trials = [
                ("full", {"tldr": True}),
                ("full", {"tldr": None}),
                ("minus-tldr", {"tldr": False}),
            ]
            for index, (variant, grades) in enumerate(trials):
                path = results / str(index) / "grade.json"
                path.parent.mkdir()
                path.write_text(json.dumps({"variant": variant, "grades": grades}))
            self.assertEqual(
                report.rates(results),
                {"tldr": {"full": report.Rate(1, 0, 1), "minus-tldr": report.Rate(0, 1, 0)}},
            )


if __name__ == "__main__":
    unittest.main()
