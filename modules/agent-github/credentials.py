"""Mint repository-scoped App tokens without persisting tokens to disk."""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def request_for(config, repository, purpose):
    parts = repository.split("/")
    if len(parts) != 2 or parts[1] not in config["repositories"]:
        raise ValueError("repository is not configured")
    owner, name = parts
    if owner == config["forkOwner"] and purpose == "git":
        app, permissions = "fork", {"contents": "write"}
    elif owner == config["upstreamOwner"] and purpose in ("git", "pr"):
        app, permissions = "upstream", {"contents": "read"}
        if purpose == "pr":
            permissions["pull_requests"] = "write"
    else:
        raise ValueError("owner or credential purpose is not configured")
    return app, {"repositories": [name], "permissions": permissions}


def git_repository(fields):
    if fields.get("protocol") != "https" or fields.get("host") != "github.com":
        raise ValueError("only github.com HTTPS credentials are supported")
    path = fields.get("path", "")
    if not path:
        raise ValueError("Git credential.useHttpPath must be enabled")
    return path.removesuffix(".git")


def encoded(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def mint(config, repository, purpose):
    app_name, body = request_for(config, repository, purpose)
    app = config["apps"][app_name]
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 540, "iss": app["id"]}
    signing_input = b".".join(encoded(json.dumps(value).encode()) for value in [{"alg": "RS256", "typ": "JWT"}, payload])
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", app["keyFile"]],
        input=signing_input, capture_output=True, check=True,
    ).stdout
    jwt = (signing_input + b"." + encoded(signature)).decode()
    request = Request(
        f'https://api.github.com/app/installations/{app["installationId"]}/access_tokens',
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {jwt}", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "kahlstrm-agents", "Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request, timeout=30) as response:
        return json.load(response)["token"]


def main():
    mode, *args = sys.argv[1:]
    config = json.loads(Path("/etc/agent-github.json").read_text())
    if mode == "git":
        if args != ["get"]:
            return 0
        fields = dict(line.rstrip("\n").split("=", 1) for line in sys.stdin if "=" in line)
        try:
            repository = git_repository(fields)
            request_for(config, repository, "git")
        except ValueError:
            return 0
        token = mint(config, repository, "git")
        print(f"username=x-access-token\npassword={token}\n")
        return 0
    if mode == "gh" and len(args) >= 2:
        repository, *command = args
        env = os.environ.copy()
        env.pop("GITHUB_TOKEN", None)
        env["GH_TOKEN"] = mint(config, repository, "pr")
        env["GH_REPO"] = repository
        return subprocess.run(["gh", *command], env=env).returncode
    raise ValueError("usage: gh-agent OWNER/REPO <gh arguments>")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HTTPError as error:
        sys.exit(f"GitHub App token request failed (HTTP {error.code})")
    except (ValueError, KeyError, OSError, URLError, subprocess.CalledProcessError):
        sys.exit("GitHub credentials unavailable; check App configuration, runtime keys, and connectivity")
