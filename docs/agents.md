# Coding agent environments

## Purpose

Agents get a persistent environment with shared tools, skills, workspaces, and
provider sign-ins. T3 provides the human interface. This keeps agent work separate
from the personal host without requiring repeated setup for each session.

Agents within an environment share credentials and are one trust domain. On
pannu, a dedicated VM isolates that domain from the host. Host-controlled network
rules restrict access to private services; exceptions are reviewed explicitly.
Human access uses the private network and T3 device pairing.

## Environment and hosting

The reusable environment lives in `modules/agents/environment/`; VM integration
lives in `modules/agents/vm/`. This lets another dedicated NixOS machine use the
same agent setup without depending on pannu or MicroVM.

`machines/agents.nix` defines the agent environment, while `machines/pannu.nix`
defines its hosting. Agents can update their environment without administering
the host. On a dedicated machine without VM isolation, the whole machine belongs
to the agents' trust domain.

On pannu, persistent guest disks live on the partition mounted at `/mnt/agents`.
MicroVM runner links and runtime sockets remain under `/var/lib/microvms`.
The VM requires the storage mount before starting.

## GitHub access

Agents use one GitHub App installed on the owner account. They push `agent/`
branches to the owner's repositories and open PRs there; merging stays with the
operator unless they explicitly ask an agent to push a change directly to the
default branch. One installation keeps private and public repositories on the same
workflow without forks, a second account, or synchronization.

Branch rulesets keep agents off default branches where GitHub offers them.
Private repositories on a free plan cannot use rulesets, so there the App can
technically write any branch and agent instructions are the boundary. The
operator provisions the App, its installation, secrets, and provider sign-ins;
personal credentials stay outside.

## Environment updates

Agents can deploy merged upstream `main` to their configured environment. This
allows routine updates after review without granting access to host deployment.
Deployment runs independently of the requesting session so service restarts do
not interrupt it.

VM updates cover the running environment; the operator retains control of the
boot image, resources, and network policy. Dedicated machines can update their
whole system. Successful updates persist across reboots, and failed activation
attempts rollback. An operator's new VM boot image takes precedence. A host
switch only stages a new boot image so running sessions continue; the switch
reports when one is pending, and `systemctl restart microvm@agents` boots it.

The VM owns a persistent Nix store so host image updates retain guest deployment
closures and build dependencies. Boot images supply missing store contents before
registration; replacing an image does not discard the guest's Nix state.

Nix manages the shared environment and skills. Provider CLIs use their native
updaters so they can follow provider releases independently. Persistent state and
backups contain credentials and must be protected accordingly.

## Operator-machine agents

An agent on the operator's machine, such as one running infrastructure applies,
reports to the requesting T3 thread through T3's MCP server. Configure it in
`~/config` only; the files are gitignored because agent hosts cannot reach it.
Codex reads them only when `~/config` is trusted.

```sh
cd ~/config && url=https://t3.p.kalski.xyz/mcp
claude mcp add --transport http --scope local t3 "$url" && claude mcp login t3
mkdir -p .codex && printf '[mcp_servers.t3]\nurl = "%s"\n' "$url" >> .codex/config.toml && codex mcp login t3
printf '{"mcp": {"t3": {"type": "remote", "url": "%s"}}}\n' "$url" > opencode.json && opencode mcp auth t3
```

Approve each sign-in with **Supervised** access, using a pairing code from T3's
**Settings → Connections**.

See the [agent instructions](../modules/agents/environment/instructions.md) for
the working procedures and environment manifest.
