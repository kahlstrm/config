# Coding agents on a Mac

`modules/darwin/agents` turns a Mac into an always-on host for T3 Code and its
harnesses. It is the lightweight counterpart of the [pannu VM](agents.md): no
isolation, the agents run as the Mac's user. Import it from a machine
configuration and enable the parts you need under `local.agentHost`;
`tests/agent-host-example.nix` enables all of them and is evaluated in CI.

| Option | Provides |
| --- | --- |
| `alwaysOn.enable` | Never sleep; restart after a power failure or freeze |
| `t3.enable` | T3 as a login agent on `127.0.0.1`, Tailscale Services for T3 and dev server previews, `t3-pair` |
| `deploy.enable` | `darwin-deploy`, scoped passwordless `sudo`, `trace-process`, Developer Mode |
| `opper.enable` | Claude Code and OpenCode through [Opper](https://opper.ai) next to the default sign-in |
| `doctor.enable` | `t3-doctor`, run after every login and daily |
| `instructions.enable` | `config/AGENTS.md` plus a host section for every harness, and `/etc/agent-environment.json` |

## Trust boundary

There is none between the agents and the user: T3 and every harness run as
`system.primaryUser` and can read the user's files, `~/.ssh`, browser data and
login keychain. Passwordless `sudo` is limited to `darwin-deploy`, a bare
`tailscale up` and `trace-process`; anyone who can commit to the checkout can
deploy it as root, so in practice agents can obtain root, and every root change
is a pushed commit. Use the pannu VM for work that needs a boundary.

## T3 and remote access

T3 starts when the user logs in, so with FileVault a restart waits at the unlock
screen until someone enters the password; `sudo fdesetup authrestart` skips that
once. It listens on loopback and is published on the tailnet as Tailscale
Services: `https://<t3.serviceName>.<tailnet>.ts.net` for T3 and
`https://<t3.previewServiceName>.<tailnet>.ts.net:<port>` for each of
`t3.previewPorts`. Service configuration has no node name in it, so renaming the
machine doesn't break it.

Services need, in the Tailscale admin console:

- The Mac tagged (Services can't be hosted by user-owned devices), with key
  expiry disabled.
- The services defined with their ports (`tcp:443`, and `tcp:<port>` for each
  preview port).
- In the policy file, an owner for the tag, auto-approval and access grants:

  ```jsonc
  "tagOwners": { "tag:agent-host": ["autogroup:admin"] },
  "autoApprovers": { "services": {
    "svc:t3": ["tag:agent-host"], "svc:preview": ["tag:agent-host"] } },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["svc:t3"], "ip": ["443"] },
    { "src": ["autogroup:member"], "dst": ["svc:preview"], "ip": ["3000", "5173"] },
  ],
  ```

`t3-pair <device>` prints a one-time pairing link as a QR code, with a short
code to type instead. T3 sessions last a fixed 30 days and aren't renewed by
use; `t3-doctor` warns a week before one expires.

Previews must use the tailnet address: the desktop app's preview panel and its
agent preview tools run on the client device, where `localhost` is not the Mac.
The host instructions tell agents so.

`t3.settings` is deep-merged into `~/.t3/userdata/settings.json` on every
switch, and T3 reloads the file; keys not declared keep their UI values. Secrets
for T3 and the harnesses come from the login keychain through
`t3.keychainEnvironment`, never from the store.

Harness CLIs are not managed by Nix: T3 installs and updates Claude Code and
Codex itself, and OpenCode uses its own installer.

## Deploying

`sudo darwin-deploy` builds the committed HEAD of `deploy.repository` as the
user and pushes it, both in the caller's session (git needs the user's
keychain), then hands switching and activation to the launchd job
`org.nixos.darwin-deploy` and follows its log. An agent in T3 can deploy a change
that restarts T3: the restart ends the agent's session, but the job finishes;
`t3-doctor` reports the outcome afterwards. The job's plist points at
`/run/current-system`, so a deploy never reloads the job running it.

`deploy.variants` names extra configurations (`<configuration>-<variant>`) that
`darwin-deploy --variant` may switch to, for testing switches end to end.

## Opper

The `~/.claude-opper` Claude Code configuration talks to Opper's
Anthropic-compatible endpoint and reads the key from the keychain with
`apiKeyHelper`; `claude-opper` starts it in a terminal and `opper.t3Instance`
adds it to T3 as a second Claude instance, next to the default one. Claude Code's
opus, sonnet and haiku slots map to `opper.claudeModels`. It doesn't know these
models' context windows, so `opper.maxContextTokens` must be the smallest one.
OpenCode gets the provider through `OPENCODE_CONFIG`, which it merges over the
user's own `opencode.json`.

Opper model IDs name a route (`host/model`), and the host decides where
inference runs; the list of EU routes is <https://opper.ai/models/eu>. Enforce
it in Opper with a Model access allowlist (inference and storage location EU)
for the organization or project; `t3-doctor` checks that every configured model
is an allowed EU route and warns while non-EU routes are still allowed.

## Debugging

- `t3-doctor` checks Nix, power settings, sleep since the previous run, T3,
  Tailscale Services, harness installs, Opper routes, the last deploy and
  whether the running commit is on `origin/main`.
- `sudo trace-process [-f <mode>] [-t <seconds>] <pid>` runs `fs_usage` on one
  of the user's processes. dtrace and dtruss can't trace syscalls while SIP is
  on, even as root.
- Developer Mode lets `lldb` and `sample` attach to the user's processes
  without `sudo`.

## Caveats

- nix-darwin removes user agents with a bare `launchctl unload`, which from a
  system job targets the wrong domain; the deploy job therefore activates
  through `launchctl asuser`.
- macOS `sudo` doesn't match a rule written for a store path when the command
  is run through its `/run/current-system` symlink; the rules list both.
