# Run one rustfs server on w2 for the Katalyst proof of concept

- Status: accepted
- Date: 2026-11-21
- Related: [the compute runners ADR](2026-11-14-temporary-compute-runners.md),
  [the private secrets repository ADR](2026-11-11-secrets-in-a-private-sops-repository.md)

## Context

The Katalyst proof of concept stores each thread's state in S3 and needs an
object store with conditional writes (`If-None-Match`, `If-Match`) that its
checks can run against from the compute runners, rather than one started on
the runner itself. Its design later adds an STS-style issuer that creates one
rustfs user per thread with an admin credential, so that revoking a thread
revokes one user.

The compute runners reach only public HTTP and HTTPS and two public DNS
resolvers. Their NetworkPolicy, their guest firewall and a boot-time isolation
check all keep private addresses out, and they cannot resolve cluster names.

Each worker has one `local-storage` disk. w2's 1 TB disk was 2 % used on
2026-11-08 ([the agent VM placement ADR](2026-11-08-agent-vm-placement.md)),
and w1's holds klusse-w1's 300 GiB of claims. w2's second NVMe disk
still carries the unmanaged partition the removed orbs left behind, which only
a `local-talos` apply from a maintainer's machine could turn into a volume.

## Decision

- **rustfs 1.0.6**, the current stable release, as plain manifests in
  `apps/rustfs`, not the upstream chart: the chart cannot fix the Service's
  address and always exposes the console port.
- **Single node, single disk.** One pod with one 100 GiB claim on w2's
  `local-storage` disk, pinned to w2 beside klusse-w2. Distributed mode spreads
  erasure-coded drives over pods, but klusse has two workers with one data disk
  each, so it would add pods without surviving a worker's loss, and the proof
  of concept's data is disposable. Objects have no parity: losing w2's disk
  loses them, and there is no backup.
- **No new Talos volume.** The existing `local-storage` disk needs no apply;
  the leftover NVMe stays unused.
- **A fixed address instead of a name.** The Service takes the ClusterIP
  `10.96.0.20` from the service range's static band, which automatic
  allocation leaves alone, so the endpoint is `http://10.96.0.20:9000` without
  cluster DNS. It is plain HTTP: klusse-w2's traffic and the setup Job's stay
  on w2, while klusse-w1's crosses the LAN unencrypted; S3's signatures
  authenticate each request.
- **Only the S3 port is opened**: the compute runners' NetworkPolicy allows
  the rustfs pod on TCP 9000, their guest firewall the ClusterIP on 9000
  (`local.klusseRunner.allowedPrivate`), and rustfs's own policy admits only
  the compute runners and its namespace. The isolation check is unchanged: it
  bypasses the guest firewall, and none of its private targets is opened.
- **One bucket, `katalyst-poc`, and one user of the same name** whose policy
  allows `s3:*` on that bucket and its objects only. The `rustfs-setup` Job
  creates both with the root credential; Flux recreates it within about two
  hours of its last run, undoing drift.
- **Credentials are SOPS-encrypted Secrets in this repository**, which is what
  the cluster decrypts today; they move with the cluster's other secrets to the
  private repository. The root credential is `rustfs-admin` in the `rustfs`
  namespace, where the later issuer runs and reads it. The scoped key reaches
  klusse-w2 as the Secret disk `katalyst-s3`, mounted at
  `/run/katalyst-s3/env` as shell exports, so it is never pasted anywhere.

## Consequences

- klusse-w2 sees the key after its next restart with an image built from this
  change. Threads on it have root, so any of them can read the key and use the
  bucket, as they can read the Amp token.
- Changing the address means changing the Service, the guest firewall's
  default and the published endpoint together.
- An issuer outside the `rustfs` namespace, or other clients, need rustfs's
  NetworkPolicy extended. Durable data needs a backup or a distributed setup
  first.
