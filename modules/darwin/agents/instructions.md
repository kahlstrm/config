# Agent environment (macOS host)

You run as the user in the manifest, on a Mac, usually started by T3 Code. Read
`/etc/agent-environment.json` for the deployed revision, paths, ports, logs, and
what `sudo` allows. Sections missing from the manifest are not set up on this
host.

There is no isolation: you share the user's account, including their files,
`~/.ssh`, browser data, and login keychain. Agents in T3 are one trust domain
with them. Never print, commit, or copy credentials (keychain items, tokens,
keys, provider sign-ins) into projects or messages, and don't read the user's
personal data unless the task needs it.

## The environment is a Nix flake

The machine is configured by the nix-darwin flake in the manifest's
`configuration.checkout`. When a missing tool, broken service, or repeatable
environment problem obstructs work, investigate and propose a declarative fix
there. Use a project's development shell (`nix develop`) when available, and try
missing tools temporarily with `nix shell nixpkgs#<tool>`. Don't install tools
with `brew` or by hand when Nix can provide them.

The coding harnesses are an exception: Claude Code, Codex, and OpenCode live in
`~/.local/bin` and `~/.opencode/bin`, installed and updated by T3 (**Settings →
Providers**) or their native updaters. A Nix deploy does not upgrade or roll
them back.

## Models

If the manifest has an `opper` section, T3 runs Claude Code in two
configurations: `~/.claude` (the user's own sign-in) and `opper.claudeConfig`
(models through Opper, billed per token; `claude-opper` in a terminal). Opper
model IDs name a specific route (`host/model`); don't switch Opper sessions to
other routes or providers without the user's consent.

## Deploying

If the manifest has a `configuration` section, `sudo darwin-deploy` builds the
committed HEAD of the checkout, pushes it, and activates it through the launchd
job `org.nixos.darwin-deploy`. It refuses to run with uncommitted changes;
`sudo darwin-deploy --rollback` returns to the previous generation.

Deploy only when the user asks for it. A deploy that changes T3's configuration
restarts T3 and ends your session, but the deploy itself finishes. So commit,
say what will change, then deploy last. After reconnecting, check the outcome
with `t3-doctor` or the manifest's deploy log.

## Permissions

Passwordless `sudo` covers only the commands listed in the manifest's `sudo`.
Everything else needs the user's password: don't try to obtain it or work around
it; ask the user to run the command. Never reboot or shut down: with FileVault,
the Mac stays offline after a restart until someone enters the password.

Don't change system settings (power, sleep, firewall, sharing, Tailscale)
outside the flake.

## Debugging

- Health of the setup: `t3-doctor` (read-only; exits non-zero on `FAIL`).
- Logs: see the manifest's `logs`.
- File system, network, and exec syscalls of one of the user's processes:
  `sudo trace-process [-f filesys|network|exec|…] [-t seconds] <pid>` (wraps
  `fs_usage`). dtrace/dtruss don't work: SIP blocks syscall tracing.
- Stack samples without `sudo`: `sample <pid> 5`.
- Developer Mode is on: `lldb -p <pid>` works on the user's processes without
  `sudo`.
- `launchctl kickstart -k gui/$(id -u)/org.nixos.t3` restarts T3, which ends
  your own session.

## Previews

To let the user preview a dev server, listen on `localhost` on one of the
manifest's `t3.previewPorts`. They open `https://<preview service>.<tailnet>:<port>`
(the manifest's `t3.previewService` without `svc:`); get `<tailnet>` with
`tailscale status --json | jq -r .MagicDNSSuffix`. Only tailnet devices can
reach it. Always use that address, never `localhost`, when sharing a preview or
opening one in T3's preview panel or preview tools: those run on the user's
device, where `localhost` is not this Mac. If a project needs another port, it
must be added to the flake's preview ports and to the preview Service and its
grant in the Tailscale admin console; propose that to the user.

Don't bind dev servers to `0.0.0.0` unless asked: that also exposes them on the
local network.

## Network

There are no network restrictions: the internet and the local network are
reachable. Don't scan or connect to other devices on the local network or
tailnet unless the task requires it.
