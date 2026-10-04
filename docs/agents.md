# Coding agents on pannu

## Trust boundary

One dedicated VM separates coding agents from the personal host. Agents inside
it share credentials and workspaces: they are one trust domain, not isolated
from each other. Host-enforced network rules allow public web access and block
private networks by default. Named destination IP/port exceptions allow the
Kubernetes API; they grant connectivity, not credentials. Host access stays
blocked. Exceptions require reviewed host configuration changes and are listed
in the guest's environment manifest.

T3 is the control interface; Codex, Claude Code, and OpenCode are the harnesses.
Use native subscription sign-ins inside the guest. Personal home directories,
SSH agents, general GitHub credentials, and deployment credentials stay outside.
Nix pins the environment and tools; updates go through configuration review.

## Human access

Use `https://t3.p.kalski.xyz` locally or through MikroTik Back to Home with LAN
access and LAN DNS enabled. The VPN provides connectivity; T3 device pairing
provides authentication. Changes to router WAN forwarding require reviewing
T3 exposure.

`ssh pannu-agents` reaches the guest through pannu without forwarding your SSH
agent. Generate the first device's pairing link inside the guest:

```sh
t3 auth pairing create --base-url https://t3.p.kalski.xyz --ttl 5m --label phone
```

Open the one-time link on that device. Authorization persists after the link
expires. Paired administrators can create more links and revoke devices in
T3's connection settings.

## Separate GitHub identity

The personal machine account `kqlski` owns the forks, including private
forks. Provision forks and private-repository collaborator access outside the
VM: that account's login has broader access than agents should receive.

Agents use two GitHub Apps:

| App | Installation | Permissions |
| --- | --- | --- |
| Fork writer | All `kqlski` repositories | Contents write |
| PR author | Selected `kahlstrm` originals | Contents, Checks, Actions, Commit statuses read; Pull requests write |

Both also require Metadata read. Neither receives upstream Contents write,
Administration, or Workflows permissions. Agents push to forks and file upstream
PRs as the PR App's bot; the operator merges. PR write permits editing and
closing PRs, but merging requires Contents write. These Apps do not create forks.

Encrypt App keys with age for the guest and administrator. Agents can read the
decrypted keys inside the VM; local helpers mint short-lived tokens. The App
installations enforce the permission boundary. Helper repository lists and token
expiry cannot contain an agent that retains an App key; revoke the installation
or rotate its key to withdraw access.

Set `origin` to the fork and `upstream` to the original. Ordinary `gh`, including
T3's GitHub actions, automatically uses App credentials. PR commands target
the original; explicit repository selectors override that default. Outside a
checkout, discovery and PR queries use a token limited to configured originals.
Do not sign into personal GitHub inside the guest. After configuring Apps,
verify fork push and PR creation succeed while upstream push and merge fail.
Review upstream CI before allowing fork code to execute with privileged credentials.

## Improving the environment

Agents receive shared instructions, a deployed-environment manifest, and a
checkout of this configuration. They should investigate recurring environment
problems and propose small declarative fixes through the same fork-and-PR
workflow. The operator reviews, merges, and deploys; agents cannot deploy their
own changes.

The operator also provisions Apps, encrypted keys, and provider sign-ins. Treat
persistent guest state and backups as credentials: they include provider
sessions, paired-device state, and the SSH host key that decrypts App secrets.
