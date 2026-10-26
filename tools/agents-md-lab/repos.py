"""Git helper and snapshots of the owner's repositories at pinned commits, served from local mirrors."""

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

OWNER = "kahlstrm"
MIRRORS = Path.home() / ".cache/agents-md-lab/mirrors"


def git(repo, *arguments, env=None, system=False):
    """Git in `repo`, returning stdout. System configuration (credentials, hooks) only with `system`."""
    isolation = {} if system else {"GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True,
        capture_output=True,
        text=True,
        env=os.environ | isolation | (env or {}),
    ).stdout


@dataclass(frozen=True)
class Source:
    name: str
    commit: str
    url: str = ""

    @property
    def remote(self):
        return self.url or f"https://github.com/{OWNER}/{self.name}.git"


def mirror(source: Source):
    path = MIRRORS / f"{source.name}.git"
    if not path.exists():
        MIRRORS.mkdir(parents=True, exist_ok=True)
        git(MIRRORS, "clone", "--quiet", "--mirror", source.remote, str(path), system=True)
    try:
        git(path, "cat-file", "-e", f"{source.commit}^{{commit}}")
    except subprocess.CalledProcessError:
        git(path, "fetch", "--quiet", "origin", system=True)
    return path


def checkout(source: Source, repo: Path):
    git(repo.parent, "clone", "--quiet", "--no-checkout", str(mirror(source)), str(repo))
    git(repo, "checkout", "--quiet", "-B", "main", source.commit)
    git(repo, "remote", "remove", "origin")
