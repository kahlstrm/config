# One runner per managed thing, with builds on runners and a klusse runner in a pod

- Status: accepted; the klusse runner and builder are not yet implemented
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
| pannu | pannu | `host-deploy` for pannu; for now also the pre-merge builds (see Builds) |
| zima, poenttoe | their own host | `host-deploy` for that host |
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
- **Orbs** get Amp OIDC only for things they can reach on the internet: GCP
  logs, metrics and narrow Secret Manager reads. Orbs get only secrets granted
  to them by name, and never these three (also in the ops runner ADR's
  required check):
  - `sops_age_key`, which decrypts every SOPS secret in the repository;
  - `local-kubernetes`, which holds the cluster's secrets, including the klusse
    runner's account-wide Amp key;
  - `local-networking`, which holds the RouterOS and Terraform credentials, so
    reading it would break the rule that orbs get no LAN access.

  Read-only LAN work goes to the runner that manages the
  thing, through a runner thread (see the orb networking ADR).
- **Cost:** every runner's Amp key acts as the whole account, so each new
  runner is one more account-wide key to protect. With five runners there are
  five keys, and the klusse runner's key sits in the cluster (see below), not
  on a host disk.

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

### Alert investigations

Phase 1 of the alert migration (Homelab alerts & incidents Space) starts its
investigation threads on the klusse runner, which uses `alert-investigator`,
instead of on pannu with a kubeconfig. pannu's runner gets no cluster
credentials.

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

- No host holds a cluster credential, and the klusse runner can't reach the
  cluster when the cluster is down; ops can.
- The klusse runner's account-wide key is in Secret Manager and in the
  cluster's etcd, so whoever can read Secrets in its namespace or the
  `local-kubernetes` secret can act as the whole Amp account.
- A thread on the klusse runner acts with `alert-investigator`'s rights from a
  pod on a worker, inside its NetworkPolicy. The ops runner ADR's required
  check covers that ServiceAccount instead of a reader identity on pannu.
- pannu's runner builds other hosts' configurations until a klusse builder
  exists, so its `amp` user needs Nix daemon access (the orb shipping ADR).
- The orb-side OIDC role for Secret Manager must name individual secrets, not
  a project-wide role.
