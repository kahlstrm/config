"""LLM judge for rules that need reading rather than pattern matching."""

import json
import subprocess
import tempfile

MODEL = "claude-opus-5-5"
VERDICT = {
    "type": "object",
    "properties": {"verdict": {"enum": ["pass", "fail", "n/a"]}, "reason": {"type": "string"}},
    "required": ["verdict", "reason"],
}
VERDICTS = {"pass": True, "fail": False, "n/a": None}
LIMIT = 60_000

PROMPT = """You grade one coding-agent trial against each criterion below, independently. You do
not know which instructions the agent had; judge only the observable work.

For each criterion answer "pass" if the work satisfies it, "fail" if it clearly does not, and
"n/a" if the trial gave no opportunity to apply it. Give a one-sentence reason.

{criteria}

<task>
{task}
</task>

{material}"""


def section(name, text):
    return f"<{name}>\n{text[:LIMIT]}\n</{name}>" if text else ""


def judge(criteria, task, **material):
    """Return {key: (True/False/None, reason)} for criteria {key: text} over named material sections."""
    schema = {"type": "object", "properties": dict.fromkeys(criteria, VERDICT), "required": list(criteria)}
    prompt = PROMPT.format(
        criteria="\n".join(f'Criterion "{key}": {text}' for key, text in criteria.items()),
        task=task,
        material="\n\n".join(section(name, text) for name, text in material.items()),
    )
    with tempfile.TemporaryDirectory(prefix="agents-md-lab-judge-", dir="/tmp") as directory:
        completed = subprocess.run(
            [
                "claude", "--print", prompt,
                "--model", MODEL,
                "--tools", "",
                "--setting-sources", "project",
                "--strict-mcp-config",
                "--no-session-persistence",
                "--output-format", "json",
                "--json-schema", json.dumps(schema),
            ],
            cwd=directory,
            capture_output=True,
            text=True,
            timeout=600,
        )
    if completed.returncode:
        raise RuntimeError(f"judge failed: {completed.stderr.strip() or completed.stdout[-500:]}")
    output = json.loads(completed.stdout)["structured_output"]
    return {key: (VERDICTS[output[key]["verdict"]], output[key]["reason"]) for key in criteria}
