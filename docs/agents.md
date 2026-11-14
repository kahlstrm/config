# Coding agent environments

## How agents work

Agents run in Amp ([the runners ADR](../infra/docs/adr/2026-11-09-amp-runners-on-hosts.md)).
Repository work happens in Amp-hosted orbs, which reach the internet only. Work
that needs the LAN goes to an Amp runner on the machine it concerns:

- **pannu and zima** each run a runner (`modules/amp-runner.nix`) as the
  unprivileged `amp` user. A thread there deploys merged `main` to its own host
  with `host-deploy deploy`, then follows it with `host-deploy status` and
  `host-deploy log`, all without approval, and manages the host's services for
  debugging.
- **pannu** holds the break-glass read-only kubeconfig for klusse, and is
  configured to start `infra-apply` for `local-networking` (`modules/infra-apply`),
  whose credentials `amp` cannot read. That applier runs without approval once
  its layer's certificate is uploaded and its `keyId` committed, as the module
  describes; until then a maintainer applies the layer from their machine.
- **klusse** runs a runner pod (`infra/local-kubernetes/apps/amp-runner`) with
  read-only cluster access.
- **pannu-agents**, a temporary runner in the agents VM, stands in for orbs:
  root in that VM, no prompts, and worktrees of the checkouts in
  `/home/amp/workspace`. Its threads can read the VM's credentials and use its
  network exceptions
  ([the compute runners ADR](../infra/docs/adr/2026-11-14-temporary-compute-runners.md)).
- **poenttoe** has no runner yet, so a maintainer deploys it from their machine.

Agents ship on their own: when told to ship, a thread merges its PR once
`sol-loop` approves and CI is green, and no person reviews it. The
destructive-change guard fails a PR that removes data or a protection unless it
is declared. The ruleset in `.github/rulesets/main.json`, which makes `main`
take changes only through PRs that passed the guard, applies once it is imported
([the frictionless shipping ADR](../infra/docs/adr/2026-11-10-agents-ship-without-approvals.md)).
Admin work that no runner can do yet, such as `local-talos` applies and admin
`talosctl`, runs on a maintainer's machine; see `infra/AGENTS.md`.

The rest of this guide covers the agents VM, a persistent T3 environment on pannu
that stays until the runners ADR's step M7, and the ops VM beside it, which takes
no work and is being removed
([the ops retirement ADR](../infra/docs/adr/2026-11-10-retire-the-ops-vm.md)).

## The agents VM

Agents in the VM get a persistent environment with shared tools, skills,
workspaces and provider sign-ins, and share its credentials as one trust domain.
A dedicated VM isolates that domain from pannu. Host-controlled network rules
restrict access to private services; exceptions are reviewed explicitly. People
reach it over the private network and T3 device pairing.

### Environment and hosting

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

### GitHub access

The agents VM uses its own GitHub App, installed on the owner account. Its agents
push `agent/` branches to the owner's repositories and open PRs there. One
installation keeps private and public repositories on the same workflow without
forks, a second account, or synchronization. Orbs act as the Amp GitHub App
instead. Neither App administers repositories, so neither can change a ruleset.

Private repositories on a free plan cannot use rulesets, so there either App can
technically write any branch and agent instructions are the boundary. A
maintainer provisions the App, its installation, secrets and provider sign-ins;
personal credentials stay outside the VM.

What the Apps cannot do, such as opening a PR in an upstream project from a fork
under the owner, or an issue or merge request on gitlab.com, is left to a
maintainer. A scoped token may cover upstream work later.

### Environment updates

Agents can deploy merged upstream `main` to their configured environment. This
allows routine updates after review without granting access to host deployment.
Deployment runs independently of the requesting session so service restarts do
not interrupt it.

VM updates cover the running environment; pannu's configuration keeps control of
the boot image, resources, and network policy. Dedicated machines can update their
whole system. Successful updates persist across reboots, and failed activation
attempts rollback. A new VM boot image from pannu's configuration takes precedence. A host
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

### Stuck VM disks

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

### The ops VM

The `ops` VM (`machines/ops.nix`) still boots on pannu until the ops retirement
ADR's stage 4 removes it. It holds the old root infrastructure credentials (an
admin talosconfig and the `ops-terraform` GCP account), and nothing is delegated
to it: agents no longer link to its T3, its link is not renewed, and its runner
was removed before it ever ran. Its forced-command deploy key
(`modules/ops-deploy.nix`) is still installed on pannu, zima and poenttoe until
that stage, but agents deploy through their hosts' runners instead.
[ADR 9](../infra/docs/adr/0009-approval-capped-ops-environment.md) records why ops
was built this way.
