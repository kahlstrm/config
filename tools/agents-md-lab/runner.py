"""Run one scenario under one prompt variant in an isolated Claude Code or Codex session."""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import graders
import shim

HERE = Path(__file__).parent
# Outside the home directory, so no ancestor AGENTS.md or CLAUDE.md is discovered.
SCRATCH = Path("/tmp")
TIMEOUT = 1200
# Always stand-ins: real ones would reach GitHub or trigger deployments.
SHIMMED = tuple(shim.DEFAULTS)
DROPPED_ENV = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "CLAUDECODE")
HOME = Path.home()
# Hidden from trials: real checkouts, this lab, and other sessions' transcripts.
HIDDEN = [HOME / "config", HOME / "workspaces", HOME / ".t3", HOME / ".cache/agents-md-lab", HOME / ".claude/projects", HOME / ".codex/sessions"]
# Copies of the instructions that agents can read from disk; all show the trial's variant.
INSTRUCTION_FILES = [Path("/etc/agent-instructions.md"), HOME / "AGENTS.md", HOME / ".claude/CLAUDE.md", HOME / ".codex/AGENTS.md", HOME / ".config/opencode/AGENTS.md"]


def sandbox(root: Path, scenario):
    """Environment that keeps trial side effects inside `root`."""
    libexec, bin_dir = root / "libexec", root / "bin"
    libexec.mkdir()
    bin_dir.mkdir()
    script = (HERE / "shim.py").read_text().split("\n", 1)[1]
    (libexec / "shim.py").write_text(f"#!{sys.executable}\n{script}")
    (libexec / "shim.py").chmod(0o755)
    shutil.copy(HERE / "fake_mcp.py", libexec)
    for tool in stand_ins(scenario):
        (bin_dir / tool).symlink_to(libexec / "shim.py")
    (root / "shims.json").write_text(json.dumps(scenario.shims))
    (root / "gh-config").mkdir()
    return {key: value for key, value in os.environ.items() if key not in DROPPED_ENV} | {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "LAB_LOG": str(root / "calls.jsonl"),
        "LAB_SHIMS": str(root / "shims.json"),
        "GH_CONFIG_DIR": str(root / "gh-config"),
        # Drops the system credential helper, so pushes cannot reach GitHub.
        "GIT_CONFIG_NOSYSTEM": "1",
    }


def stand_ins(scenario):
    return {*SHIMMED, *scenario.shims}


def real_binaries(tools):
    return sorted({Path(path).resolve() for tool in tools if (path := shutil.which(tool))})


def mcp_config(root: Path, servers):
    return json.dumps(
        {
            "mcpServers": {
                server: {
                    "command": sys.executable,
                    "args": [str(root / "libexec/fake_mcp.py"), server],
                    "env": {"LAB_LOG": str(root / "calls.jsonl")},
                }
                for server in servers
            }
        }
    )


def isolate(command, root: Path, tools, cwd=None):
    """Wrap `command` in a mount namespace that hides real state and covers real tools.

    The trial sees a private /tmp with only its own root, the trial's variant in
    place of every instruction file, and stand-ins bound over the real binaries
    of `tools`, so absolute paths cannot reach them either.
    """
    instructions = {path.resolve() for path in INSTRUCTION_FILES if path.exists()}
    variant = root / "CLAUDE.md" if (root / "CLAUDE.md").exists() else root / "libexec/empty.md"
    variant.touch()
    return [
        "bwrap",
        "--dev-bind", "/", "/",
        "--tmpfs", "/tmp",
        "--bind", str(root), str(root),
        *(argument for path in HIDDEN if path.exists() for argument in ("--tmpfs", str(path))),
        *(argument for path in instructions for argument in ("--ro-bind", str(variant), str(path))),
        *(argument for path in real_binaries(tools) for argument in ("--ro-bind", str(root / "libexec/shim.py"), str(path))),
        "--die-with-parent",
        "--chdir", str(cwd or root / "repo"),
        "--",
        *command,
    ]


