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

A host declares each VM under `local.agentVMs.<name>`. Every VM is its own trust
domain with its own tap interface, subnet, DNS forwarder, egress rules and allowed
services; a VM cannot reach another VM's guest or host-side address. The one
exception is explicit on both sides: a guest's `allowedClients` admits another VM
to listed ports, which that VM must also list among its allowed services.

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

## Ops environment

The `ops` VM (`machines/ops.nix`) holds root infrastructure credentials: an admin
talosconfig and a GCP service account for Terraform's `local-talos` layer. Agents
reach it only through T3: the agents VM's T3 links to it at approval-required, so
the operator approves every command of a delegated thread in the T3 app outside a
short read-only allow list. The host admits the agents guest to the ops guest's T3
port and nothing else (`allowedClients` on the ops VM, the matching `ops-t3`
allowed service on the agents VM); ops cannot open connections to the agents VM.
The operator's T3 app reaches it at `t3-ops.p.kalski.xyz`.

The approval gate is the boundary, so ops omits what would bypass it. The agent
user has no passwordless sudo, ops has no GitHub App and reads the public
configuration anonymously, and agenix decrypts the credentials to `/run/agenix`,
outside the agent's home and projects. Claude Code's managed settings
(`modules/agent-ops/claude.nix`) are its only permission rules: they allow a few
read-only `talosctl`, `terraform` and `git` commands and deny file reads of the
credentials. The `agent-ops` check enforces these properties. Use Claude Code on
ops; other harnesses have no equivalent allow list there.

`agent-deploy` on ops deploys merged `main` like the agents VM. Enrolling or
revoking a credential follows `modules/agent-ops/default.nix`, which also lists
the GCP permissions the service account needs. To set up ops once, pair the T3
app with `t3-ops.p.kalski.xyz`, sign in to Claude in the ops VM, create a pairing
code there with `t3 pair`, and link it from the agents VM:

```sh
t3 environment link --access approval-required --pairing-code <code> http://10.83.0.6:3773
```

## Operator-machine agents

An agent on the operator's machine, such as one running infrastructure applies,
reports to the requesting T3 thread through T3's MCP server. Handed-over
instructions name that thread as `T3 thread: <id>`. Configure the server in user
scope so the agent reaches it from any project; OpenCode's entry lives in
`config/opencode/opencode.json`. Agent hosts load none of these.

```sh
url=https://t3.p.kalski.xyz/mcp
claude mcp add --transport http --scope user t3 "$url" && claude mcp login t3
codex mcp add t3 --url "$url" && codex mcp login t3
opencode mcp auth t3
```

Approve each sign-in with **Full access**, which lets the agent start threads,
using a pairing code from T3's **Settings → Connections**.

See the [agent instructions](../modules/agents/environment/instructions.md) for
the working procedures and environment manifest.
