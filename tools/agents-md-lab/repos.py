"""Snapshots of the owner's repositories at pinned commits, served from local mirrors."""

import subprocess
from dataclasses import dataclass
from pathlib import Path

OWNER = "kahlstrm"
MIRRORS = Path.home() / ".cache/agents-md-lab/mirrors"


@dataclass(frozen=True)
class Source:
    name: str
    commit: str
    url: str = ""

    @property
    def remote(self):
        return self.url or f"https://github.com/{OWNER}/{self.name}.git"


def git(*arguments, cwd=None):
    subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True)


def mirror(source: Source):
    path = MIRRORS / f"{source.name}.git"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        git("clone", "--quiet", "--mirror", source.remote, str(path))
    if subprocess.run(["git", "-C", str(path), "cat-file", "-e", f"{source.commit}^{{commit}}"], capture_output=True).returncode:
        git("-C", str(path), "fetch", "--quiet", "origin")
    return path


def checkout(source: Source, repo: Path):
    git("clone", "--quiet", "--no-checkout", str(mirror(source)), str(repo))
    git("-C", str(repo), "checkout", "--quiet", "-B", "main", source.commit)
    git("-C", str(repo), "remote", "remove", "origin")
