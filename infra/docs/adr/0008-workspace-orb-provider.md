# 8. Run the katalyst workspace's orbs on klusse beside the personal ones

- Status: accepted
- Date: 2026-10-29

## Context

[ADR 7](0007-amp-orbs-on-klusse.md) runs orbs from a personal orb provider and
defers a workspace provider for shared use. Members of the `katalyst` workspace
should now be able to start orbs on klusse with their own Amp subscriptions.

## Decision

- **The workspace gets its own provider, `klusse`, in the namespace
  `amp-orbs-katalyst`.** It reuses `apps/amp-orbs/kubevirt` as a Kustomize
  base, so both providers run the same dispatch program, orb image and
  internet-only NetworkPolicy, and differ only in namespace, token and quota.
- **Its quota is half the personal one**, two running VMs and ten orbs' disks,
  so members' orbs cannot take the capacity the operator's orbs need.
- **Its token lives in Secret Manager as `amp_orb_provider_katalyst`**, next to
  the personal provider's token.

## Consequences

- Workspace orbs reach no private address, as personal orbs do. Runners stay
  personal, so members cannot hand work to the operator's runners.
- The namespace runs its own image pre-pull DaemonSet, because the dispatch
  program reads it from its own namespace. The image is stored once per node.
