#!/usr/bin/env python3
"""Check the factual claims in the VM instructions against the running environment."""

import getpass
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

MANIFEST = Path("/etc/agent-environment.json")
HOME = Path.home()


@dataclass(frozen=True)
class Claim:
    rule: str
    statement: str
    check: Callable[[], bool]


def manifest():
    return json.loads(MANIFEST.read_text())


def succeeds(*command, timeout=20, env=None):
    try:
        return subprocess.run(command, capture_output=True, timeout=timeout, env=env).returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def output(*command, timeout=20):
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout).stdout


def reachable(url, *flags):
    return succeeds("curl", "--silent", "--output", "/dev/null", "--max-time", "8", *flags, url, timeout=15)


def in_home(tool):
    path = shutil.which(tool)
    return bool(path) and Path(path).resolve().is_relative_to(HOME)


def skill_links(directory):
    shared = {path.name for path in Path("/etc/agent-skills").iterdir()}
    linked = {path.name for path in (HOME / directory).iterdir() if path.resolve().is_relative_to("/etc/agent-skills") or path.resolve().is_relative_to("/nix/store")}
    return bool(shared) and shared <= linked


CLAIMS = [
    Claim("vm-manifest", "runs as `agent`", lambda: getpass.getuser() == "agent"),
    Claim(
        "vm-manifest",
        "manifest names configuration, configCheckout, workspaces, and VM or machine mode",
        lambda: {"configuration", "configCheckout", "workspaces"} <= manifest().keys()
        and manifest()["isolation"]["mode"] in {"VM", "machine", "dedicated"},
    ),
    Claim("vm-manifest", "configCheckout is a checkout of the configuration", lambda: f"{manifest()['configuration']}" in output("git", "-C", manifest()["configCheckout"], "remote", "get-url", "origin")),
    Claim("vm-guest-state", "manifest lists no host shares", lambda: manifest()["isolation"]["hostShares"] == []),
    Claim("vm-guest-state", "no 9p or virtiofs mounts", lambda: output("findmnt", "-t", "9p,virtiofs", "-no", "TARGET").strip() == ""),
    Claim("vm-sudo", "sudo works without a password", lambda: succeeds("sudo", "-n", "true")),
    Claim("vm-docker", "DOCKER_HOST points at a rootless daemon owned by the agent", lambda: "rootless" in output("docker", "info", "--format", "{{json .SecurityOptions}}") and str(os.getuid()) in os.environ.get("DOCKER_HOST", "")),
    Claim("vm-harness-updates", "claude, codex and opencode run from the agent's home", lambda: all(in_home(tool) and succeeds(tool, "--version") for tool in ("claude", "codex", "opencode"))),
    Claim("vm-harness-updates", "agent-tools.service exists", lambda: succeeds("systemctl", "cat", "agent-tools.service")),
    Claim("vm-ssh-keys", "lib/ssh-keys.nix exists in the configuration", lambda: (Path(manifest()["configCheckout"]) / "lib/ssh-keys.nix").is_file()),
    Claim("vm-deploy", "agent-deploy exists and deployment is declared in the manifest", lambda: shutil.which("agent-deploy") is not None and "enabled" in manifest()["deployment"]),
    Claim("vm-deploy", "agent-deploy status file and unit exist", lambda: Path("/nix/var/nix/profiles/agent-deploy/status.json").exists() and succeeds("systemctl", "cat", "agent-deploy.service")),
    Claim("vm-boot-deployment", "manifest declares the boot mode", lambda: "bootMode" in manifest()["deployment"]),
    Claim("vm-store-repair", "agent-store-repair exists with its unit and log directory", lambda: shutil.which("agent-store-repair") is not None and succeeds("systemctl", "cat", "agent-store-repair.service") and Path("/var/log/agent-store-repair").is_dir()),
    Claim("vm-skills", "shared skills are linked for Claude Code", lambda: skill_links(".claude/skills")),
    Claim("vm-skills", "shared skills are linked for Codex", lambda: skill_links(".agents/skills")),
    Claim("vm-skills", "/etc/agent-skills matches config/agents/skills", lambda: {p.name for p in Path("/etc/agent-skills").iterdir()} == {p.name for p in (Path(manifest()["configCheckout"]) / "config/agents/skills").iterdir()}),
    Claim("vm-github-https", "git uses a credential helper for HTTPS", lambda: bool(output("git", "config", "--get", "credential.helper").strip())),
    Claim("vm-github-https", "gh reaches the owner's repositories", lambda: succeeds("gh", "api", f"repos/{manifest()['github']['owner']}/{manifest()['configuration'].split('/')[1]}")),
    Claim("vm-network-facts", "public HTTPS is allowed", lambda: reachable("https://example.com")),
    Claim("vm-network-facts", "IPv6 egress is blocked", lambda: not reachable("https://example.com", "-6")),
    Claim("vm-network-facts", "private destinations are blocked", lambda: not reachable("http://192.168.1.1/") and not reachable("http://10.0.0.1/")),
    Claim(
        "vm-network-facts",
        "allowed services are reachable on their declared ports",
        lambda: all(
            succeeds("bash", "-c", f"exec 3<>/dev/tcp/{service['address']}/{port}", timeout=8)
            for service in manifest()["isolation"]["allowedServices"].values()
            for port in service["tcpPorts"]
        ),
    ),
    Claim("vm-network-facts", "KUBECONFIG is set and readable", lambda: Path(os.environ.get("KUBECONFIG", "/nonexistent")).is_file()),
]


def evaluate(claim):
    try:
        return "pass" if claim.check() else "FAIL"
    except Exception as failure:
        return f"error: {failure!r}"[:120]


def main():
    results = [(claim, evaluate(claim)) for claim in CLAIMS]
    print("| Rule | Claim | Result |\n| --- | --- | --- |")
    for claim, result in results:
        print(f"| {claim.rule} | {claim.statement} | {result} |")
    sys.exit(any(result != "pass" for _, result in results))


if __name__ == "__main__":
    main()