PREFLIGHT = """
set -eu
test "$(cat /etc/agent-instructions.md)" = "preflight variant"
test -z "$(ls -A "$HOME/config")$(ls -A "$HOME/.t3")"
test -z "$(ls /tmp | grep -v "^$(basename "$1")$" || true)"
shift
for tool in "$@"; do "$tool" --version >/dev/null 2>&1 || true; done
"""


def preflight():
    """Fail unless trials are isolated on this machine, before spending on a sweep."""
    from scenarios import Scenario

    with tempfile.TemporaryDirectory(prefix="agents-md-lab-", dir=SCRATCH) as root:
        root = Path(root)
        scenario = Scenario(id="preflight", task="", checks={}, files={"README": "x\n"})
        scenario.setup(root)
        (root / "CLAUDE.md").write_text("preflight variant")
        env = sandbox(root, scenario)
        real_tools = [str(path) for path in real_binaries(SHIMMED)]
        completed = subprocess.run(
            isolate(["bash", "-c", PREFLIGHT, "preflight", str(root), *real_tools], root, SHIMMED),
            env=env, capture_output=True, text=True,
        )
        if completed.returncode:
            raise RuntimeError(f"trial isolation failed: {completed.stderr.strip()}")
        logged = graders.calls(graders.Trial([], root / "repo", root))
        if len(logged) != len(real_tools):
            raise RuntimeError(f"real tools reachable inside trials: {real_tools}")


def claude_command(task, model, budget, mcp):
    return [
        "claude",
        "--print",
        task,
        "--setting-sources",
        "project",
        "--strict-mcp-config",
        *(["--mcp-config", mcp] if mcp else []),
        "--no-session-persistence",
        "--permission-mode",
        "bypassPermissions",
        "--output-format",
        "stream-json",
        "--verbose",
        "--max-budget-usd",
        str(budget),
        *(["--model", model] if model else []),
    ]


def codex_command(task, model, effort, root: Path, mcp):
    """`codex exec` without user config; `isolate` already sandboxes it and binds the variant over ~/.codex/AGENTS.md."""
    servers = [
        setting
        for server in mcp
        for setting in (
            f'mcp_servers.{server}.command="{sys.executable}"',
            f'mcp_servers.{server}.args=["{root}/libexec/fake_mcp.py", "{server}"]',
            f'mcp_servers.{server}.env={{LAB_LOG="{root}/calls.jsonl"}}',
        )
    ]
    return [
        "codex",
        "exec",
        "--json",
        "--ephemeral",
        "--ignore-user-config",
        "--dangerously-bypass-approvals-and-sandbox",
        *(["--model", model] if model else []),
        *(argument for setting in ([f'model_reasoning_effort="{effort}"'] if effort else []) + servers for argument in ("-c", setting)),
        task,
    ]


def unwrap(command):
    """Codex reports shell commands as `bash -lc '<command>'`."""
    words = shlex.split(command)
    return words[2] if len(words) == 3 and words[1] in ("-c", "-lc") else command


def tool_use(name, **arguments):
    return {"type": "tool_use", "name": name, "input": arguments}


def from_codex(events, model):
    """Codex JSONL events in the shape graders read from Claude Code's stream-json."""
    items = [event["item"] for event in events if event.get("type") == "item.completed"]
    uses = [
        use
        for item in items
        for use in {
            "command_execution": lambda: [tool_use("Bash", command=unwrap(item["command"]))],
            "file_change": lambda: [
                tool_use("Write" if change["kind"] == "add" else "Edit", file_path=change["path"]) for change in item["changes"]
            ],
            "mcp_tool_call": lambda: [tool_use(f"mcp__{item['server']}__{item['tool']}", **(item.get("arguments") or {}))],
        }.get(item["type"], list)()
    ]
    messages = [item["text"] for item in items if item["type"] == "agent_message"]
    failure = next(
        ((event.get("error") or {}).get("message") or event.get("message") or "turn failed"
         for event in events if event.get("type") in ("turn.failed", "error")),
        None,
    )
    finished = failure or any(event.get("type") == "turn.completed" for event in events)
    usage = next((event["usage"] for event in events if event.get("type") == "turn.completed"), {})
    return [
        {"type": "system", "model": model},
        *({"type": "assistant", "message": {"content": [use]}} for use in uses),
        *([{"type": "result", "is_error": bool(failure), "result": failure or (messages[-1] if messages else ""), "usage": usage}] if finished else []),
    ]


