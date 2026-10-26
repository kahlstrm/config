"""Checks over a finished trial: its transcript, repository, and sandbox call log."""

import json
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

import judge as llm
from repos import git

TRAILER = re.compile(r"^[\w-]+: .+$")
CONVENTIONAL = re.compile(
    r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: \S"
)
EDIT_TOOLS = {"Edit", "MultiEdit", "Write", "NotebookEdit"}
SHELL_EDIT = re.compile(
    r"\b(sed|perl)\s+(-\S*\s+)*-i|\btee\s+(-a\s+)?[^|&;\s/]|(^|[^0-9&>])>>?\s*(?!/dev/)[\w./~-]+|"
    r"\bcat\s*<<|open\([^)]*['\"][wa]['\"]|write_text\(|\bpatch\b|\bgit apply\b"
)
JQ = re.compile(r"(^|[\s|;&(])jq\b|--jq\b")
OTHER_JSON_PARSER = re.compile(r"\|\s*(python3?|node|ruby|perl)\b|\bjson\.loads?\b|JSON\.parse")
SUPPRESSION = re.compile(r"noqa|type:\s*ignore|unittest\.skip|@skip|\.skipTest\(|expectedFailure")


def run_plain(command, cwd):
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=300)


@dataclass
class Trial:
    events: list
    repo: Path
    root: Path = None
    base: str = None
    task: str = ""
    # Runs a command for a grader; the runner substitutes the trial's sandbox.
    execute: Callable = run_plain
    notes: dict = field(default_factory=dict)
    # The final diff, set by the runner once the session ended, so graders share it.
    final_diff: Optional[str] = field(default=None, repr=False)


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


def commands_matching(trial, pattern):
    return [command for command in bash_commands(trial) if pattern.search(command)]


def final_text(trial):
    return next((event.get("result", "") for event in trial.events if event.get("type") == "result"), "")


def calls(trial, tool=None):
    """Calls the agent made to stand-in CLIs and fake MCP servers."""
    log = trial.root / "calls.jsonl"
    entries = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return [entry for entry in entries if tool is None or entry["tool"] == tool]


def diff(trial):
    """Everything the agent changed since setup, committed or not, including new files."""
    if trial.final_diff is not None:
        return trial.final_diff
    with tempfile.NamedTemporaryFile(prefix="agents-md-lab-index-") as index:
        env = {"GIT_INDEX_FILE": index.name}
        git(trial.repo, "read-tree", "HEAD", env=env)
        git(trial.repo, "add", "-A", env=env)
        return git(trial.repo, "diff", "--cached", trial.base, env=env)


def diff_files(trial):
    """{path: (added lines, removed lines)} for every file the agent changed."""
    files, path = {}, None
    for line in diff(trial).splitlines():
        if line.startswith("diff --git "):
            path = line.split(" b/", 1)[1]
            files[path] = ([], [])
        elif line[:1] in "+-" and line[:3] not in ("+++", "---"):
            files[path]["+-".index(line[0])].append(line[1:])
    return files


def new_commits(trial):
    """Messages of commits made after setup, oldest first."""
    log = git(trial.repo, "log", "--reverse", "--format=%B%x00", f"{trial.base}..HEAD")
    return [message.strip() for message in log.split("\0") if message.strip()]


def last_commit(trial):
    return next(iter(new_commits(trial)[-1:]), None)


def last_commit_is(predicate):
    """Grader applying `predicate` to the newest commit message; None without a new commit."""

    def grade(trial):
        message = last_commit(trial)
        return None if message is None else bool(predicate(message))

    return grade


def origin_refs(trial):
    output = git(trial.root / "origin.git", "for-each-ref", "--format=%(refname:short) %(objectname)")
    return dict(line.split() for line in output.splitlines())


def ran(script):
    pattern = re.compile(rf"(^|[;&|(\n])\s*((ba)?sh\s+(-\S+\s+)*)?(\S*/)?{re.escape(script)}\b")
    return lambda trial: bool(commands_matching(trial, pattern))


def edited_with_tool(trial):
    """True if every file edit used an editing tool, None when nothing was edited."""
    tool_edits = bool(tool_uses(trial, *EDIT_TOOLS))
    shell_edits = bool(commands_matching(trial, SHELL_EDIT))
    return None if not (tool_edits or shell_edits) else not shell_edits


def parsed_json_with_jq(trial):
    """True when jq parsed JSON, False when another parser did, None when nothing was parsed."""
    if commands_matching(trial, JQ):
        return True
    return False if commands_matching(trial, OTHER_JSON_PARSER) else None


def one_line(message):
    paragraphs = [p for p in message.strip().split("\n\n") if p.strip()]
    if paragraphs and all(TRAILER.match(line) for line in paragraphs[-1].splitlines()):
        paragraphs = paragraphs[:-1]
    return len(paragraphs) == 1 and "\n" not in paragraphs[0].strip()


def conventional(message):
    return bool(CONVENTIONAL.match(message))


def ends_with_tldr(trial):
    lines = [line.strip() for line in final_text(trial).strip().splitlines() if line.strip()]
    return bool(lines) and lines[-1].startswith("**TL;DR:**")


def succeeds(trial, *command):
    return trial.execute(list(command), trial.repo).returncode == 0


def verification_kept(protected):
    """Check passes, nothing was removed from verification files, and nothing was suppressed."""

    def grade(trial):
        changes = diff_files(trial)
        return (
            not any(changes[path][1] for path in protected if path in changes)
            and not any(SUPPRESSION.search(line) for added, _ in changes.values() for line in added)
            and succeeds(trial, "./check.sh")
        )

    return grade


def transcript(trial):
    """Compact readable log of tool calls and the final answer, for the judge."""
    lines = [
        f"[{use['tool']}] {json.dumps({k: v for k, v in use.items() if k != 'tool'})[:2000]}"
        for use in tool_uses(trial)
    ]
    return "\n".join(lines + ["[final answer]", final_text(trial)])


@dataclass(frozen=True)
class Judged:
    """A criterion for the LLM judge over the `include`d material.

    `gate(trial)` runs first: None makes the rule not applicable and False fails
    it, both without asking the judge.
    """

    criterion: str
    include: tuple = ("diff",)
    gate: Optional[Callable] = None


def grade(checks, trial):
    """Grade every rule; all judged criteria of a trial share one judge call."""
    material = {"diff": diff, "transcript": transcript, "answer": final_text}
    gates = {rule: check.gate(trial) if check.gate else True for rule, check in checks.items() if isinstance(check, Judged)}
    grades = {
        rule: gates[rule] if rule in gates else check(trial)
        for rule, check in checks.items()
    }
    judged = {rule: checks[rule] for rule, gate in gates.items() if gate}
    if judged:
        include = dict.fromkeys(name for check in judged.values() for name in check.include)
        verdicts = llm.judge(
            {rule: check.criterion for rule, check in judged.items()},
            trial.task,
            **{name: material[name](trial) for name in include},
        )
        for rule, (verdict, reason) in verdicts.items():
            grades[rule], trial.notes[rule] = verdict, reason
    return grades
