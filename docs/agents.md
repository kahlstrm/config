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

Steps that need the operator's credentials, such as infrastructure applies, run
in an agent on the operator's machine. That agent reaches T3 as an outside MCP
client, so it can read the requesting thread and send results back to it.

T3's MCP endpoint is `https://t3.p.kalski.xyz/mcp`, proxied by pannu and reachable
from the home network. Each harness signs in separately; approve each one with
**Supervised** access, which allows sending messages. A pairing code comes from
T3's **Settings → Connections**. Configure it per user on the operator's machine.
Project files would also load in the agent VM, which cannot reach the endpoint.

```sh
claude mcp add --transport http --scope user t3 https://t3.p.kalski.xyz/mcp
claude mcp login t3

codex mcp add t3 --url https://t3.p.kalski.xyz/mcp
codex mcp login t3
```

OpenCode's global config is this repository's `config/opencode/opencode.json`.
Add a `t3` remote server under `mcp` there, then run `opencode mcp auth t3`.
Revoke a harness's access under **Settings → Connections**; sign-ins last 30
days.

See the [agent instructions](../modules/agents/environment/instructions.md) for
the working procedures and environment manifest.
