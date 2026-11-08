# Move the agents VM to KubeVirt on w2 once pannu shows contention

- Status: proposed
- Date: 2026-11-08
- Related: [ADR 7](0007-amp-orbs-on-klusse.md),
  [ADR 9](0009-approval-capped-ops-environment.md),
  [ADR 10](0010-run-agent-vms-on-q35.md),
  [ADR 11](0011-replace-flannel-with-cilium.md)

## Context

pannu is one machine carrying unrelated jobs: Steam and Jovian gaming with
Sunshine, the agents VM (8 vCPU, 32 GiB), the ops VM (2 vCPU, 4 GiB), builds
for frame-work, the agent VMs' binary cache (`agent-cache-warm` and harmonia
behind nginx, `modules/agents/vm/cache.nix`), and nginx for owui and bambuddy.
A reboot or a host switch takes all of them down together, and games, builds
and agents share its CPU, memory and disk.

The cluster's workers sit nearly idle. On 2026-11-08, `kubectl top` showed:

| Node | Hardware | CPU | Memory | Allocatable memory | Requested |
|---|---|---|---|---|---|
| w1 | 14 cores, 32 GiB | 4 % | 22 % | 28.6 GiB | 4.7 GiB |
| w2 | Ryzen 9 9955HX, 16 cores / 32 threads, 30 GiB | 0 % | 13 % | 26.5 GiB | 1.1 GiB |

w2 has three NVMe disks: Talos on a 256 GB disk, the `local-storage` user
volume on a 1 TB disk (2 % used), and a second 1 TB disk that still holds the
unmanaged `u-orb-storage` partition ADR 7 left behind.

### Evidence of contention

Prometheus does not scrape pannu, so there is no host-side history. From inside
the agents VM on 2026-11-08:

- CPU steal was 0.05 % over the 57 minutes since its last boot.
- No out-of-memory kill in the guest's journal since 2026-10-13.
- The guest booted 8 times between 2026-10-17 and 2026-11-08. The guest cannot
  tell which were host reboots, host switches that restarted it, or deliberate
  restarts (the q35 change, ADR 10). The boot that ended on 2026-11-01 at 23:05
  has no shutdown in its journal.

This shows no contention yet. It cannot show contention while a game runs,
pannu's own memory pressure, or why the VM restarted.

### What a move rewrites

The guest side carries over: the NixOS configuration, `agent-deploy`, the
persistent `/home`, `/var` and `/nix` volumes with the store seed, and the
cache client. On the host side, everything pannu provides through microvm.nix
is rewritten:

- **Network boundary.** The per-guest nftables table (`modules/agents/vm/network.nix`)
  becomes NetworkPolicies on the VM's launcher pod: egress to public 80/443 and
  DNS, the named allowed services, nothing else private. Under the current CNI
  a new pod is unpoliced for about two seconds
  ([ADR 4](0004-network-policies-apply-seconds-after-pod-start.md)); a VM
  boots for longer than that, so the guest cannot use the window, but the
  boundary is no longer enforced from the first packet until Cilium
  (ADR 11) lands. The VM's address becomes a pod address masqueraded to w2's,
  so LAN services that admit the agents VM by address admit every pod on w2
  instead.
- **Storage.** The three volumes become node-local PersistentVolumes pinned to
  w2, on a dedicated disk like ADR 7's `orb-storage`. The VM cannot run on w1
  while w2 is down.
- **Boot image.** The microvm.nix runner and its erofs store disk become a
  containerDisk built in CI and pinned by digest (ADR 7). The store seed
  already copies a new image's closure into the persistent `/nix`.
- **Tests and checks.** The host-side VM tests that boot through microvm.nix
  and check the nftables rules are replaced by policy tests in the Talos lab
  and a KubeVirt boot test.
- **Ingress.** `t3.p.kalski.xyz` on pannu's nginx becomes a route through
  Traefik, and the ops link (`ops-link.nix`) reaches ops across the LAN
  instead of across pannu.

ADR 7's lessons apply: KubeVirt's support-container CPU limits (already raised
in `infrastructure/configs/kubevirt.yaml`), node-pinned local disks, large
containerDisks and slow pulls, and scheduling delays from etcd timeouts. One
long-lived VM avoids the spawn, pause and hibernate problems that made orbs
hard, and restarts only on a new image or a node reboot.

### KubeVirt today

KubeVirt runs with no VMs since the orbs were removed: 12 pods using about
1.5 GiB of memory across the workers, plus webhooks that ADR 11 must gate at
its cutover. `infra/TODO.md` plans its removal. It is installed from a copy of
upstream's `kubevirt-operator.yaml` (v1.9.1, image pinned by digest). KubeVirt
ships no official Helm chart, so like ADR 6 the upstream manifest is the
official installation.

## Decision

1. **The agents VM moves to a KubeVirt VM on w2, but only after contention on
   pannu is measured.** Until then it stays on pannu unchanged. The trigger is
   any of:
   - guest CPU steal above 5 % for 10 minutes while pannu runs a game, or
     agent work visibly slowing games;
   - memory pressure on pannu (PSI `some` above 10 % for 5 minutes, or an
     OOM kill of the host, a game or a VM);
   - more than two unplanned agents VM restarts a month caused by pannu
     itself (gaming crashes, host-only updates).

   To measure, pannu runs node-exporter and Prometheus scrapes it, alerting on
   the first two. Restart causes come from pannu's journal
   (`microvm@agents`).

   The VM must fit w2: 32 GiB does not fit its 26.5 GiB allocatable memory,
   so either w2 gets more memory or the VM shrinks (the guest used 3 GiB at
   rest on 2026-11-08; its peak is unmeasured).
2. **ops stays on pannu.** It holds the root credentials that repair the
   cluster, so it must not run on the nodes it reboots, like the stationary
   site. A small dedicated machine replaces pannu only if pannu's own reboots
   start blocking repairs.
3. **KubeVirt** — open, see below.
4. **The build cache stays on pannu.** ops keeps depending on it, so pannu
   keeps building both systems. When the agents VM moves, it reaches
   `nix-cache.p.kalski.xyz:5443` through a NetworkPolicy exception, and nginx
   admits w2's address. Because that admits every pod on w2, the cache gains
   a signing key first and guests stop trusting it unsigned. Builders in the
   cluster stay rejected: pannu already builds for ops.

### Installing KubeVirt

If KubeVirt stays, it keeps the vendored upstream manifest. A `just
kubevirt-refresh <version>` recipe downloads that release's
`kubevirt-operator.yaml`, resolves `quay.io/kubevirt/virt-operator:<version>`
to its digest, pins it and rewrites the header with the version and commit, so
an update is one reviewed diff.

## Open decisions

- **KubeVirt now**: remove it per `infra/TODO.md` and reinstall from the same
  upstream manifest when the trigger fires, or keep it running idle until
  then.
- **Fitting w2**: add memory to w2, or shrink the agents VM.
- **Cache access from w2**: confirm the signed cache on pannu over a LAN
  exception rather than revisiting cluster builders.

## Consequences

- Nothing changes until the trigger fires, apart from scraping pannu.
- After a move, pannu keeps gaming, ops, the cache and its nginx sites; the
  agents VM no longer restarts with pannu, but restarts with w2 instead and
  cannot fail over to w1.
- The agents VM's network boundary moves from pannu's nftables to cluster
  policy, which the agents environment can read but not change, and which
  merges to `main` control (GitOps trust boundary).
- pannu's IOMMU is enabled so its GPU could be passed to the agents VM; no
  GPU is passed through today, and after a move it no longer could be.
