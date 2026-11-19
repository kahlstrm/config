# Run self-hosted orbs as Docker containers in a runner VM

- Status: accepted; the first thread on the provider `klusse-w1` is its proof
- Date: 2026-11-19
- Supersedes: [ADR 7](0007-amp-orbs-on-klusse.md), whose lessons still apply
- Related: [the compute runners ADR](2026-11-14-temporary-compute-runners.md),
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md)

## Context

[ADR 7](0007-amp-orbs-on-klusse.md) ran self-hosted orbs on klusse and was
abandoned for three reasons. Two no longer hold: Amp has a Linux app, and
Amp-hosted orb credits ran out, so threads cannot start or resume orbs there.
The compute runners stand in for orbs since then.

The third reason, that provisioning orbs was a large job, came from one choice:
a KubeVirt VM per orb, built from Amp's container image. That needed a bootable
image built in CI and pulled before each spawn, hibernation with six guest
fixes, two claims per orb on a dedicated Talos volume, and memory reserved per
orb on the node that held its disks.

Amp now documents a Docker dispatch program, and its image starts as a plain
container: under Docker on 2026-11-19, `amp orb bootstrap` ran and stopped only
for lack of a token. Under gVisor it never started. Self-hosted orbs are free on
the account's plan. Amp's Helm chart still supports only GKE, EKS and AKS.

Orbs as plain pods were considered. They would put root-run agent code on the
workers' own kernel, could not run Docker without a privileged pod, and
Kubernetes cannot stop a pod and keep its filesystem.

## Decision

- **An orb is a Docker container in the `klusse-w1` compute runner VM**
  (`local.klusseRunner.orbs`, `modules/klusse-runner/orbs.nix`). `amp orb
  provider` runs there and starts the dispatch program for each job: `spawn`
  creates or starts the container and runs `amp orb bootstrap` in it, `pause`
  stops it, `delete` removes it. No machine is created per orb.
- **Pausing keeps files, not processes.** There is no hibernation. Terminal
  sessions and services in an orb end when it pauses.
- **The VM provisions the provider.** On its first start the service runs
  `amp orb provider create klusse-w1` with the account's Amp access key, which
  the runner there already uses, and makes the provider the account's default
  orb. The provider's token stays in the service's state directory on the VM's
  claim; no secret is added to the cluster.
- **Orbs are privileged containers**, so Docker and KVM work in them. Root in
  an orb is root in the VM, as for the runner's threads. The boundary stays the
  VM and the namespace's internet-only NetworkPolicy, which the VM checks at
  each boot before the provider starts.
- **Docker's data has its own claim**, the disk `orbs`, so orbs cannot fill the
  runner's `/nix` and `/home`. KubeVirt backs a claim with a disk image of its
  size, which caps what orbs use on the worker's disk. The disk is XFS with
  project quotas, and each orb may add 30 GiB to its image.
- **Each orb may use 4 CPUs and 8 GiB.** These are limits; nothing is reserved
  per orb. The VM grows to 12 vCPUs and 20 GiB, what w1 can spare.
- **Amp's image is used as published**, pulled daily so no spawn waits for it.
  Project snapshots are local images made with `docker commit`.
- **Stopped orbs are removed after 30 days**, with the images no orb uses,
  because Amp sends no `delete` for an archived thread.

## Consequences

- An orb's processes do not survive a pause, which ADR 7's orbs kept.
- Orbs share the VM's kernel and are separated from each other only as
  containers. A workspace provider for other people's threads would need its
  own VM.
- A thread in an orb can read the account's Amp access key and the provider's
  token in the VM, and act as the account.
- All orbs live on one VM on w1. They stop while it restarts, and are lost with
  its `orbs` claim; work is kept by pushing it.
- If the provider's saved token is lost, the service cannot create a provider
  of the same name. Deleting `klusse-w1` under Settings → Orbs in Amp lets the
  next start create it again.
- Orbs and the runner's threads share the VM's CPUs and memory. Several busy
  orbs at their limits exceed 20 GiB, and the guest then kills processes.
- A thread whose orb was removed after 30 days starts from the image again,
  and Amp sets its repository up anew. A project snapshot that old and unused
  is removed too, and new threads then run setup until Amp saves another.
- Threads, prompts and the output of orb work go through Amp's servers, as
  before.
