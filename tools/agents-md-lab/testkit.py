"""Fixtures shared by the lab's unit tests."""

import json
import tempfile
import unittest
from pathlib import Path

import graders
from repos import git
from scenarios import SCENARIOS


def tool(name, **arguments):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": name, "input": arguments}]}}


def bash(*commands):
    return [tool("Bash", command=command) for command in commands]


def trial(*commands, answer="done", root=None):
    return graders.Trial(bash(*commands) + [{"type": "result", "result": answer}], Path("."), root)


def log_calls(root, *calls):
    with open(root / "calls.jsonl", "a") as log:
        log.writelines(json.dumps(call) + "\n" for call in calls)


class RepositoryTest(unittest.TestCase):
    """A temporary trial root per test, with helpers to set up scenarios in it."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"

    def prepare(self, scenario, *commands):
        """Set up `scenario` (an id or a Scenario); return it with a trial of `commands`."""
        scenario = SCENARIOS[scenario] if isinstance(scenario, str) else scenario
        base = scenario.setup(self.root)
        return scenario, graders.Trial(bash(*commands), self.repo, self.root, base, scenario.task)

    def git(self, *arguments):
        return git(self.repo, *arguments)

    def edit(self, path, old, new):
        file = self.repo / path
        self.assertIn(old, file.read_text())
        file.write_text(file.read_text().replace(old, new))
