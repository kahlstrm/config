import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import catalogue
import claims
import graders
import lab
import prompt
import report
import repos
import runner
import scenarios
from scenarios import Scenario
from scenarios.kit import commit
from testkit import RepositoryTest, trial

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
        for path, rules in catalogue.SOURCES.items():
            with self.subTest(path=path):
                remaining = (REPOSITORY / path).read_text()
                for rule in rules:
                    remaining = prompt.without(remaining, rule.text)
                leftover = [line for line in remaining.splitlines() if line.strip() and not line.startswith("#")]
                self.assertEqual(leftover, [])

    def test_ablating_a_rule_removes_text_that_presupposes_it(self):
        ablated = lab.ablate((REPOSITORY / "config/AGENTS.md").read_text(), "pr-text-approval")
        self.assertNotIn("present the exact text", ablated)
        self.assertIn("Write ONLY concise oneliners", ablated)

    def test_pruning_removes_several_rules_and_keeps_the_rest(self):
        pruned = lab.prune((REPOSITORY / "config/AGENTS.md").read_text(), ["jq", "dry", "pr-text-approval"])
        for removed in ("use `jq`", "Follow DRY", "present the exact text"):
            self.assertNotIn(removed, pruned)
        self.assertIn("Write ONLY concise oneliners", pruned)

    def test_full_only_plans_no_ablations(self):
        instructions = (REPOSITORY / "config/AGENTS.md").read_text()
        arguments = lab.argparse.Namespace(
            scenario=["paivabot-stats-command"], rule=None, repeat=2, baseline=False, full_only=True, out=Path("/r")
        )
        self.assertEqual([variant for _, variant, *_ in lab.plan(arguments, instructions)], ["full", "full"])

    def test_every_rule_is_measured_or_says_why_not(self):
        covered = {rule for scenario in scenarios.SCENARIOS.values() for rule in scenario.rules}
        claimed = {claim.rule for claim in claims.CLAIMS}
        self.assertLessEqual(covered | claimed, set(catalogue.RULES))
        for rule in catalogue.RULES.values():
            with self.subTest(rule=rule.id):
                self.assertNotEqual(bool(rule.note), rule.id in covered | claimed)


class Graders(unittest.TestCase):
    def test_extracts_bash_commands_and_final_text(self):
        finished = trial("ls", "jq length x.json", answer="Answer")
        self.assertEqual(graders.bash_commands(finished), ["ls", "jq length x.json"])
        self.assertEqual(graders.final_text(finished), "Answer")

    def test_running_a_script_differs_from_reading_it(self):
        ran = graders.ran("run.sh")
        self.assertTrue(ran(trial("cd /x && ./run.sh")))
        self.assertTrue(ran(trial("bash -x run.sh")))
        self.assertFalse(ran(trial("cat run.sh", "cat ./run.sh")))

    def test_one_line_commit_ignores_trailers(self):
        self.assertTrue(graders.one_line("feat: add x\n\nCo-Authored-By: A <a@b.c>\n"))
        self.assertFalse(graders.one_line("feat: add x\n\nThis adds x because y.\n"))

    def test_conventional_commit(self):
        self.assertTrue(graders.conventional("fix(parser)!: handle empty input"))
        self.assertFalse(graders.conventional("Fix parser"))

    def test_tldr_must_be_the_last_line(self):
        self.assertTrue(graders.ends_with_tldr(trial(answer="Text.\n\n**TL;DR:** yes, mostly.\n")))
        self.assertFalse(graders.ends_with_tldr(trial(answer="**TL;DR:** yes.\n\nMore text.")))

    def test_judged_rules_share_one_judge_call_and_gates_skip_it(self):
        checks = {
            "a": graders.Judged("criterion a"),
            "b": graders.Judged("criterion b", include=("answer",)),
            "skipped": graders.Judged("never asked", gate=lambda trial: None),
            "failed": graders.Judged("never asked", gate=lambda trial: False),
            "scripted": lambda trial: True,
        }
        verdicts = {"a": (True, "fine"), "b": (False, "missing")}
        with patch.object(graders.llm, "judge", return_value=verdicts) as judge, patch.object(graders, "diff", return_value="+x"):
            grades = graders.grade(checks, trial(answer="done"))
        judge.assert_called_once()
        self.assertEqual(judge.call_args.args[0], {"a": "criterion a", "b": "criterion b"})
        self.assertEqual(judge.call_args.kwargs, {"diff": "+x", "answer": "done"})
        self.assertEqual(grades, {"a": True, "b": False, "skipped": None, "failed": False, "scripted": True})


