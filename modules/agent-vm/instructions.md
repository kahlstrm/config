# Agent environment

You run as `agent` inside the isolated `agents` VM on pannu. Read
`/etc/agent-environment.json` for the deployed revision, capabilities, and paths.
The guest is managed by the `kahlstrm/config` Nix flake. `/home/agent/config`
is its working checkout; other projects belong in `/home/agent/workspaces`.
Persistent state lives on guest-owned disks. No host directories or sockets
are shared. Guest root would not grant host administration.

When a missing tool, broken service, or repeatable environment problem obstructs
work, investigate and propose a declarative fix in this repository. Prefer small
changes to `modules/agent-vm`, `modules/agent-github`, or `modules/agent-host`.
Validate with the repository checks. Explain any change to access or isolation.
Tools are pinned in Nix; propose version updates here rather than using tool
updaters. Public keys are defined in `lib/ssh-keys.nix`; machines and secrets
select which keys they trust.
Do not switch pannu, deploy, modify the host, or introduce personal credentials.
An operator reviews, merges, and deploys environment changes.

Use native Codex and Claude sign-ins provided by the operator. Their credentials
are shared by this VM's agents, which are one trust domain. Never print, commit,
or copy provider credentials or App private keys into project files.

Check the manifest's `github.enabled` before assuming App credentials exist.
The operator provisions Apps, keys, and forks. If access is disabled or a fork
is missing, report that prerequisite; do not sign into personal GitHub or copy
personal SSH keys into the guest.

When enabled, Git uses HTTPS with repository-specific App credentials. `origin` is
`kahlstrm-agents/<repo>`; `upstream` is `kahlstrm/<repo>`. Create a branch and
push it to origin. Ordinary `gh` automatically uses App credentials and defaults
to the upstream repository; explicit repository selectors override that default.
Use `gh pr create --head kahlstrm-agents:<branch>` to propose it upstream.
The upstream App reads contents
and CI status and writes PRs; the fork App writes only fork contents. The App
installations enforce permissions; local helpers are not a security boundary.
Do not attempt to merge or obtain stronger permissions. Follow each project's
instructions, including showing the exact external communication text and
obtaining approval before posting where required.

Public HTTP/HTTPS and Quad9 DNS are allowed. New connections to pannu, private
LAN addresses, tailnet addresses, and arbitrary outbound ports are blocked by
the host. IPv6 egress is blocked. Request a declarative, reviewed exception if
a task requires more access; do not circumvent the network policy.
