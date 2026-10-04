# Coding agents on pannu

Pannu runs a dedicated NixOS QEMU/KVM guest named `agents`. T3 Code runs as the
unprivileged `agent` user with native Codex, Claude Code, and OpenCode tools.
Everything is pinned by the root flake; updates are reviewed Nix changes.
The guest does not use the personal machine configuration or home-manager profile.

## Boundaries and state

`modules/agent-host` manages the VM, resource limits, LAN HTTPS proxy, and
host-enforced network rules. `modules/agent-vm` manages the user, tools, T3 service,
and environment instructions. `modules/agent-github` manages local App token
minting and credential selection. `machines/pannu.nix` enables the environment.

The default allocation is 4 vCPUs and 8 GiB RAM, with a 10 GiB host process memory
limit. Guest disks under `/var/lib/microvms/agents` provide 40 GiB for `/home`,
8 GiB for `/var`, and 16 GiB for the writable Nix store/database. The base system
is a separate immutable guest store disk. No host filesystem, Nix daemon socket,
Docker socket, personal SSH agent, or host administration credential is shared.
Guest root does not authorize host deployment. Agents within this VM share one
trust domain, provider sign-ins, workspaces, and GitHub App keys.

The host allows guest connections to public IPv4 TCP 80/443 and Quad9 DNS on
9.9.9.9 or 149.112.112.112. It drops private, tailnet, loopback, link-local,
multicast, and reserved destinations, IPv6, and spoofed source addresses. New
guest connections to the host are dropped; replies to host-initiated SSH and
reverse-proxy connections are allowed. This is a network boundary, not a domain
allowlist: public web services remain reachable. Add reviewed policy exceptions
when a project needs another destination or port.

Back up the guest disks while `microvm@agents` is stopped. They contain provider
sessions, T3 state, projects, and the guest SSH host key; protect backups as
credentials. Removing a project checkout does not erase its T3 history.

## Connect

Use `https://t3.p.kalski.xyz` on the LAN. The existing LAN DNS maps pannu's
subdomains to `10.1.1.10`; nginx uses the existing wildcard certificate and
proxies only T3 HTTP/WebSocket traffic into the isolated guest. Generate a
short-lived pairing link inside the guest:

```sh
t3 auth pairing create --base-url https://t3.p.kalski.xyz --ttl 5m --label browser
```

Remote access uses the router's MikroTik Back to Home WireGuard connection,
with LAN access enabled and access to the LAN DNS. The same URL works locally
and through the VPN. T3 device pairing authenticates browsers and phones;
nginx does not duplicate the VPN policy with a client-subnet allowlist.
The proxy uses pannu's existing HTTPS listener. Keep unsolicited WAN forwarding
blocked at the router; this configuration adds no WAN port forwarding. Review
T3 exposure when changing router forwards or access to pannu's HTTPS listener.
The guest has no tailnet membership or tailnet browser route.

For administration, the home-manager SSH alias `pannu-agents` uses pannu as a jump host to
`agent@10.83.0.2`. SSH agent forwarding is disabled. The administrator public
key configured in `local.agentHost.authorizedKeys` must match your client key.
Record and verify the guest host key through pannu on first connection.

```sh
ssh pannu-agents
ssh -N -L 3773:10.83.0.2:3773 pannu
```

SSH forwarding is also available as a fallback. For the tunnel, generate a
short-lived browser link inside the guest:

```sh
t3 auth pairing create --base-url http://127.0.0.1:3773 --ttl 5m --label laptop
```

Open the printed pairing URL on the device running the tunnel. Treat pairing
links as passwords. Revoke lost devices using T3 Settings → Connections or
`t3 auth session --help`. Desktop T3 can also use the `pannu-agents` SSH alias.
T3 and provider versions must be compatible with the connecting client.


## Provider sign-ins

Authenticate as `agent` inside the guest, using your personal subscriptions.
For Codex, `codex login --device-auth` avoids a remote localhost callback.
Start `claude` and follow its sign-in flow. Configure OpenCode providers only
when needed. Keep these sign-ins in the guest; do not copy your personal home
directory, SSH keys, or general GitHub login into it. API accounts can be
configured separately when subscription access does not suit a provider.

T3 runs as the system service `t3code`, using `/home/agent` and its persistent
`~/.t3` state. Do not install a second service using `t3 service install`.

## GitHub identity and permissions

Create the personal machine account `kahlstrm-agents` outside the guest. Use it
to create the forks; for private originals, provision the required collaborator
access and fork from that account outside the guest. Keep its account login,
SSH keys, and personal access tokens outside the VM. That account's private
repository collaborator access is broader than the runtime App permissions.

Register two Apps, with no webhooks required:

| App | Installation | Repository permissions |
| --- | --- | --- |
| Fork writer (for example `kahlstrm-agents-forks`) | All repositories under `kahlstrm-agents` | Contents write; mandatory Metadata read |
| PR author (ideally `kahlstrm-agents`) | Selected originals under `kahlstrm` | Contents read; Pull requests write; mandatory Metadata read |

