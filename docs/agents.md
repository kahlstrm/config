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

Agent VMs run on QEMU's `q35` machine type instead of microvm.nix's default
`microvm`; [ADR 10](../infra/docs/adr/0010-run-agent-vms-on-q35.md) records why.

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
personal credentials stay outside the agents VM.

What the App cannot do, such as opening a PR in an upstream project from a fork
under the owner, goes through the ops environment: there `gh` is signed in as the
operator's own account, and agents use it only in delegated tasks where the
operator approves each command. GitLab works the same way: ops' `glab` is signed in
as the operator's gitlab.com account for issues and merge requests in projects
hosted there.

## Environment updates

Agents can deploy merged upstream `main` to their configured environment. This
allows routine updates after review without granting access to host deployment.
Deployment runs independently of the requesting session so service restarts do
not interrupt it.

VM updates cover the running environment; the operator retains control of the
boot image, resources, and network policy. Dedicated machines can update their
whole system. Successful updates persist across reboots, and failed activation
attempts rollback. An operator's new VM boot image takes precedence. A host
switch only stages the agents VM's new boot image so running sessions continue;
the switch reports when one is pending, and `systemctl restart microvm@agents`
boots it. Ops instead restarts during the switch whenever its image changes
(`restartOnSwitch`), which ends its running sessions.

The VM owns a persistent Nix store so host image updates retain guest deployment
closures and build dependencies. Boot images supply missing store contents before
registration; replacing an image does not discard the guest's Nix state.

The host builds each VM's system as well. Every five minutes,
`agent-cache-warm.service` on pannu checks upstream `main` and builds the
`agents` and `ops` systems that `agent-deploy` would build, into GC roots under
`/nix/var/nix/gcroots/agent-cache`. Harmonia serves pannu's store on a unix
socket behind nginx at `https://nix-cache.p.kalski.xyz:5443`, with the
`*.p.kalski.xyz` certificate (`modules/agents/vm/cache.nix`). nginx admits only
the guests' addresses, and each guest resolves the name to its own gateway and
reaches it as the allowed service `nix-cache`. Guests prefer it to
cache.nixos.org, so a deployment downloads what pannu built. Only pannu can
answer on a guest's gateway, and it already controls the guest, so the guests
trust these paths without a signing key. Ops is too
small to build T3 Code. Its deployment waits up to 30 minutes for pannu to hold
its system and fails instead of building. If it times out because `main` moved
on, run `agent-deploy` again. `journalctl -u agent-cache-warm` on pannu shows
what was built or why a build failed.

Nix manages the shared environment and skills. Provider CLIs use their native
updaters so they can follow provider releases independently. Persistent state and
backups contain credentials and must be protected accordingly.

## Stuck VM disks

When a guest's processes hang in D state with "blocked for more than" in its
console and the host shows no I/O pressure, capture QEMU's view before restarting
the VM: a restart loses it. Run this as root on pannu, setting `vm` to `agents` or
`ops`. QMP takes one client at a time, so run it before `systemctl stop`, which
uses the same socket.

```sh
vm=agents
out=/root/vm-stall-$vm-$(date -u +%Y%m%dT%H%MZ); mkdir -p "$out"; cd /var/lib/microvms/$vm
pid=$(systemctl show -p MainPID --value microvm@$vm)
qmp() { (printf '{"execute":"qmp_capabilities"}\n%s\n' "$1"; sleep 1) | nix shell nixpkgs#socat -c socat - UNIX-CONNECT:$vm.sock | jq -c 'select(.return != {}) | .return // .error // empty'; }
sample() {
  qmp '{"execute":"query-block"}' | jq -c '.[] | {device, qdev, "io-status"}'
  for dev in $(qmp '{"execute":"x-query-virtio"}' | jq -r '.[] | select(.name == "virtio-blk") | .path'); do
    for queue in $(seq 0 15); do
      qmp "{\"execute\":\"x-query-virtio-queue-status\",\"arguments\":{\"path\":\"$dev\",\"queue\":$queue}}" |
        jq -c --arg dev "$dev" 'select(."queue-index" != null) | {$dev, "queue-index", inuse, "shadow-avail-idx", "last-avail-idx", "used-idx", "signalled-used"}'
    done
  done
  for fd in /proc/$pid/fd/*; do
    [ "$(readlink "$fd")" = "anon_inode:[io_uring]" ] && { echo "== io_uring fd ${fd##*/}"; cat /proc/$pid/fdinfo/${fd##*/}; }
  done
  for task in /proc/$pid/task/*; do echo "== ${task##*/} $(cat $task/comm) $(cat $task/wchan)"; cat $task/stack; done
}
sample > "$out/sample-1.txt"; sleep 10; sample > "$out/sample-2.txt"
cat /proc/pressure/io > "$out/host-pressure.txt"; dmesg -T | tail -200 > "$out/host-dmesg.txt"
journalctl -u microvm@$vm --since -2h > "$out/console.log"
```