class Scenarios(RepositoryTest):
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
        self.prepare(Scenario(id="x", task="", checks={}, files={"a.txt": "a\n", "CLAUDE.md": "rules\n"}))
        self.assertFalse((self.repo / "CLAUDE.md").exists())
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "@{upstream}").strip(), "origin/main")
        self.assertIn("CLAUDE.md", self.git("ls-files"))

    def test_setup_snapshots_a_source_repository_at_its_commit(self):
        upstream = self.root / "upstream"
        first = Scenario(id="u", task="", checks={}, files={"a.txt": "one\n"}).setup(upstream)
        commit(upstream / "repo", "Second", {"a.txt": "two\n"})
        (self.root / "trial").mkdir()
        with patch.object(repos, "MIRRORS", self.root / "mirrors"):
            source = repos.Source("upstream", first, url=str(upstream / "repo"))
            Scenario(id="s", task="", checks={}, source=source).setup(self.root / "trial")
        self.assertEqual((self.root / "trial/repo/a.txt").read_text(), "one\n")

    def test_prepared_state_is_not_counted_as_agent_work(self):
        prepare = lambda root: commit(root / "repo", "feat: setup", {"b.txt": "b\n"})
        _, prepared = self.prepare(Scenario(id="x", task="", checks={}, files={"a.txt": "a\n"}, prepare=prepare))
        self.assertEqual((graders.new_commits(prepared), graders.diff(prepared)), ([], ""))

    def test_diff_includes_commits_and_untracked_files(self):
        _, trial = self.prepare(Scenario(id="x", task="", checks={}, files={"a.txt": "a\n"}))
        (self.repo / "a.txt").write_text("b\n")
        self.git("commit", "-qam", "feat: change a")
        (self.repo / "new.txt").write_text("new\n")
        self.assertEqual(list(graders.diff_files(trial)), ["a.txt", "new.txt"])
        self.assertEqual(graders.new_commits(trial), ["feat: change a"])

    def test_commit_scenario_grades_the_new_commit(self):
        scenario, trial = self.prepare("commit-fresh")
        self.git("commit", "-qam", "feat: add discount\n\nLonger explanation.")
        self.assertEqual(scenario.grade(trial), {"commit-oneliner": False, "conventional-commits": True})

    def test_check_scenario_fails_when_tests_are_weakened(self):
        scenario, trial = self.prepare("failing-check")
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})
        (self.repo / "tests/test_price.py").write_text("")
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": False})

    def test_check_scenario_passes_with_a_source_fix(self):
        scenario, trial = self.prepare("failing-check")
        source = self.repo / "src/price.py"
        source.write_text(source.read_text().replace("int(", "round("))
        self.assertEqual(scenario.grade(trial), {"no-skip-verification": True})


