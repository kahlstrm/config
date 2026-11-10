# One runner per managed thing, with builds on runners and a klusse runner in a pod

- Status: accepted; the klusse runner is in `local-kubernetes/apps/amp-runner`
  and its image in `pkgs/amp-runner-image.nix`; the break-glass read path is on
  the pannu runner until the ops runner exists; the builder is not yet implemented
- Date: 2026-11-09
- Related: [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md),
  [the orb shipping ADR](2026-11-09-orb-shipping-guardrail-ladder.md),
  [the agent VM placement ADR](2026-11-08-agent-vm-placement.md)
- Amends: the runners ADR (which runners exist and what they hold), the orb
  networking ADR (cluster work moves from pannu to the klusse runner), and the
  agent VM placement ADR's direction

## Context

The runners ADR puts a runner on each NixOS host, and the orb networking ADR
sends LAN work to the pannu runner or the ops runner. Read-only cluster access
and alert investigations would then need a kubeconfig on pannu, a host that
also runs games, the ops VM and the agents VM. The placement ADR planned to
move the agents VM to KubeVirt on w2. With Amp, the agents VM can instead be
retired after T3, and pannu should be scaled down, with most work in orbs and
in klusse.

## Decision

### Runners

One runner per thing it manages, holding only that thing's credentials:

| Runner | Manages and debugs | Holds |
|---|---|---|
| pannu | pannu | `host-deploy` and unit management for pannu (see Debugging on host runners); for now also the pre-merge builds (see Builds) and the break-glass cluster reader (see below) |
| zima | zima | `host-deploy`, unit management and Jellyfin and Seerr state snapshots (see Debugging on host runners) |
| poenttoe | poenttoe | `host-deploy` for poenttoe, once it has a runner |
| klusse | the cluster | an in-cluster read-only ServiceAccount, `alert-investigator` |
| ops | privileged cross-cutting work | Talos admin, RouterOS, Terraform, `gh`/`glab` with a maintainer's accounts, service keys ([the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md)) |

- **The klusse runner** is an Amp runner in a pod on an x86 worker. Its
  ServiceAccount token comes from the cluster itself, so no kubeconfig is
  distributed to any host. It stays a pod: orbs can't do its work, because
  they have no LAN or cluster access.
- **No Talos `os:reader` for the klusse runner.** A pod in the cluster can't
  debug the cluster when it is broken, so node-level and Talos debugging stays
  on the ops runner.
- **ops stays outside the cluster**, so it is the way in when klusse is down.
- **A break-glass read path from outside the cluster.** A pod can't debug the
  cluster when the cluster is the problem, including when the klusse runner
  itself never registers. A runner outside the cluster holds a kubeconfig for
  `break-glass-reader` (see below).
- **Orbs** get Amp OIDC only for things they can reach on the internet: GCP
  logs, metrics and narrow Secret Manager reads. Orbs get only secrets granted
  to them by name: `local-kubernetes`, which they edit (amended 2026-11-10; see
  the secret-edits ADR). Never these three (also in the ops runner ADR's
  required check):
  - `sops_age_key`, which decrypts every SOPS secret in the repository;
  - `klusse_amp_runner_key`, the klusse runner's account-wide Amp key;
  - `local-networking`, which holds the RouterOS and Terraform credentials, so
    reading it would break the rule that orbs get no LAN access.

  Read-only LAN work goes to the runner that manages the
  thing, through a runner thread (see the orb networking ADR).
- **Cost:** every runner's Amp key acts as the whole account, so each new
  runner is one more account-wide key to protect. With five runners there are
  five keys, and the klusse runner's key sits in the cluster (see below), not
  on a host disk.

### Debugging on host runners

Every host runner (`local.ampRunner` with `host-deploy`, today pannu and zima)
gets the same debugging rights, so threads can diagnose and recover a host's
services without a maintainer:

