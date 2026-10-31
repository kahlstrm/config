#!/usr/bin/env python3
"""Minimal stdio MCP server standing in for an issue tracker or T3; logs every tool call."""

import json
import os
import sys

SERVERS = {
    "linear": {
        "list_teams": ({"type": "object", "properties": {}}, [{"id": "team-1", "key": "LAB", "name": "Lab"}]),
        "list_issue_statuses": (
            {"type": "object", "properties": {"team": {"type": "string"}}, "required": ["team"]},
            [{"name": name, "type": kind} for name, kind in [("Triage", "triage"), ("Backlog", "backlog"), ("Todo", "unstarted"), ("In Progress", "started"), ("Done", "completed")]],
        ),
        "create_issue": (
            {
                "type": "object",
                "properties": {
                    "team": {"type": "string"},
                    "title": {"type": "string"},
                    "description": {"type": "string"},
                    "state": {"type": "string", "description": "Status name; defaults to Triage"},
                    "labels": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["team", "title"],
            },
            {"id": "LAB-42", "url": "https://linear.app/lab/issue/LAB-42"},
        ),
    },
    "t3": {
        "watch_pull_request": (
            {
                "type": "object",
                "properties": {"url": {"type": "string", "description": "Full pull request URL"}},
                "required": ["url"],
            },
            {"watching": True, "note": "This thread wakes when checks or reviews change."},
        ),
    },
}


def reply(request, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()


def main():
    server = sys.argv[1]
    tools = SERVERS[server]
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if "id" not in request:
            continue
        if method == "initialize":
            reply(request, {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": server, "version": "1"}})
        elif method == "tools/list":
            reply(request, {"tools": [{"name": name, "description": f"{server} {name.replace('_', ' ')}", "inputSchema": schema} for name, (schema, _) in tools.items()]})
        elif method == "tools/call":
            name, arguments = request["params"]["name"], request["params"].get("arguments", {})
            with open(os.environ["LAB_LOG"], "a") as log:
                log.write(json.dumps({"tool": server, "args": [name], "input": arguments}) + "\n")
            reply(request, {"content": [{"type": "text", "text": json.dumps(tools[name][1])}]})
        else:
            reply(request, {})


if __name__ == "__main__":
    main()
