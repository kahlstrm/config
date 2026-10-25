#!/usr/bin/env python3
"""Stand-in for an external CLI: log the call, answer from canned responses.

Invoked through a symlink named after the tool. `LAB_SHIMS` names a JSON file
mapping tools to `[pattern, stdout, exit code]` rules, matched in order against
the joined arguments; `DEFAULTS` apply when no scenario rule matches.
"""

import json
import os
import re
import select
import sys
from pathlib import Path

DEFAULTS = {
    "gh": [
        [r"^pr create", "https://github.com/kahlstrm/repo/pull/1\n", 0],
        [r"^pr checks", "build\tpass\t1m\thttps://github.com/kahlstrm/repo/actions/runs/1\n", 0],
        [r"^auth status", "github.com\n  ✓ Logged in to github.com as kahlstrm-agents[bot]\n", 0],
    ],
    "agent-deploy": [[r"^$", "Requested deployment of kahlstrm/config main.\n", 0], [r".", "agent-deploy: takes no arguments\n", 2]],
    "agent-store-repair": [[r"^$", "Requested store repair.\n", 0], [r".", "agent-store-repair: takes no arguments\n", 2]],
}


def stdin():
    if sys.stdin.isatty() or not select.select([sys.stdin], [], [], 0.2)[0]:
        return ""
    return sys.stdin.read()


def pull_request_view(log):
    """Like `gh pr view`: the PR exists only once `gh pr create` was called."""
    created = any(call["tool"] == "gh" and call["args"][:2] == ["pr", "create"] for call in log)
    if created:
        return '{"number":1,"state":"OPEN","url":"https://github.com/kahlstrm/repo/pull/1"}\n', 0
    return "no pull requests found for branch\n", 1


def respond(tool, arguments, log):
    configured = json.loads(Path(os.environ["LAB_SHIMS"]).read_text()).get(tool, [])
    joined = " ".join(arguments)
    default = pull_request_view(log) if tool == "gh" and joined.startswith("pr view") else ("", 0)
    return next(
        ((stdout, code) for pattern, stdout, code in configured + DEFAULTS.get(tool, []) if re.search(pattern, joined)),
        default,
    )


def main():
    tool, arguments = Path(sys.argv[0]).name, sys.argv[1:]
    call = {"tool": tool, "args": arguments, "cwd": os.getcwd(), "stdin": stdin()}
    path = Path(os.environ["LAB_LOG"])
    log = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    with path.open("a") as file:
        file.write(json.dumps(call) + "\n")
    stdout, code = respond(tool, arguments, log)
    (sys.stdout if code == 0 else sys.stderr).write(stdout)
    sys.exit(code)


if __name__ == "__main__":
    main()