class Sandbox(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scenario = Scenario(id="x", task="", checks={}, files={"a": "a\n"}, shims={"aws": [["^s3 ls", "bucket\n", 0]]})
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

    def test_stand_in_rules_can_depend_on_earlier_calls(self):
        self.assertEqual(self.run_tool("gh", "pr", "view").returncode, 1)
        self.run_tool("gh", "pr", "create", "--fill")
        self.assertIn('"state":"OPEN"', self.run_tool("gh", "pr", "view").stdout)

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


class Codex(unittest.TestCase):
    def item(self, kind, **fields):
        return {"type": "item.completed", "item": {"type": kind, **fields}}

    def test_codex_events_read_like_claude_events(self):
        events = runner.from_codex([
            {"type": "thread.started"},
            self.item("agent_message", text="Reading first."),
            self.item("command_execution", command="/run/current-system/sw/bin/bash -lc 'cat a.txt | jq .x'", exit_code=0),
            self.item("file_change", changes=[{"path": "/r/a.txt", "kind": "update"}, {"path": "/r/b.txt", "kind": "add"}]),
            self.item("mcp_tool_call", server="linear", tool="create_issue", arguments={"title": "t"}),
            self.item("agent_message", text="done\n\n**TL;DR:** done."),
            {"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 2}},
        ], "gpt-6.1-sol")
        finished = graders.Trial(events, Path("/r"))
        self.assertEqual(graders.bash_commands(finished), ["cat a.txt | jq .x"])
        self.assertEqual(
            [(use["tool"], use.get("file_path")) for use in graders.tool_uses(finished, *graders.EDIT_TOOLS)],
            [("Edit", "/r/a.txt"), ("Write", "/r/b.txt")],
        )
        self.assertEqual(graders.tool_uses(finished, "mcp__linear__create_issue")[0]["title"], "t")
        self.assertTrue(graders.ends_with_tldr(finished))
        self.assertIsNone(runner.session_error(events, None))

    def test_failed_codex_turn_is_a_session_error(self):
        events = runner.from_codex([{"type": "turn.failed", "error": {"message": "You've hit your usage limit. Try again at 3:05 AM."}}], None)
        self.assertTrue(runner.usage_limited(runner.session_error(events, None)))
        self.assertEqual(runner.session_error(runner.from_codex([], None), "exit status 1"), "exit status 1")

    def test_codex_command_selects_model_effort_and_fake_mcp_servers(self):
        command = runner.codex_command("task", "gpt-6.1-sol", "medium", Path("/r"), ["linear"])
        self.assertEqual(command[-1], "task")
        self.assertIn('model_reasoning_effort="medium"', command)
        self.assertIn('mcp_servers.linear.args=["/r/libexec/fake_mcp.py", "linear"]', command)
        self.assertIn("--ignore-user-config", command)


class Sessions(unittest.TestCase):
    def test_failed_sessions_are_errors_not_grades(self):
        limited = [{"type": "result", "is_error": True, "result": "You've hit your session limit · resets 1pm"}]
        self.assertEqual(runner.session_error(limited, None), limited[0]["result"])
        self.assertTrue(runner.usage_limited(runner.session_error(limited, None)))
        self.assertEqual(runner.session_error([], "killed"), "killed")
        self.assertIsNone(runner.session_error([{"type": "result", "is_error": False, "result": "done"}], None))


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

    def results(self, *trials):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        results = Path(directory.name)
        for index, (variant, grades, *error) in enumerate(trials):
            path = results / str(index) / "grade.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"variant": variant, "grades": grades, "error": error[0] if error else None}))
        return results

    def test_summarises_trials_per_rule_and_variant(self):
        results = self.results(
            ("full", {"tldr": True}),
            ("full", {"tldr": None}),
            ("minus-tldr", {"tldr": False}),
            ("minus-tldr", {"tldr": False}, "You've hit your session limit"),
        )
        self.assertEqual(
            report.rates(results),
            {"tldr": {"full": report.Rate(1, 0, 1), "minus-tldr": report.Rate(0, 1, 0)}},
        )

    def test_compares_full_instructions_of_two_runs(self):
        current = self.results(*[("full", {"tldr": True, "jq": True})] * 5, ("minus-tldr", {"tldr": False}))
        pruned = self.results(*[("full", {"tldr": False, "jq": True})] * 5)
        table = report.comparison(current, pruned)
        self.assertIn("| tldr | 5/5 | 0/5 | 0.004 | regressed |", table)
        self.assertIn("| jq | 5/5 | 5/5 | 1.000 | held |", table)


if __name__ == "__main__":
    unittest.main()
