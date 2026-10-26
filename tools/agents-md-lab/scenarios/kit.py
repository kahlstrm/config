"""Scenario definition and repository setup shared by all scenario modules."""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

import graders
import repos
from repos import git

HIDDEN = ("CLAUDE.md", "AGENTS.md", "GEMINI.md", "opencode.json", ".claude", ".codex", ".opencode")
PAIVABOT = repos.Source("paivabot", "57261a509a878872687a3e87805a9d9286d66823")


def write(repo: Path, files: dict):
    for path, text in files.items():
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text(text)
        if text.startswith("#!"):
            (repo / path).chmod(0o755)


def commit(repo: Path, message, files):
    write(repo, files)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", message)


@dataclass(frozen=True)
class Scenario:
    """A task in a prepared repository that gives the `checks` rules a chance to matter.

    `checks` maps each rule to a grader: a function of a finished `graders.Trial`
    returning True, False or None (not applicable), or a `graders.Judged`.
    The repository starts from `source` (a pinned snapshot of a real repository)
    or from `files`, then gets `commits` and finally uncommitted `changes`.
    Instruction files in `HIDDEN` are removed from the worktree without changing
    history or `git status`. `origin` is a local bare clone. `prepare(root)` adds
    further state such as diverged branches. `shims` adds canned responses for
    stand-in CLIs and `mcp` names fake MCP servers to attach.
    """

    id: str
    task: str
    checks: dict
    files: dict = field(default_factory=dict)
    commits: tuple = ()
    changes: dict = field(default_factory=dict)
    source: Optional[repos.Source] = None
    shims: dict = field(default_factory=dict)
    mcp: tuple = ()
    prepare: Optional[Callable] = None

    @property
    def rules(self):
        return tuple(self.checks)

    def setup(self, root: Path):
        """Prepare `root/repo` and `root/origin.git`; return the base commit agent work is measured from."""
        repo = root / "repo"
        if self.source:
            repos.checkout(self.source, repo)
        else:
            repo.mkdir(parents=True)
            git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.name", "Lab")
        git(repo, "config", "user.email", "lab@example.invalid")
        for message, files in ((("Initial commit", self.files),) if self.files else ()) + tuple(self.commits):
            commit(repo, message, files)
        for path in git(repo, "ls-files", "--", *HIDDEN).splitlines():
            git(repo, "update-index", "--skip-worktree", path)
            (repo / path).unlink()
        git(repo, "clone", "-q", "--bare", ".", str(root / "origin.git"))
        git(repo, "remote", "add", "origin", str(root / "origin.git"))
        git(repo, "fetch", "-q", "origin")
        git(repo, "branch", "-q", "-u", "origin/main")
        write(repo, self.changes)
        if self.prepare:
            self.prepare(root)
        return git(repo, "rev-parse", "HEAD").strip()

    def grade(self, trial):
        return graders.grade(self.checks, trial)
