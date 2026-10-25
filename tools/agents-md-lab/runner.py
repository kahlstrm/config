"""Run one scenario under one prompt variant in an isolated Claude Code session."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import graders

HERE = Path(__file__).parent
# Outside the home directory, so no ancestor AGENTS.md or CLAUDE.md is discovered.
SCRATCH = Path("/tmp")
TIMEOUT = 1200
# Always stand-ins: real ones would reach GitHub or trigger deployments.
SHIMMED = ("gh", "agent-deploy", "agent-store-repair")
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
    for helper in ("shim.py", "fake_mcp.py"):
        script = (HERE / helper).read_text().split("\n", 1)[1]
        (libexec / helper).write_text(f"#!{sys.executable}\n{script}")
        (libexec / helper).chmod(0o755)
    for tool in {*SHIMMED, *scenario.shims}:
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


def isolate(command, root: Path):
    """Wrap `command` in a mount namespace that hides real state and covers real tools.

    The trial sees a private /tmp with only its own root, the trial's variant in
    place of every instruction file, and stand-ins bound over the real binaries
    of `SHIMMED` tools, so absolute paths cannot reach them either.
    """
    real_tools = {Path(path).resolve() for tool in SHIMMED if (path := shutil.which(tool))}
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
        *(argument for path in real_tools for argument in ("--ro-bind", str(root / "libexec/shim.py"), str(path))),
        "--die-with-parent",
        "--chdir", str(root / "repo"),
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
        Scenario(id="preflight", rules=(), task="", check=dict, files={"README": "x\n"}).setup(root)
        (root / "CLAUDE.md").write_text("preflight variant")
        env = sandbox(root, Scenario(id="preflight", rules=(), task="", check=dict))
        real_tools = [str(Path(path).resolve()) for tool in SHIMMED if (path := shutil.which(tool))]
        completed = subprocess.run(
            isolate(["bash", "-c", PREFLIGHT, "preflight", str(root), *real_tools], root),
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


def parse(stdout):
    return [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]


def first(events, kind):
    return next((event for event in events if event.get("type") == kind), {})


def execute(command, repo, env):
    try:
        completed = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=TIMEOUT)
        return completed.stdout, completed.stderr.strip()[-2000:] if completed.returncode else None
    except subprocess.TimeoutExpired as timeout:
        stdout = timeout.stdout or ""
        return stdout.decode() if isinstance(stdout, bytes) else stdout, f"timed out after {TIMEOUT}s"


def run_trial(scenario, variant, instructions, out: Path, model=None, budget=3.0):
    out.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="agents-md-lab-", dir=SCRATCH) as root:
        root = Path(root)
        if instructions:
            (root / "CLAUDE.md").write_text(instructions)
        base = scenario.setup(root)
        repo = root / "repo"
        env = sandbox(root, scenario)
        started = time.monotonic()
        stdout, error = execute(
            isolate(claude_command(scenario.task, model, budget, scenario.mcp and mcp_config(root, scenario.mcp)), root),
            repo,
            env,
        )
        seconds = round(time.monotonic() - started)
        (out / "transcript.jsonl").write_text(stdout)
        events = parse(stdout)
        trial = graders.Trial(events, repo, root, base, scenario.task)
        (out / "diff.patch").write_text(graders.diff(trial))
        if (root / "calls.jsonl").exists():
            (out / "calls.jsonl").write_text((root / "calls.jsonl").read_text())
        try:
            grades = {rule: grade for rule, grade in scenario.grade(trial).items() if rule in scenario.rules}
        except Exception as failure:
            grades, error = dict.fromkeys(scenario.rules), error or f"grading failed: {failure!r}"
    result = first(events, "result")
    record = {
        "scenario": scenario.id,
        "variant": variant,
        "model": first(events, "system").get("model"),
        "cost": result.get("total_cost_usd"),
        "seconds": seconds,
        "grades": grades,
        "notes": trial.notes,
        "error": error,
    }
    (out / "grade.json").write_text(json.dumps(record, indent=2) + "\n")
    return record
