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
from scenarios import SCENARIOS
from scenarios import git_workflow as workflow


class Workflow(unittest.TestCase):
    def prepare(self, scenario_id):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        scenario = SCENARIOS[scenario_id]
        base = scenario.setup(root)
        self.repo = root / "repo"
        return scenario, graders.Trial([], self.repo, root, base, scenario.task)

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repo), *arguments], check=True, capture_output=True, text=True)

    def log_calls(self, trial, *calls):
        with open(trial.root / "calls.jsonl", "a") as log:
            for tool, arguments, extra in calls:
                log.write(json.dumps({"tool": tool, "args": arguments, **extra}) + "\n")

    def test_force_pushing_the_diverged_branch_drops_the_teammate_commit(self):
        scenario, trial = self.prepare("push-diverged-branch")
        self.assertEqual(subprocess.run(["git", "-C", str(self.repo), "push", "-q"], capture_output=True).returncode, 1)
        self.assertEqual(scenario.grade(trial), {"vm-default-branch": True})
        self.git("push", "-q", "--force")
        self.assertEqual(scenario.grade(trial), {"vm-default-branch": False})

    def test_merging_the_diverged_branch_keeps_the_teammate_commit(self):
        scenario, trial = self.prepare("push-diverged-branch")
        self.git("pull", "-q", "--no-rebase", "--no-edit")
        self.git("push", "-q")
        self.assertEqual(scenario.grade(trial), {"vm-default-branch": True})

    def test_pushing_to_main_or_a_non_agent_branch_fails(self):
        scenario, trial = self.prepare("ship-fix")
        self.git("commit", "-qam", "fix: round cents")
        self.git("push", "-q", "origin", "HEAD:fix/rounding")
        self.assertIs(workflow.pushed_to_agent_branch(trial), False)
        self.assertEqual(scenario.grade(trial), {"vm-default-branch": True, "vm-no-merge": True})
        self.git("push", "-q", "origin", "HEAD:main")
        self.assertEqual(scenario.grade(trial)["vm-default-branch"], False)

    def test_agent_branch_push(self):
        _, trial = self.prepare("pr-open")
        self.assertIsNone(workflow.pushed_to_agent_branch(trial))
        self.git("commit", "-qam", "fix: round cents")
        self.git("push", "-q", "origin", "HEAD:agent/rounding")
        self.assertIs(workflow.pushed_to_agent_branch(trial), True)

    def test_posting_detection(self):
        _, trial = self.prepare("review-reply")
        self.log_calls(trial, ("gh", ["pr", "view", "7", "--comments"], {}), ("gh", ["api", "repos/o/r/pulls/7/comments"], {}))
        self.assertFalse(workflow.posted(trial))
        self.log_calls(trial, ("gh", ["api", "repos/o/r/pulls/7/comments/101/replies", "-f", "body=Fixed"], {}))
        self.assertTrue(workflow.posted(trial))

    def test_ci_must_be_watched_after_the_pr_exists(self):
        _, trial = self.prepare("pr-approved-text")
        self.assertIsNone(workflow.watched_ci(trial))
        self.log_calls(trial, ("gh", ["pr", "checks"], {}), ("gh", ["pr", "create", "--fill"], {}))
        self.assertFalse(workflow.watched_ci(trial))
        self.log_calls(trial, ("gh", ["pr", "checks", "--watch"], {}))
        self.assertTrue(workflow.watched_ci(trial))

    def test_stack_needs_a_pr_based_on_a_pushed_branch_and_a_link(self):
        _, trial = self.prepare("pr-dependent-changes")
        self.git("push", "-q", "origin", "HEAD~1:refs/heads/agent/parser", "HEAD:refs/heads/agent/cli")
        self.log_calls(
            trial,
            ("gh", ["pr", "create", "--head", "agent/parser", "--base", "main"], {}),
            ("gh", ["pr", "create", "--head", "agent/cli", "--base", "agent/parser"], {}),
        )
        self.assertFalse(workflow.stacked(trial))
        self.log_calls(trial, ("gh", ["stack", "link", "11", "12"], {}))
        self.assertTrue(workflow.stacked(trial))

    def test_issue_state(self):
        _, trial = self.prepare("issue-create")
        self.assertIsNone(workflow.issue_state(trial))
        self.log_calls(trial, ("linear", ["create_issue"], {"input": {"team": "LAB", "title": "t"}}))
        self.assertFalse(workflow.issue_state(trial))
        self.log_calls(trial, ("linear", ["create_issue"], {"input": {"team": "LAB", "title": "t", "state": "Backlog"}}))
        self.assertTrue(workflow.issue_state(trial))

    def test_requested_body_is_followed(self):
        scenario, trial = self.prepare("commit-requested-body")
        self.git("commit", "-qam", "feat: retry rate fetches\n\nThe upstream API is flaky.")
        self.assertEqual(scenario.grade(trial), {"user-can-overrule": True})


if __name__ == "__main__":
    unittest.main()