The guest's own count of in-flight requests helps too. Logging in may hang on
the stuck disk, since sshd reads `~/.ssh` first, so bound it with a timeout from
a machine with your guest key (agents is `10.83.0.2`, ops `10.83.0.6`):

```sh
timeout 30 ssh -o ConnectTimeout=5 agent@10.83.0.2 'grep -H . /sys/block/vd*/inflight'
```

Compare a queue's indexes across the two samples to see where the requests stopped:

- `inuse` above 0 and unchanged: QEMU took requests from the guest and never
  completed them, so they are in its backend. If QEMU holds io_uring instances,
  their fdinfo shows where. `SqHead` behind `SqTail` means the requests were never
  submitted to the kernel. `CqHead` behind `CqTail` means the kernel completed them
  and QEMU did not reap them. Equal pairs mean the kernel still holds them: look at
  the `iou-wrk` thread stacks. Without io_uring, look for QEMU threads whose
  `wchan` and stack sit in the filesystem or block layer rather than in a poll.
- `shadow-avail-idx` ahead of `last-avail-idx`: the guest queued requests QEMU
  has not picked up, so QEMU missed the notification.
- `inuse` 0 while the guest still counts requests in flight: QEMU completed them
  but the guest never saw the interrupt.

Then restart with `systemctl restart microvm@$vm`. Stopping a hung guest can take
the full stop timeout before systemd kills QEMU.

## Ops environment

The `ops` VM (`machines/ops.nix`) holds root infrastructure credentials: an admin
talosconfig and a GCP service account for Terraform's `local-talos` layer. Running
`ops-kubeconfig` there writes the cluster-admin kubeconfig that `local-talos` outputs
to `/run/ops-credentials/kubeconfig`, where `KUBECONFIG` points; it mints nothing new,
since the service account already reads that state, and a reboot removes it. Agents
reach it only through T3: the agents VM's T3 links to it at approval-required, so
the operator approves every command of a delegated thread in the T3 app outside a
short read-only allow list. The host admits the agents guest to the ops guest's T3
port and nothing else (`allowedClients` on the ops VM, the matching `ops-t3`
allowed service on the agents VM); ops cannot open connections to the agents VM.
The operator's T3 app reaches it at `t3-ops.p.kalski.xyz`.

The approval gate is the boundary, so ops omits what would bypass it. The agent
user has no passwordless sudo, and ops has no GitHub App and reads the public
configuration anonymously. Its `gh` uses the operator's own account, signed in once
with `gh auth login` into `/var/lib/ops-github`. Nothing sets `GH_CONFIG_DIR`, so
T3's server cannot read the token for its own GitHub features; agents name the
directory in each command, and no `gh` command is on the allow list. Its `glab`
uses the operator's gitlab.com account the same way, signed in with a personal
access token into `/var/lib/ops-gitlab`; nothing sets `GLAB_CONFIG_DIR`, and no
`glab` command is allowed either. The credentials' private keys are generated on ops at
boot and never leave it, not even encrypted in the repository. They live in
`/var/lib/ops-credentials`, outside the agent's home and projects. Only their
public halves are committed: the operator-signed Talos client certificate and the
Talos CA under `modules/agent-ops/public/`, and the GCP service account and its
uploaded key ID in `machines/ops.nix`. From these, ops assembles the talosconfig
and the GCP key file in `/run/ops-credentials`. Claude Code's managed settings
(`modules/agent-ops/claude.nix`) are its only permission rules: they allow a few
read-only `talosctl`, `terraform` and `git` commands and deny file reads of the
credentials. Every `kubectl` command asks, reads included. Other harnesses lack such rules, so ops installs only Claude Code
and its managed T3 settings disable every other provider; T3 restores them at each
start. The `agent-ops`, `agent-ops-providers`, `agent-ops-credentials` and `agent-ops-deploy` checks
enforce these properties.

