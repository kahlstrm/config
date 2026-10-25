"""Scenario definition and repository setup shared by all scenario modules."""

import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

import repos

HIDDEN = ("CLAUDE.md", "AGENTS.md", "GEMINI.md", "opencode.json", ".claude", ".codex", ".opencode")


def git(repo, *arguments):
    """Git without system configuration, whose hooks would alter setup commits."""
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True,
        capture_output=True,
        text=True,
        env=os.environ | {"GIT_CONFIG_NOSYSTEM": "1"},
    ).stdout


def write(repo: Path, files: dict):
    for path, text in files.items():
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text(text)
        if text.startswith("#!"):
            (repo / path).chmod(0o755)


@dataclass(frozen=True)
class Scenario:
    """A task in a prepared repository that gives `rules` a chance to matter.

    The repository starts from `source` (a pinned snapshot of a real repository)
    or from `files`, then gets `commits` and finally uncommitted `changes`.
    Instruction files in `HIDDEN` are removed from the worktree without changing
    history or `git status`. `origin` is a local bare clone. `shims` adds canned
    responses for stand-in CLIs and `mcp` names fake MCP servers to attach.
    `prepare(root)` runs last, for state such as diverged branches.
    `check` maps a finished `graders.Trial` to `{rule: True | False | None}`.
    """

    id: str
    rules: tuple
    task: str
    check: Callable
    files: dict = field(default_factory=dict)
    commits: tuple = ()
    changes: dict = field(default_factory=dict)
    source: Optional[repos.Source] = None
    shims: dict = field(default_factory=dict)
    mcp: tuple = ()
    prepare: Optional[Callable] = None

    def setup(self, root: Path):
        """Prepare `root/repo` and `root/origin.git`; return the base commit."""
        repo = root / "repo"
        if self.source:
            repos.checkout(self.source, repo)
        else:
            repo.mkdir(parents=True)
            git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.name", "Lab")
        git(repo, "config", "user.email", "lab@example.invalid")
        for message, files in ((("Initial commit", self.files),) if self.files else ()) + tuple(self.commits):
            write(repo, files)
            git(repo, "add", "-A")
            git(repo, "commit", "-qm", message)
        for path in git(repo, "ls-files", "--", *HIDDEN).splitlines():
            git(repo, "update-index", "--skip-worktree", path)
            (repo / path).unlink()
        git(repo, "clone", "-q", "--bare", ".", str(root / "origin.git"))
        git(repo, "remote", "add", "origin", str(root / "origin.git"))
        git(repo, "fetch", "-q", "origin")
        git(repo, "branch", "-q", "-u", "origin/main")
        write(repo, self.changes)
        base = git(repo, "rev-parse", "HEAD").strip()
        if self.prepare:
            self.prepare(root)
        return base

    def grade(self, trial):
        return self.check(trial)
