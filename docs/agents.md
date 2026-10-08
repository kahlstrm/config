# Coding agents on pannu

## Trust boundary

One dedicated VM separates coding agents from the personal host. Agents inside
it share credentials and workspaces: they are one trust domain, not isolated
from each other. Host-enforced network rules allow public web access and block
private networks by default. Named destination IP/port exceptions allow the
Kubernetes API; they grant connectivity, not credentials. Host access is limited
to DNS forwarding. Exceptions require reviewed host configuration changes and
are listed in the guest's environment manifest.

The guest uses a DNS forwarder on its gateway that follows pannu's current
resolvers, including local hostnames. Resolving a name does not grant access to
the service; destination rules still apply.

T3 is the control interface; Codex, Claude Code, and OpenCode are the harnesses.
Use native subscription sign-ins inside the guest. Personal home directories,
SSH agents, general GitHub credentials, and deployment credentials stay outside.
Nix pins the base environment and T3. On boot, an unprivileged service installs
missing Codex, Claude Code, and OpenCode CLIs into the persistent agent home
using their official installers; failed installations retry automatically.
No SSH is needed for installation. Provider CLIs can update independently through
their native updaters or T3's **Settings → Providers → Update now**. Running
sessions may need to be reopened to use a new version. Provider sign-in is still
an operator action.

## Human access

Use `https://t3.p.kalski.xyz` locally or through MikroTik Back to Home with LAN
access and LAN DNS enabled. The VPN provides connectivity; T3 device pairing
provides authentication. Changes to router WAN forwarding require reviewing
T3 exposure.

`ssh pannu-agents` reaches the guest through pannu without forwarding your SSH
agent. Generate each device's pairing link inside the guest:

```sh
t3 auth pairing create --base-url https://t3.p.kalski.xyz --ttl 5m --label phone
```

Open the one-time link on that device. Authorization persists after the link
expires. Ordinary pairing grants client access, not `access:write`, so these
sessions cannot manage devices in T3's connection settings. Use the guest CLI
to create pairing links or manage sessions with `t3 auth session list` and
`t3 auth session revoke`.

## Separate GitHub identity

The configured machine account owns the forks, including private forks.
Provision forks and private-repository collaborator access outside the
VM: that account's login has broader access than agents should receive.

Agents use two GitHub Apps:

| App | Installation | Permissions |
| --- | --- | --- |
| Fork writer | All repositories owned by the fork account | Contents write |
| PR author | Selected upstream repositories | Contents, Checks, Actions, Commit statuses read; Pull requests write |

Account owners and permitted repositories are configured through
`local.agentGithub`.

Both also require Metadata read. Neither receives upstream Contents write,
Administration, or Workflows permissions. Agents push to forks and file upstream
PRs as the PR App's bot; the operator merges. PR write permits editing and
closing PRs, but merging requires Contents write. These Apps do not create forks.

Encrypt App keys with age for the guest and administrator. Agents can read the
decrypted keys inside the VM; local helpers mint short-lived tokens. The App
installations enforce the permission boundary. Helper repository lists and token
expiry cannot contain an agent that retains an App key; revoke the installation
or rotate its key to withdraw access.

Ordinary `gh`, including T3's GitHub actions, automatically uses App credentials.
After configuring Apps, verify fork push and PR creation succeed while upstream
push and merge fail.
Review upstream CI before allowing fork code to execute with privileged credentials.

## Operating the environment

The guest combines [global coding instructions](../config/AGENTS.md) with
[VM instructions](../modules/agents/instructions.md) for the Git/PR workflow,
tool management, and failure diagnosis. Agents also receive a
deployed-environment manifest and a checkout of this
configuration. The operator reviews, merges, and deploys environment PRs;
agents cannot deploy their own changes.

The operator also provisions Apps, encrypted keys, and provider sign-ins. Treat
persistent guest state and backups as credentials: they include provider
sessions, paired-device state, and the SSH host key that decrypts App secrets.