The operator can raise a delegated thread to **Auto** once its plan is approved. In
the ops app, choose Auto in that thread's composer and send a message, such as the go
ahead; choosing the mode alone changes nothing until a message is sent. Claude's auto
mode then reviews each command instead of asking; the deny rules still apply. Raise
between turns, because Claude cannot switch modes in a running turn and T3 ends it.
Check first that the thread has no queued messages: T3 checks a message against the
sender's limit when it is sent, so a message queued earlier from the agents VM would
run at Auto. Once a thread is above the link's cap, the agents VM can still read and
wait on it but can no longer send to, answer or change it. Bypass mode stays disabled,
so T3 runs Full access in auto mode too. The delegated task on the agents VM ends with
the turn before the raise, and later turns don't wake it; once the operator reports the
task done, the agent reads the result from the ops thread. Don't approve a command that starts `claude` or
`t3` on ops: a nested Claude could run in auto mode outside the thread's approvals.
Ops' agent also follows its own instructions (`modules/agent-ops/instructions.md`):
it checks that a task makes sense and that each command matches the approved plan
before running it.

Ops also deploys merged `main` to pannu, zima and poenttoe, so agents can delegate a
deployment instead of handing it to the operator. Each of these machines imports
`modules/ops-deploy.nix`, which creates an `ops-deploy` account that trusts ops' deploy
key (`deployers.ops` in `lib/ssh-keys.nix`) and gives it a forced command:
`ssh <machine> deploy` queues the machine's `agent-deploy` runner, which builds and
switches to its own configuration from upstream `main`; `status` and `log` report on it.
There is no shell or forwarding, so the key decides when a merged change lands but not
what lands. The host opens SSH to each machine for ops only (pannu at ops' gateway, zima
on the LAN, poenttoe over ZeroTier). From ops' tap address pannu accepts only
`ops-deploy`. `status` and `log` are on ops' allow list; `deploy` asks the operator.
A pannu deploy restarts ops when ops' image changes and only stages the agents VM's
new image, so on pannu the forced command also takes `restart-vm <agents|ops>`, which
restarts that VM's `microvm@` unit to boot its staged image; it asks the operator too.
It returns before the VM stops, so ops can restart itself, ending its own running turn.
`make deploy-<machine>` from the operator's machine still deploys any working tree.

Ops also runs an Amp runner, `ops` (`modules/agent-ops/runner.nix`), for privileged
work that Amp threads hand it, starting with `local-networking` applies. It runs as
`amp`, not `agent`, so the T3 agent's home, instructions and credentials stay out of
its reach, and it has no deploy rights. It asks before every tool call, file reads
included, and refuses commands that name its credentials or print environments. Its
only credential is its own GCP key for the `ops-networking` service account, which
`gcp-project` lets write `local-networking` state and read the `local-networking`
secret. A maintainer registers its Amp access key once on pannu; see the module.

[ADR 9](../infra/docs/adr/0009-approval-capped-ops-environment.md) records why ops is built this way, and [the auto-mode ADR](../infra/docs/adr/2026-11-06-operator-raised-auto-mode-on-ops.md) why the operator may raise its threads to Auto.

`agent-deploy` on ops deploys merged `main` like the agents VM. Signing, uploading,
renewing and revoking a credential follow `modules/agent-ops/default.nix`, which
also lists the GCP permissions the service account needs. To set up ops once, pair the T3
app with `t3-ops.p.kalski.xyz`, sign in to Claude and `gh` in the ops VM, and link the agents
VM to it. T3 links only over https or loopback, so the agents VM reaches ops through a
loopback forward (`modules/agents/vm/ops-link.nix`). The hub redeeming a pairing code
chooses the link's access, so create the code on ops limited to orchestration scopes;
such a code refuses a full-access link:

```sh
# on ops
t3 pair --ttl 10m --scope orchestration:read --scope orchestration:operate
# on the agents VM
t3 environment link --access approval-required --pairing-code <code> http://127.0.0.1:3774
```

On ops, `t3 auth session list` then shows the link's session with only
`orchestration:read orchestration:operate`; revoke it there if it shows more. The link
expires after 30 days; link again with a new code before then.

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