Do not grant Administration, Workflows, or upstream Contents write. The fork
writer must allow installation on another account if registered under your main
account. Public App distribution does not publish its private key or repositories.
PRs are authored by the PR App's bot identity; fork pushes use the fork writer.
The runtime Apps do not provision forks and cannot merge upstream PRs without
upstream Contents write. PR write still allows edits and closures of PRs on
selected originals. Review upstream CI permissions and workflows, particularly
any `pull_request_target` workflow that executes fork code with credentials.

Download each App's PEM and record its App ID and installation ID on your trusted
machine. Obtain the guest host public key through pannu (`ssh-keyscan -t ed25519
10.83.0.2` from pannu), verify it, and add it plus the administrator key as age
recipients in `secrets/secrets.nix`. Encrypt the PEMs as
`secrets/agent-fork-app.age` and `secrets/agent-pr-app.age`. Commit ciphertext only.
Declare the runtime secrets and App identifiers in pannu's guest settings:

```nix
local.agentHost.guestModule = { config, ... }: {
  age.secrets.agent-fork-app = {
    file = ../secrets/agent-fork-app.age;
    owner = "agent";
    mode = "0400";
  };
  age.secrets.agent-pr-app = {
    file = ../secrets/agent-pr-app.age;
    owner = "agent";
    mode = "0400";
  };
  local.agentGithub = {
    enable = true;
    repositories = [ "config" ];
    apps.fork = {
      id = "FORK_APP_ID";
      installationId = "FORK_INSTALLATION_ID";
      keyFile = config.age.secrets.agent-fork-app.path;
    };
    apps.upstream = {
      id = "PR_APP_ID";
      installationId = "PR_INSTALLATION_ID";
      keyFile = config.age.secrets.agent-pr-app.path;
    };
  };
};
```

The helper mints repository-scoped installation tokens on demand and does not
save tokens to disk. Git selects the App using the HTTPS owner/repository path;
`gh-agent kahlstrm/config <gh arguments>` selects the PR App. The private keys
are readable by guest agents: the helpers and repository list are conveniences,
while the actual maximum permissions come from the two App installations.
Short token lifetimes do not contain an agent that retains an App key. Revoke
the installation or rotate the App key to revoke that access.

Use `gh-agent` for authenticated PR commands. T3's generic GitHub sign-in and
buttons that invoke plain `gh` do not select these App credentials; do not
authenticate them with your personal GitHub account inside the guest.

The initial configuration leaves GitHub credentials disabled until the Apps and
encrypted keys exist. It can still clone a public configuration repository.

## Agent workflow

The guest initializes `/home/agent/config` from the original repository, with
`upstream` pointing to `kahlstrm/config` and `origin` to `kahlstrm-agents/config`.
Other projects belong under `/home/agent/workspaces` with the same remote scheme.
Agents read the deployed manifest at `/etc/agent-environment.json` and shared
instructions at `/etc/agent-instructions.md`. Codex, Claude, and OpenCode receive
these as global instructions. Repository instructions also apply.

```sh
git switch -c fix/agent-environment
# Make and validate a small declarative change.
git push -u origin HEAD
gh-agent kahlstrm/config pr create --head kahlstrm-agents:fix/agent-environment
```

Present the exact PR text and get approval before posting where project
instructions require it. The operator reviews, merges, and deploys; agents can
propose fixes to their own environment but cannot switch pannu.

Before relying on credentials, use a disposable private repository/fork to
verify clone, fork push, and PR creation succeed, and original push and PR merge
fail. The local tests verify token scoping; GitHub enforces the installed App
permissions, which must also be checked after registration.

## Checks, updates, and operations

From `~/config`, build and test without deployment:

```sh
nix build .#checks.x86_64-linux.agent-credentials .#checks.x86_64-linux.agent-network .#checks.x86_64-linux.agent-guest --no-link
nix build .#nixosConfigurations.pannu.config.microvm.vms.agents.config.config.microvm.declaredRunner --no-link
make build-pannu
```

The `Agent environment` CI workflow runs credential tests and a NixOS network
test covering public web access, reverse-proxy replies, host/private/tailnet
blocking, source spoofing, IPv6, unsolicited ingress, and firewall reloads.
It also boots a guest to check T3, the native tools, and shared instructions.
Use `path:.` as the flake reference when checking newly added untracked files.

Update tooling through `nix flake update nixpkgs-unstable-nixos`, review package
versions and the effects on pannu, build, and run the checks. Merge and schedule
deployment when active sessions can be interrupted. `t3 update` and automatic
native tool updates do not update the pinned Nix packages.

Deploy pannu using `make deploy-pannu` after review.
On pannu, inspect `systemctl status microvm@agents agent-network` and
`journalctl -u microvm@agents`. Restart the guest with `sudo systemctl restart
microvm@agents`; this interrupts active agent sessions. Operator guest service
inspection can use `ssh pannu-agents systemctl status t3code`.

**TL;DR:** One declarative VM isolates the agents, while separate GitHub Apps
permit fork pushes and upstream PRs; account/App provisioning and provider
sign-ins stay explicit operator tasks.
