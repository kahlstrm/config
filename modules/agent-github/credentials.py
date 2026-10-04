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
from urllib.parse import urlparse


def request_for(config, repository, purpose):
    if repository is None and purpose == "pr":
        if not config["repositories"]:
            raise ValueError("no repositories are configured")
        return "upstream", {"repositories": config["repositories"], "permissions": pr_permissions()}
    parts = repository.split("/")
    if len(parts) != 2 or parts[1] not in config["repositories"]:
        raise ValueError("repository is not configured")
    owner, name = parts
    if owner == config["forkOwner"] and purpose == "git":
        app, permissions = "fork", {"contents": "write"}
    elif owner == config["upstreamOwner"] and purpose in ("git", "pr"):
        app, permissions = "upstream", {"contents": "read"}
        if purpose == "pr":
            permissions = pr_permissions()
    else:
        raise ValueError("owner or credential purpose is not configured")
    return app, {"repositories": [name], "permissions": permissions}


def pr_permissions():
    return {"contents": "read", "pull_requests": "write", "checks": "read", "actions": "read", "statuses": "read"}


def git_repository(fields):
    if fields.get("protocol") != "https" or fields.get("host") != "github.com":
        raise ValueError("only github.com HTTPS credentials are supported")
    path = fields.get("path", "")
    if not path:
        raise ValueError("Git credential.useHttpPath must be enabled")
    return path.removesuffix(".git")


def encoded(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def app_jwt(app):
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 540, "iss": app["id"]}
    signing_input = b".".join(encoded(json.dumps(value).encode()) for value in [{"alg": "RS256", "typ": "JWT"}, payload])
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", app["keyFile"]],
        input=signing_input, capture_output=True, check=True,
    ).stdout
    return (signing_input + b"." + encoded(signature)).decode()


def github_request(endpoint, token, body=None):
    request = Request(
        f"https://api.github.com/{endpoint}",
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "kahlstrm-agents", "Content-Type": "application/json"},
    )
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def mint(config, repository, purpose):
    app_name, body = request_for(config, repository, purpose)
    app = config["apps"][app_name]
    return github_request(f'app/installations/{app["installationId"]}/access_tokens', app_jwt(app), body)["token"]


def app_login(config, repository, purpose):
    app_name, _ = request_for(config, repository, purpose)
    return github_request("app", app_jwt(config["apps"][app_name]))["slug"] + "[bot]"


def option(args, name, short=None):
    for index, arg in enumerate(args):
        if arg == name or short and arg == short:
            if index + 1 == len(args):
                raise ValueError("missing option value")
            return args[index + 1]
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
        if short and arg.startswith(short) and len(arg) > len(short):
            return arg[len(short):]
    return None


def repository_name(value):
    if value.startswith("https://"):
        parsed = urlparse(value)
        if parsed.netloc != "github.com":
            raise ValueError("only github.com repositories are supported")
        value = parsed.path.strip("/")
    elif value.startswith("git@github.com:"):
        value = value.removeprefix("git@github.com:")
    return value.removesuffix(".git")


def checkout_repository():
    for remote in ["upstream", "origin"]:
        result = subprocess.run(["git", "remote", "get-url", remote], capture_output=True, text=True)
        if result.returncode == 0:
            return repository_name(result.stdout.strip())
    return None


def gh_repository(config, args):
    explicit = option(args, "--repo", "-R")
    if explicit:
        return repository_name(explicit)
    if args[:2] == ["repo", "view"] and len(args) > 2 and not args[2].startswith("-"):
        return repository_name(args[2])
    if args[:1] == ["api"]:
        for arg in args[1:]:
            if arg.startswith("repos/"):
                return "/".join(arg.split("/")[1:3])
    repository = os.environ.get("GH_REPO") or checkout_repository()
    if repository:
        repository = repository_name(repository)
        owner, name = repository.split("/")
        if owner == config["forkOwner"]:
            repository = f'{config["upstreamOwner"]}/{name}'
    return repository


def run_gh(config, executable, args, repository=None):
    if not args or args[0] in ("--version", "version", "--help", "help") or "--help" in args or args[-1:] == ["-h"]:
        return subprocess.run([executable, *args]).returncode
    host = option(args, "--hostname", "-h") or os.environ.get("GH_HOST", "github.com")
    if host != "github.com":
        raise ValueError("only github.com is supported")
    if args[:1] == ["auth"] and args[1:2] not in (["status"], ["token"]):
        raise ValueError("GitHub authentication is managed by Apps")
    repository = repository or gh_repository(config, args)
    purpose = "git" if repository and repository.startswith(config["forkOwner"] + "/") else "pr"
    token = mint(config, repository, purpose)
    if args[:2] == ["auth", "status"]:
        # Installation tokens cannot authenticate /user, which ordinary gh auth status probes.
        github_request("installation/repositories", token)
        login = app_login(config, repository, purpose)
        if option(args, "--json") == "hosts":
            print(json.dumps({"hosts": {"github.com": [{"state": "success", "active": True, "host": "github.com", "login": login, "tokenSource": "GitHub App"}]}}))
        else:
            print(f"github.com: authenticated as {login} (GitHub App installation)")
        return 0
    if args[:2] == ["api", "user"]:
        args = ["api", "users/" + app_login(config, repository, purpose), *args[2:]]
    env = os.environ.copy()
    env.pop("GITHUB_TOKEN", None)
    env["GH_TOKEN"] = token
    env["GH_HOST"] = "github.com"
    if repository:
        env["GH_REPO"] = repository
    return subprocess.run([executable, *args], env=env).returncode


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
    if mode == "gh-auto" and args:
        executable, *command = args
        return run_gh(config, executable, command)
    if mode == "gh" and len(args) >= 3:
        executable, repository, *command = args
        request_for(config, repository, "pr")
        return run_gh(config, executable, command, repository)
    raise ValueError("usage: gh-agent OWNER/REPO <gh arguments>")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HTTPError as error:
        sys.exit(f"GitHub App token request failed (HTTP {error.code})")
    except (ValueError, KeyError, OSError, URLError, subprocess.CalledProcessError):
        sys.exit("GitHub credentials unavailable; check App configuration, runtime keys, and connectivity")
