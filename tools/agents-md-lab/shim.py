#!/usr/bin/env python3
"""Stand-in for an external CLI: log the call, answer from canned responses.

Invoked through a symlink named after the tool. `LAB_SHIMS` names a JSON file
mapping tools to `[pattern, stdout, exit code]` rules, matched in order against
the joined arguments; `DEFAULTS` apply when no scenario rule matches. A rule
with a fourth element applies only after an earlier call to the same tool
matched that pattern.
"""

import json
import os
import re
import select
import sys
from pathlib import Path

PULL_REQUEST = '{"number":1,"state":"OPEN","url":"https://github.com/kahlstrm/repo/pull/1"}\n'
DEFAULTS = {
    "gh": [
        [r"^pr create", "https://github.com/kahlstrm/repo/pull/1\n", 0],
        [r"^pr view", PULL_REQUEST, 0, r"^pr create"],
        [r"^pr view", "no pull requests found for branch\n", 1],
        [r"^pr checks", "build\tpass\t1m\thttps://github.com/kahlstrm/repo/actions/runs/1\n", 0],
        [r"^auth status", "github.com\n  ✓ Logged in to github.com as kahlstrm-agents[bot]\n", 0],
    ],
    "agent-deploy": [[r"^$", "Requested deployment of kahlstrm/config main.\n", 0], [r".", "agent-deploy: takes no arguments\n", 2]],
    "agent-store-repair": [[r"^$", "Requested store repair.\n", 0], [r".", "agent-store-repair: takes no arguments\n", 2]],
}


def stdin(arguments):
    """Piped input, read only when the arguments name stdin, as in `--body-file -`."""
    if "-" not in arguments or sys.stdin.isatty() or not select.select([sys.stdin], [], [], 0.2)[0]:
        return ""
    return sys.stdin.read()


def earlier(tool, log, pattern):
    return any(call["tool"] == tool and re.search(pattern, " ".join(call["args"])) for call in log())


def respond(tool, arguments, log):
    configured = json.loads(Path(os.environ["LAB_SHIMS"]).read_text()).get(tool, [])
    joined = " ".join(arguments)
    return next(
        (
            (stdout, code)
            for pattern, stdout, code, *after in configured + DEFAULTS.get(tool, [])
            if re.search(pattern, joined) and (not after or earlier(tool, log, after[0]))
        ),
        ("", 0),
    )


def main():
    tool, arguments = Path(sys.argv[0]).name, sys.argv[1:]
    path = Path(os.environ["LAB_LOG"])
    stdout, code = respond(tool, arguments, lambda: [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else [])
    with path.open("a") as file:
        file.write(json.dumps({"tool": tool, "args": arguments, "cwd": os.getcwd(), "stdin": stdin(arguments)}) + "\n")
    (sys.stdout if code == 0 else sys.stderr).write(stdout)
    sys.exit(code)


if __name__ == "__main__":
    main()
