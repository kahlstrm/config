# Agent environment

You run as `agent` in a dedicated coding environment. Read
`/etc/agent-environment.json` for the deployed revision, capabilities, and paths.
The manifest's `configuration` identifies the managing Nix flake;
`configCheckout` is its working checkout and `workspaces` is for other projects.
The manifest describes whether this environment is a VM or a dedicated machine.
In the VM, persistent state lives on guest-owned disks; no host directories or
sockets are shared, and guest root does not grant host administration.
In the VM you have passwordless `sudo` for diagnostics and experiments. Make
lasting system changes declaratively; imperative ones are unreviewed and may be
lost on deployment or reboot.

When a missing tool, broken service, or repeatable environment problem obstructs
work, investigate and propose a declarative fix in this repository. Prefer small
changes to `modules/agents` or `modules/agent-github`.
Validate with the repository checks. Explain any change to access or isolation.
Use a project's existing development shell (`nix develop`) when available.
Try missing tools temporarily with `nix shell`. After repeated use, propose a
declarative addition: project-specific dependencies belong in the project's
flake or development shell; tools useful across projects belong in the agent
environment. Also propose removing seldom-used tools when temporary or project
shells suffice, after checking service, test, and project dependencies. Keep
persistent development tools pinned and update them through reviewed Nix changes.
On Linux, a rootless Docker daemon runs as you and `DOCKER_HOST` points at it,
so container-based tests such as Testcontainers work without root.
The coding harnesses are an exception: Codex, Claude Code, and OpenCode are
installed in your writable home by `agent-tools.service` and can use their native
updaters or T3's provider update action. Check `--version` for their current
versions; a Nix rebuild does not upgrade or roll back these binaries.
Public keys are defined in `lib/ssh-keys.nix`; machines and secrets
select which keys they trust.
Do not modify the VM host or introduce personal credentials. An operator reviews
and merges environment changes. When the manifest's `deployment.enabled` is true,
`agent-deploy` requests a detached deployment of the configured environment from
merged upstream `main`. It accepts no commit or target arguments. Inspect
`systemctl status agent-deploy` and
`/nix/var/nix/profiles/agent-deploy/status.json` for progress and failures.
In a VM, kernel, initrd, and boot parameter changes require an operator deployment
of the boot image. The last successful compatible environment is restored on
reboot. On a dedicated machine, deployment updates that machine, including its
boot configuration; the machine must be exclusively for agents.

`agent-store-repair` requests a fixed store verification and repair using the
configured caches. It accepts no arguments and grants no general root access.
Inspect `systemctl status agent-store-repair` and `/var/log/agent-store-repair/repair.log`
for results; uncached missing paths may still require operator recovery.

Shared skills are maintained in `config/agents/skills` and included in the environment
configuration at `/etc/agent-skills`. Boot provisioning links each shared skill
into `~/.agents/skills` for Codex and `~/.claude/skills` for Claude Code.
Additional locally installed skills remain in those directories. Shared skill
changes take effect after deploying the updated environment configuration.

Use native Codex and Claude sign-ins provided by the operator. Their credentials
are shared by this environment's agents, which are one trust domain. Never print,
commit, or copy provider credentials or App private keys into project files.

Check the manifest's `github.enabled` before assuming App credentials exist.
The operator provisions the App and its installation. If access is disabled or
a repository is not installed, report that prerequisite; do not sign into
personal GitHub or copy personal SSH keys into the guest.

When enabled, Git and `gh` use HTTPS with credentials from a single GitHub App
installed on the manifest's `github.owner`. Clone repositories from that owner
directly; `origin` is the repository itself and there are no forks. Push work to
a new branch prefixed `agent/` and open the PR with `gh pr create` in the same
repository. Push to the default branch only when the user explicitly asks;
otherwise never push to it or another existing branch you did not create, and
never force-push shared branches. Private repositories may have no branch
protection, so this rule is the boundary. After pushing, watch the CI checks
(for example `gh pr checks --watch`) and fix failures. The App installation
enforces repository access; local helpers are not a security boundary. Outside
such a request, do not merge; never attempt to obtain stronger permissions.
For dependent changes, open one PR per branch, each based on the branch below
it, and link them as a native GitHub stack with `gh stack link <pr>...`
(bottom to top).

The App cannot open PRs in repositories of owners where it is not installed,
such as an upstream project that `github.owner` has forked. In that case, push
the `agent/` branch to the fork under `github.owner` and give the user a link
that opens GitHub's pull request form with the approved title and description
filled in:
`https://github.com/<owner>/<repo>/compare/<base>...<github.owner>:<fork>:<branch>?expand=1&title=<title>&body=<body>`,
with the title and description URL-encoded. Check that the compare page loads.
If no fork exists, ask the user to create one.

For a VM, public HTTP/HTTPS and DNS to `isolation.dnsServers` in the manifest
are allowed. Local names may resolve even when their services are blocked.
The host permits DNS forwarding on the VM gateway using its current
resolvers, blocks other new connections to the host, and blocks private
destinations and other ports except the named services in `isolation.allowedServices` in the
environment manifest. These exceptions
provide connectivity only; any credentials for them are listed under
`credentials` in the manifest, with their access scope; `kubectl` reads the
Kubernetes kubeconfig through `KUBECONFIG`. IPv6 egress is blocked. Request a
declarative, reviewed exception if a task requires more access; do not circumvent
the network policy.

Attempt the requested work normally. If a network operation fails, investigate
the cause and consult the declared restrictions as part of that diagnosis.
Distinguish network restrictions from DNS, service availability, credentials,
and service permissions. If the policy is blocking the task, explain the
destination and port needed and ask the user whether to add a reviewed exception
or choose another approach. Do not repeatedly retry confirmed blocked access.
