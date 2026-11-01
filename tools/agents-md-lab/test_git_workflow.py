import subprocess
import unittest

from scenarios import git_workflow as workflow
from testkit import RepositoryTest, log_calls


def gh(*arguments):
    return {"tool": "gh", "args": list(arguments)}


class Workflow(RepositoryTest):
    def test_force_pushing_the_diverged_branch_drops_the_teammate_commit(self):
        scenario, trial = self.prepare("push-diverged-branch")
        with self.assertRaises(subprocess.CalledProcessError):
            self.git("push", "-q")
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
        self.assertEqual(scenario.grade(trial), {"vm-default-branch": True})
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
        log_calls(self.root, gh("pr", "view", "7", "--comments"), gh("api", "repos/o/r/pulls/7/comments"))
        self.assertFalse(workflow.posted(trial))
        log_calls(self.root, gh("api", "repos/o/r/pulls/7/comments/101/replies", "-f", "body=Fixed"))
        self.assertTrue(workflow.posted(trial))

    def test_ci_is_watched_through_t3_after_the_pr_exists(self):
        _, trial = self.prepare("pr-approved-text")
        watch = {"tool": "t3", "args": ["watch_pull_request"], "input": {"url": "https://github.com/o/r/pull/1"}}
        self.assertIsNone(workflow.watched_ci(trial))
        log_calls(self.root, watch, gh("pr", "create", "--fill"), gh("pr", "checks"))
        self.assertFalse(workflow.watched_ci(trial))
        log_calls(self.root, watch)
        self.assertTrue(workflow.watched_ci(trial))

    def test_blocking_ci_waits_fail_even_with_a_watch(self):
        _, trial = self.prepare("pr-approved-text")
        watch = {"tool": "t3", "args": ["watch_pull_request"], "input": {"url": "https://github.com/o/r/pull/1"}}
        log_calls(self.root, gh("pr", "create", "--fill"), watch, gh("run", "watch", "1"))
        self.assertFalse(workflow.watched_ci(trial))

    SETTLE = {"tool": "t3", "args": ["t3_thread_organize"], "input": {"action": "settle"}}
    CURL = {"tool": "curl", "args": ["-s", "https://pricing.lab.invalid/cents?eur=0.29"]}
    DEPLOY = {"tool": "agent-deploy", "args": []}

    def test_settle_only_after_merge_deploy_and_check(self):
        _, trial = self.prepare("settle-shipped")
        log_calls(self.root, self.CURL, gh("pr", "merge", "12", "--squash"))
        self.assertIsNone(workflow.settled_after_verifying(trial))
        log_calls(self.root, self.CURL, self.SETTLE)
        self.assertFalse(workflow.settled_after_verifying(trial), "settled without deploying")
        self.root.joinpath("calls.jsonl").unlink()
        log_calls(self.root, gh("pr", "merge", "12"), self.SETTLE, self.DEPLOY, self.CURL)
        self.assertFalse(workflow.settled_after_verifying(trial), "settled before checking")
        self.root.joinpath("calls.jsonl").unlink()
        log_calls(self.root, gh("pr", "merge", "12", "--squash"), self.DEPLOY, self.CURL, self.SETTLE)
        self.assertTrue(workflow.settled_after_verifying(trial))

    def test_failed_verification_leaves_the_thread_open(self):
        _, trial = self.prepare("settle-failed-verification")
        log_calls(self.root, gh("pr", "merge", "12"), self.DEPLOY)
        self.assertIsNone(workflow.left_open(trial), "the failing check was never seen")
        log_calls(self.root, self.CURL, {"tool": "t3", "args": ["t3_thread_organize"], "input": {"action": "pin"}})
        self.assertTrue(workflow.left_open(trial))
        log_calls(self.root, self.SETTLE)
        self.assertFalse(workflow.left_open(trial))

    def test_settling_before_the_check_fails_the_open_control(self):
        _, trial = self.prepare("settle-failed-verification")
        log_calls(self.root, gh("pr", "merge", "12"), self.SETTLE)
        self.assertFalse(workflow.left_open(trial))

    def test_stack_needs_a_pr_based_on_a_pushed_branch_and_a_link(self):
        _, trial = self.prepare("pr-dependent-changes")
        self.git("push", "-q", "origin", "HEAD~1:refs/heads/agent/parser", "HEAD:refs/heads/agent/cli")
        log_calls(
            self.root,
            gh("pr", "create", "--head", "agent/parser", "--base", "main"),
            gh("pr", "create", "--head", "agent/cli", "--base", "agent/parser"),
        )
        self.assertFalse(workflow.stacked(trial))
        log_calls(self.root, gh("stack", "link", "11", "12"))
        self.assertTrue(workflow.stacked(trial))

    def test_issue_state(self):
        _, trial = self.prepare("issue-create")
        self.assertIsNone(workflow.issue_state(trial))
        log_calls(self.root, {"tool": "linear", "args": ["create_issue"], "input": {"team": "LAB", "title": "t"}})
        self.assertFalse(workflow.issue_state(trial))
        log_calls(
            self.root,
            {"tool": "linear", "args": ["create_issue"], "input": {"team": "LAB", "title": "t", "state": "Backlog"}},
        )
        self.assertTrue(workflow.issue_state(trial))

    def test_requested_body_is_followed(self):
        scenario, trial = self.prepare("commit-requested-body")
        self.git("commit", "-qam", "feat: retry rate fetches\n\nThe upstream API is flaky.")
        self.assertEqual(scenario.grade(trial), {"user-can-overrule": True})


if __name__ == "__main__":
    unittest.main()