- **Reading without a prompt.** `amp` is in `systemd-journal` and reads every
  journal on its host. The runner's permission rules allow single `systemctl
  status`, `show` and `list-units` and `journalctl` commands without a prompt.
  Journals can contain secrets that a service logs, and every thread on the
  runner can read them, so they reach Amp's storage too; a service that logs a
  secret exposes it.
- **Managing units behind a prompt.** One polkit rule on
  `org.freedesktop.systemd1.manage-units` lets `amp` start, stop, restart and
  reload the services its host's configuration defines, by name, except
  protected ones. The runner's rules ask before each of these. A reboot is
  `systemctl start reboot.target`, asked like any other start.
- **An allowlist, not a denylist.** polkit sees only the requested unit's name
  and the verb, and systemd also authorizes `systemd-run` and `isolate` as a
  `start` of the named unit. A rule that allowed every unit except a denylist
  would therefore let a thread run a transient unit as root, or stop protected
  services by stopping `sysinit.target` or a slice they belong to, or by
  isolating a target. So the rule allows only configured services by name and
  `reboot.target`: no targets, slices, mounts or sockets, and no template
  instances the configuration does not name. Each allowed name has a unit
  file, so systemd refuses a transient unit under it. Unit edits, masks,
  `kill`, `daemon-reload` and transient units stay root's.
- **Protected services, on every host:** the runner's own unit, `agent-deploy`,
  `sshd`, polkit, D-Bus, the Nix daemon, the firewall and nftables, the network
  managers and `tailscaled`. They would cut the runner or maintainers off the
  host, interrupt a deployment or drop its firewall. Every service whose stop,
  restart or start would reach one of them is protected too: what they require,
  bind to, are part of or conflict with, and what is required by or conflicts
  with them, as the configuration declares it.
  `local.ampRunner.protectedUnits` adds a host's own; dependencies that a
  template or `unitConfig` sets must be listed there by hand.
- **On pannu,** `microvm@ops` and every service it requires or is part of
  through its template (its tap, virtiofs, PCI and boot-marker units,
  `agent-ops-network` and `agent-storage`) are protected, since stopping any of them stops ops,
  and pannu's `amp` user must not reach the VM that holds root credentials. Ops restarts only when a deploy changes its image
  (`restartOnSwitch`). `agent-network`, the agents VM's firewall, is protected
  like the host firewall. `microvm@agents` is not protected: an approved restart
  is fine, and the agents VM is being retired.
- **Prompts guide; the user account is the boundary.** Amp's built-in rules let
  a thread run code without approval, so a thread can manage unprotected units
  without a prompt by calling `systemctl` from a script. The allowlist, not the
  prompt, decides which services a prompt-injected thread can stop or start;
  starting one runs only its configured command.
- **Root units that only read** can be listed in
  `local.ampRunner.readOnlyUnits`; the runner starts them without a prompt. On
  zima, `jellyfin-plugins.service` lists Jellyfin's plugin directory into its
  journal, since `amp` cannot read Jellyfin's state.

#### State snapshots on zima

Jellyfin's database migrations are one-way: rolling back the generation alone
leaves a database the old Jellyfin cannot read. Before such a deploy, a thread
on the zima runner starts `state-snapshot.service` (asked), which stops
`jellyfin` and `seerr`, takes read-only btrfs snapshots of their state
directories into `/mnt/data/.snapshots/jellyfin-<UTC time>-<directory>`, and
starts them again (`modules/state-snapshot.nix`, which also gives the rollback).

- **Scope.** `/mnt/data` is the `@media` subvolume, so a snapshot of it would
  pin every media file deleted later. Instead
  `/mnt/data/media/.state/nixarr/jellyfin` and `…/jellyseerr` each become
  their own subvolume in a one-time conversion, and only they are snapshotted.
  Converting is a reflink copy, so it is quick and takes no extra space. The
  snapshot unit refuses to run until both are subvolumes.
- **Expiry.** `state-snapshot-expire.timer` deletes these snapshots daily once
  they are 14 days old, and `state-snapshot-prune.service` (asked) deletes all
  of them. Both delete only entries named `jellyfin-*` that are read-only
  subvolumes whose parent is one of the two state subvolumes, and
  `btrfs subvolume delete` does not recurse, so no other subvolume is touched.

#### Bootstrapping zima's runner

`main` already runs Jellyfin 12 and Seerr 3.5 on zima, so the first deploy that
installs the runner also applies Jellyfin's one-way migration, before any
thread could take a snapshot. A maintainer therefore converts the state and
takes the first snapshot by hand, as root on zima, then deploys `main`:

```sh
bash -euc 'systemctl stop jellyfin seerr; cd /mnt/data/media/.state/nixarr; for d in jellyfin jellyseerr; do btrfs subvolume create $d.new; cp -a --reflink=always $d/. $d.new/; chown --reference=$d $d.new; chmod --reference=$d $d.new; mv $d $d.pre-subvolume; mv $d.new $d; done'
```

```sh
bash -euc 'install -d -m 0700 /mnt/data/.snapshots; stamp=$(date -u +%Y%m%dT%H%M%SZ); for d in jellyfin jellyseerr; do btrfs subvolume snapshot -r /mnt/data/media/.state/nixarr/$d /mnt/data/.snapshots/jellyfin-$stamp-$d; btrfs property get -ts /mnt/data/.snapshots/jellyfin-$stamp-$d ro | grep -qx ro=true; done; systemctl start jellyfin seerr; echo "Both snapshots taken: jellyfin-$stamp-*"'
```

Each command stops at its first failure. Go on only if the second one ends
with "Both snapshots taken"; otherwise fix the cause first, as Jellyfin and
Seerr stay stopped.

Then check that Jellyfin and Seerr still work on the old version, install the
runner's access key (`machines/zima.nix` gives the command), and deploy `main`
with `make deploy-zima` from a clean checkout of `main`. Once Jellyfin 12 works, delete the copies the
conversion kept: `rm -rf /mnt/data/media/.state/nixarr/{jellyfin,jellyseerr}.pre-subvolume`.
The hand-made snapshots follow the unit's naming, so they expire after 14 days
like the unit's own. Deploying a commit without the Jellyfin 12 change instead
would need a branch that reverts it and a second deploy, and the conversion
would still be needed.

### The klusse runner in a pod

Checked on 2026-11-09 without deploying anything, by building an image of the
flake's pinned `amp-cli` (0.0.1791107882-gfe04cc) and running it in Docker
with the restrictions a `restricted` pod would have:

- **Architecture:** nixpkgs ships `amp-cli` for `x86_64-linux` and
  `aarch64-linux`. The runner pins to the x86 workers (w1, w2) with a node
  selector, not the Pi 5 control planes.
- **Image:** `dockerTools.buildLayeredImage` of `amp-cli`, `bash`,
  `coreutils`, `git`, `kubectl`, `jq` and CA certificates, built from the flake
  so the runner uses the same pinned Amp as the hosts, and referenced by digest.
  It is built on a runner or in CI, never in an orb (see Builds).
- **Namespace:** its own, labelled for the `restricted` Pod Security level.
- **Pod security:** it started as uid 65532 with a read-only root file system,
  every capability dropped and `no-new-privileges`: `amp --version` worked.
  Amp needs a writable `HOME` and a `/tmp` it can execute from, because its
  Bun runtime unpacks a native module to `/tmp` and loads it; a `noexec` tmpfs
  made it fail with `ERR_DLOPEN_FAILED`. Two `emptyDir` volumes cover both.
- **Key:** `amp --no-tui` exits with "API key required" without one. The key
  is an Amp access key in `AMP_API_KEY`, from a Kubernetes Secret through
  `secretKeyRef`. It is usable from the internet, so per the
  [secret rules](../../AGENTS.md#secret-management) it lives in the
  `local-kubernetes` Secret Manager secret and reaches the cluster through an
  `ExternalSecret`, in the runner's own namespace. No role in that namespace
  grants `get` on Secrets, the `alert-investigator` ServiceAccount's included;
  only External Secrets writes it.
- **Registration:** the runner connects out to ampcode.com and registers under
  `--runner-id klusse`. Amp identifies a runner by host and working directory,
  so the pod gets a fixed `hostname` and a fixed working directory. The
  registration itself was not tested, because it would register a runner on
  the Amp account; the first deployment checks that `klusse` shows in
  the runner list and that a thread on it runs `kubectl auth can-i --list`.
- **Settings:** a ConfigMap holds the `--settings-file`: read-only `kubectl`
  commands allowed so unattended alert threads don't stall, and
  `amp.updates.mode: "disabled"`, since the image is read-only and Amp updates
  arrive through `flake.lock`.
- **One replica, `Recreate` strategy:** two pods with the same hostname and
  runner ID would both register as `klusse`, so a rollout stops the old pod
  before it starts the new one.
- **Network:** a NetworkPolicy allows DNS, the Kubernetes API and HTTPS to the
  internet, and nothing else on the LAN. The first seconds after the pod starts
  are unpoliced
  ([ADR 4](0004-network-policies-apply-seconds-after-pod-start.md)).

### The break-glass read path

When the klusse runner is down, nothing an agent can reach sees the cluster,
and an unready runner also blocks Flux's `apps` layer. A runner outside the
cluster therefore holds a read-only kubeconfig:

- **Identity:** the `break-glass-reader` ServiceAccount in `agent-debug`, bound
  only to the `agent-debug-reader` ClusterRole: pods, logs, events, workloads,
  Flux and ExternalSecret status. No Secrets, `exec`, `attach`,
  `port-forward`, proxies or writes, and none of `agent-debug-reader`'s pod
  deletion, evictions or sandbox pods. Its long-lived token is a
  `service-account-token` Secret in Git, so it needs the `apps` layer to have
  applied once, not to be healthy.
- **Delivery:** the token is age-encrypted to the runner host's SSH host key
  alone, not to the SOPS keys or other hosts, and decrypted by agenix to a file
  only the runner's `amp` user reads. The kubeconfig points at it, also readable
  only by `amp`, and the runner's service sets `KUBECONFIG`
  (`local.ampRunner.kubernetesTokenFile`).
- **Permission rules:** single read-only `kubectl` and `flux` commands (`get`,
  `describe`, `logs`, `events` and similar) run without a prompt. A `kubectl` or
  `flux` command with chaining, pipes, redirects, substitutions or several lines
  is rejected; other commands follow Amp's built-in rules. RBAC is the
  boundary; the rules only spare prompts.
- **Placement, for now on pannu:** the pannu runner is the only runner outside
  the cluster today. Once the ops runner exists, the kubeconfig moves there, next
  to node and Talos debugging, which already stay on ops, and pannu's runner goes
  back to managing only pannu: re-encrypt the token to ops' host key, set
  `kubernetesTokenFile` on ops and drop it from pannu.
- **One-time steps:** after Flux applies the ServiceAccount, someone with admin
  access to klusse reads its token and encrypts it to the host key, as
  `machines/pannu.nix` describes, then commits it and deploys the host.
  Rebuilding the cluster or recreating the token Secret needs the same again;
  deleting the encrypted file and deploying revokes it from the host.

### Alert investigations

Phase 1 of the alert migration (Homelab alerts & incidents Space) starts its
investigation threads on the klusse runner, which uses `alert-investigator`,
instead of on pannu with a kubeconfig. pannu's runner holds only the
break-glass reader, for when the klusse runner itself is down.

### Builds

- **Nothing is built in orbs.** Builds and build verification run on runners:
  the pannu runner for now, a klusse builder later.
- **Builds that move to klusse** get a builder on w1 with a cache that signs
  what it serves, as the placement ADR sketched. VM tests run there with KVM
  from KubeVirt ([the klusse placement ADR](2026-11-09-move-work-from-pannu-to-klusse.md)).
- **The cache gap:** harmonia on pannu serves pannu's store, which today holds
  what `agent-cache-warm` builds (the agents and ops systems from `main`) and
  whatever else pannu builds. Orb and CI builds never reach it.

#### Proposal: verification builds replace `agent-cache-warm`

When the pre-merge verification build (the orb shipping ADR) runs on the cache
host, it already puts the system's store paths into the store harmonia
serves. With squash merges, the merged tree equals the verified tree, so the
derivations match, and `agent-cache-warm` can be replaced or slimmed down. It
stays at most as a fallback for ops' bootstrap. Cases where the merged commit's
derivations differ from the verified ones:

- **ops and agents embed the commit.** `machines/ops.nix` and
  `machines/agents.nix` set `revision = inputs.self.rev`, which ends up in
  `/etc/agent-environment.json`. The squash commit's rev differs from the PR
  head's, so their system paths differ, although only a few small derivations
  need building. ops' deployments wait for that exact system in the cache
  (`waitForSubstituter`), so ops needs either a post-merge build of its own
  system, which is what `agent-cache-warm` keeps doing, or a revision read from
  somewhere other than its derivation. The agents VM is retired, so only ops
  is affected.
- **A PR behind `main`.** The squash commit's tree is `main` plus the PR's
  diff, which differs from the PR head unless the branch was up to date with
  `main` when verified. Verification runs on a head that includes the current
  `main`, and runs again if `main` moves before the merge.
- **A dirty tree** evaluates with revision `dirty`. Verification checks out the
  pushed head into a clean directory.
- **Darwin configurations** are not built on pannu at all.

### The placement ADR's direction

- pannu is scaled down: most work runs in orbs and klusse.
- The agents VM is retired after T3 (M7 of the runners ADR) instead of moving
  to KubeVirt. The placement ADR's move trigger and its node-exporter
  measurement for the move no longer apply.
- KubeVirt stays in klusse for VM tests and heavy work that doesn't fit small
  orbs ([the klusse placement ADR](2026-11-09-move-work-from-pannu-to-klusse.md)).
- ops stays on pannu, outside the cluster, with its cache, as that ADR decided.
- What moves to klusse: the klusse runner, and proactively the builder, its
  signed cache and the VM tests (the klusse placement ADR).

## Consequences

- Threads on host runners can stop and restart unprotected services on their
  host and reboot it, from that host's place in the LAN. A prompt-injected
  thread can therefore take services down without approval, though not cut off
  SSH, the firewall, deployments or the runner itself.
- One host holds a cluster credential: the break-glass reader, on pannu until
  the ops runner takes it over. Any thread on that runner can read its token,
  and with it the cluster's state, except Secrets, from that host's place in
  the LAN. When the cluster is the problem, the break-glass reader reads its API
  from outside, and ops reaches the nodes through Talos.
- The klusse runner's account-wide key is in Secret Manager and in the
  cluster's etcd, so whoever can read Secrets in its namespace or the
  `local-kubernetes` secret can act as the whole Amp account.
- A thread on the klusse runner acts with `alert-investigator`'s rights from a
  pod on a worker, inside its NetworkPolicy. The ops runner ADR's required
  check covers that ServiceAccount instead of a reader identity on pannu.
- pannu's runner builds other hosts' configurations until a klusse builder
  exists, through the Nix daemon access its `amp` user has as an untrusted
  client (#342).
- The orb-side OIDC role for Secret Manager must name individual secrets, not
  a project-wide role.
