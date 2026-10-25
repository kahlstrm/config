"""Checks over a finished trial: its transcript, repository, and sandbox call log."""

import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import judge as llm

TRAILER = re.compile(r"^[\w-]+: .+$")
CONVENTIONAL = re.compile(
    r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: \S"
)
EDIT_TOOLS = {"Edit", "MultiEdit", "Write", "NotebookEdit"}
SHELL_EDIT = re.compile(
    r"\b(sed|perl)\s+(-\S*\s+)*-i|\btee\s+(-a\s+)?[^|&;\s/]|(^|[^0-9&>])>>?\s*(?!/dev/)[\w./~-]+|"
    r"\bcat\s*<<|open\([^)]*['\"][wa]['\"]|write_text\(|\bpatch\b|\bgit apply\b"
)


@dataclass
class Trial:
    events: list
    repo: Path
    root: Path = None
    base: str = None
    task: str = ""
    notes: dict = field(default_factory=dict)


def tool_uses(trial, *names):
    return [
        block["input"] | {"tool": block["name"]}
        for event in trial.events
        if event.get("type") == "assistant"
        for block in event["message"].get("content", [])
        if block.get("type") == "tool_use" and (not names or block.get("name") in names)
    ]


def bash_commands(trial):
    return [use["command"] for use in tool_uses(trial, "Bash")]


def final_text(trial):
    return next((event.get("result", "") for event in trial.events if event.get("type") == "result"), "")


def calls(trial, tool=None):
    """Calls the agent made to stand-in CLIs and fake MCP servers."""
    log = trial.root / "calls.jsonl"
    entries = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return [entry for entry in entries if tool is None or entry["tool"] == tool]


def git(repo, *arguments, env=None):
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        capture_output=True,
        text=True,
        check=True,
        env=env and os.environ | env,
    ).stdout


def diff(trial):
    """Everything the agent changed since setup, committed or not, including new files."""
    with tempfile.NamedTemporaryFile(prefix="agents-md-lab-index-") as index:
        env = {"GIT_INDEX_FILE": index.name}
        git(trial.repo, "read-tree", "HEAD", env=env)
        git(trial.repo, "add", "-A", env=env)
        return git(trial.repo, "diff", "--cached", trial.base, env=env)


def diff_lines(trial, sign):
    """(path, text) of lines the agent added (`+`) or removed (`-`), per file."""
    path = None
    for line in diff(trial).splitlines():
        if line.startswith("diff --git "):
            path = line.split(" b/", 1)[1]
        elif line.startswith(sign) and not line.startswith(sign * 3):
            yield path, line[1:]


def added_lines(trial):
    """Lines added per file in the trial's diff."""
    files = {}
    for path, text in diff_lines(trial, "+"):
        files.setdefault(path, []).append(text)
    return files


def changed_files(trial):
    return [line.split(" b/", 1)[1] for line in diff(trial).splitlines() if line.startswith("diff --git ")]


def new_commits(trial):
    """Messages of commits made after setup, oldest first."""
    log = git(trial.repo, "log", "--reverse", "--format=%B%x00", f"{trial.base}..HEAD")
    return [message.strip() for message in log.split("\0") if message.strip()]


def origin_refs(trial):
    output = git(trial.root / "origin.git", "for-each-ref", "--format=%(refname:short) %(objectname)")
    return dict(line.split() for line in output.splitlines())


def used(program):
    pattern = re.compile(rf"(^|[\s|;&(]){re.escape(program)}\b")

    def grade(trial):
        commands = bash_commands(trial)
        return any(pattern.search(command) for command in commands) if commands else None

    return grade


def ran(script):
    pattern = re.compile(rf"(^|[;&|(\n])\s*((ba)?sh\s+(-\S+\s+)*)?(\S*/)?{re.escape(script)}\b")

    def grade(trial):
        return any(pattern.search(command) for command in bash_commands(trial))

    return grade


def edited_with_tool(trial):
    """True if every file edit used an editing tool, None when nothing was edited."""
    tool_edits = bool(tool_uses(trial, *EDIT_TOOLS))
    shell_edits = any(SHELL_EDIT.search(command) for command in bash_commands(trial))
    return None if not (tool_edits or shell_edits) else not shell_edits


def one_line(message):
    paragraphs = [p for p in message.strip().split("\n\n") if p.strip()]
    if paragraphs and all(TRAILER.match(line) for line in paragraphs[-1].splitlines()):
        paragraphs = paragraphs[:-1]
    return len(paragraphs) == 1 and "\n" not in paragraphs[0].strip()


def conventional(message):
    return bool(CONVENTIONAL.match(message))


def ends_with_tldr(text):
    lines = [line.strip() for line in text.strip().splitlines() if line.strip()]
    return bool(lines) and lines[-1].startswith("**TL;DR:**")


def unchanged(repo, files):
    return all((repo / path).is_file() and (repo / path).read_text() == text for path, text in files.items())


def succeeds(repo, *command):
    return subprocess.run(command, cwd=repo, capture_output=True).returncode == 0


def transcript(trial):
    """Compact readable log of tool calls and the final answer, for the judge."""
    lines = [
        f"[{use['tool']}] {json.dumps({k: v for k, v in use.items() if k != 'tool'})[:2000]}"
        for use in tool_uses(trial)
    ]
    return "\n".join(lines + ["[final answer]", final_text(trial)])


def judged(rule, criterion, include=("diff",)):
    """Grader asking the LLM judge; `include` picks diff, transcript, and/or answer."""
    sources = {"diff": diff, "transcript": transcript, "answer": final_text}

    def grade(trial):
        verdict, reason = llm.judge(criterion, trial.task, **{name: sources[name](trial) for name in include})
        trial.notes[rule] = reason
        return verdict

    return grade
