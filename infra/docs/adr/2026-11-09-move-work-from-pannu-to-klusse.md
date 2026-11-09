# Move work from pannu to klusse without waiting for contention, and keep KubeVirt

- Status: accepted
- Date: 2026-11-09
- Supersedes: [the agent VM placement ADR](2026-11-08-agent-vm-placement.md)
- Related: [ADR 7](0007-amp-orbs-on-klusse.md),
  [ADR 11](0011-replace-flannel-with-cilium.md),
  [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the runner model ADR](2026-11-09-one-runner-per-managed-thing.md),
  [the orb shipping ADR](2026-11-09-orb-shipping-guardrail-ladder.md)

## Context

The placement ADR moves the agents VM from pannu to a KubeVirt VM on w2 only
once contention on pannu is measured, and removes KubeVirt until then. #336
added the measurement: node-exporter on pannu, the agent VMs' vCPU steal, and
alerts for steal, memory pressure and OOM kills.

Since then:

- The runner model ADR retires the agents VM after T3, so moving it is moot.
- pannu still carries gaming (Jovian, Sunshine), the ops VM, builds for other
  hosts and for the pre-merge verification of the orb shipping ADR, the binary
  cache (`agent-cache-warm` and harmonia), and nginx for owui and Bambuddy. A
  reboot or a switch of pannu takes all of them down together.
- The workers are mostly idle: on 2026-11-08, w1 used 4 % CPU and 22 % memory,
  and w2 0 % CPU and 13 % memory (the placement ADR's table).
- Heavy work and VM tests don't fit small orbs, and nothing is built in orbs.
  KubeVirt is still installed (v1.9.1, no VMs).

## Decision

- **Work moves from pannu to klusse proactively.** There is no contention
  trigger; each move is its own change once its pieces are ready.
- **KubeVirt stays in klusse** to run heavy work and VM tests. Its removal is
  dropped, along with the `infra/TODO.md` item. The support-container CPU
  limits in `infrastructure/configs/kubevirt.yaml` stay.
- **Candidates to move:**
  - **Builds:** a klusse builder on w1, including the `flake.lock` verification
    builds that run on the pannu runner until it exists.
  - **The binary cache:** served from klusse and signed with a key in a
    SOPS-encrypted Secret, so hosts and runners trust a key instead of the
    network. ops' own cache stays on pannu (below).
  - **nginx for owui and Bambuddy:** their sites become Traefik routes. The
    services they front stay on pannu unless they move in their own change.
  - **VM tests:** run in klusse with KVM from KubeVirt. KubeVirt's device plugin
    advertises `devices.kubevirt.io/kvm`, so a builder pod can request
    `/dev/kvm` as a resource instead of running privileged; whether the
    `restricted` Pod Security level still admits it is checked with the
    builder.
- **What stays on pannu:** gaming, the ops VM, ops' cache and the pannu runner.
  ops is the way in when klusse is down, so its deployments must not depend on
  a cache in the cluster (the runner model ADR and the replaced ADR's
  decision 4).
- **#336's steal metrics and alerts no longer gate anything.** They stay until
  a later cleanup trims them; the agents VM they measure retires after T3.

## Consequences

- Moved work stops when klusse is down instead of when pannu is down. ops and
  its cache stay independent of the cluster.
- KubeVirt's webhooks stay among the gates of the Cilium cutover (ADR 11), and
  its pods keep using about 1.5 GiB of memory across the workers.
- The builder adds a signing key to the cluster, and anything that can read the
  builder namespace's Secrets can sign cache entries that hosts trust.
- Each move needs its own plan: where the builder's store lives on w1, which
  hosts trust the new cache key, and the Traefik routes and certificates for
  the nginx sites.