def parse(stdout):
    return [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]


def first(events, kind):
    return next((event for event in events if event.get("type") == kind), {})


def session_error(events, error):
    """Why the session produced no gradable work, or None when it finished normally."""
    result = first(events, "result")
    if not result:
        return error or "session ended without a result"
    if result.get("is_error"):
        return result.get("result") or result.get("subtype") or "session failed"
    return None


def usage_limited(error):
    return bool(error) and ("hit your" in error and "limit" in error or any(phrase in error.lower() for phrase in ("rate limit", "usage limit")))


def execute(command, repo, env):
    try:
        completed = subprocess.run(
            command, cwd=repo, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=TIMEOUT
        )
        failure = completed.stderr.strip()[-2000:] or f"exit status {completed.returncode}"
        return completed.stdout, failure if completed.returncode else None
    except subprocess.TimeoutExpired as timeout:
        stdout = timeout.stdout or ""
        return stdout.decode() if isinstance(stdout, bytes) else stdout, f"timed out after {TIMEOUT}s"


def run_trial(scenario, variant, instructions, out: Path, model=None, budget=3.0, harness="claude", effort=None):
    out.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="agents-md-lab-", dir=SCRATCH) as root:
        root = Path(root)
        if instructions:
            (root / "CLAUDE.md").write_text(instructions)
        base = scenario.setup(root)
        repo = root / "repo"
        env, tools = sandbox(root, scenario), stand_ins(scenario)
        started = time.monotonic()
        command = (
            codex_command(scenario.task, model, effort, root, scenario.mcp)
            if harness == "codex"
            else claude_command(scenario.task, model, budget, scenario.mcp and mcp_config(root, scenario.mcp))
        )
        stdout, error = execute(isolate(command, root, tools), repo, env)
        seconds = round(time.monotonic() - started)
        (out / "transcript.jsonl").write_text(stdout)
        events = from_codex(parse(stdout), model) if harness == "codex" else parse(stdout)
        trial = graders.Trial(
            events,
            repo,
            root,
            base,
            scenario.task,
            execute=lambda command, cwd: subprocess.run(
                isolate(command, root, tools, cwd), env=env, capture_output=True, text=True, timeout=300
            ),
        )
        trial.final_diff = graders.diff(trial)
        (out / "diff.patch").write_text(trial.final_diff)
        (out / "commits.txt").write_text("\n---\n".join(graders.new_commits(trial)))
        if (root / "calls.jsonl").exists():
            (out / "calls.jsonl").write_text((root / "calls.jsonl").read_text())
        error = session_error(events, error)
        try:
            grades = dict.fromkeys(scenario.rules) if error else scenario.grade(trial)
        except Exception as failure:
            grades, error = dict.fromkeys(scenario.rules), f"grading failed: {failure!r}"
    result = first(events, "result")
    record = {
        "scenario": scenario.id,
        "variant": variant,
        "harness": harness,
        "model": first(events, "system").get("model"),
        "effort": effort,
        "cost": result.get("total_cost_usd"),
        "usage": result.get("usage"),
        "seconds": seconds,
        "grades": grades,
        "notes": trial.notes,
        "error": error,
    }
    (out / "grade.json").write_text(json.dumps(record, indent=2) + "\n")
    return record
