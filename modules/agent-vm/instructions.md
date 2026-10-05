# Agent environment

You run as `agent` inside the isolated `agents` VM on pannu. Read
`/etc/agent-environment.json` for the deployed revision, capabilities, and paths.
The manifest's `configuration` identifies the managing Nix flake;
`configCheckout` is its working checkout and `workspaces` is for other projects.
Persistent state lives on guest-owned disks. No host directories or sockets
are shared. Guest root would not grant host administration.

When a missing tool, broken service, or repeatable environment problem obstructs
work, investigate and propose a declarative fix in this repository. Prefer small
changes to `modules/agent-vm`, `modules/agent-github`, or `modules/agent-host`.
Validate with the repository checks. Explain any change to access or isolation.
Use a project's existing development shell (`nix develop`) when available.
Try missing tools temporarily with `nix shell`. After repeated use, propose a
declarative addition: project-specific dependencies belong in the project's
flake or development shell; tools useful across projects belong in the guest
environment. Also propose removing seldom-used tools when temporary or project
shells suffice, after checking service, test, and project dependencies. Keep
persistent tools pinned and update them through reviewed Nix changes.
Public keys are defined in `lib/ssh-keys.nix`; machines and secrets
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

When enabled, Git uses HTTPS with repository-specific App credentials. `origin`
belongs to the manifest's `github.forkOwner`; `upstream` belongs to
`github.upstreamOwner`. Create a branch and
push it to origin. Ordinary `gh` automatically uses App credentials and defaults
to the upstream repository; explicit repository selectors override that default.
Use `gh pr create --head <forkOwner>:<branch>` with the configured fork owner
to propose it upstream.
The upstream App reads contents and CI status and writes PRs; the fork App
writes only fork contents. The App
installations enforce permissions; local helpers are not a security boundary.
Do not attempt to merge or obtain stronger permissions. Follow each project's
instructions, including showing the exact external communication text and
obtaining approval before posting where required.

Public HTTP/HTTPS and DNS to `isolation.dnsServers` in the environment manifest
are allowed. Local names may resolve even when their services are blocked.
The host permits DNS forwarding on the VM gateway using pannu's current
resolvers, blocks other new connections to pannu, and blocks private destinations
and other ports except the named services in `isolation.allowedServices` in the
environment manifest. These exceptions
provide connectivity, not credentials. IPv6 egress is blocked. Request a
declarative, reviewed exception if a task requires more access; do not circumvent
the network policy.

Attempt the requested work normally. If a network operation fails, investigate
the cause and consult the declared restrictions as part of that diagnosis.
Distinguish network restrictions from DNS, service availability, credentials,
and service permissions. If the policy is blocking the task, explain the
destination and port needed and ask the user whether to add a reviewed exception
or choose another approach. Do not repeatedly retry confirmed blocked access.
