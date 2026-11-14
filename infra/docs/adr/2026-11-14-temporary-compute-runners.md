# Run temporary compute runners at home that work like orbs

- Status: accepted, implemented on pannu (`compute-pannu`); klusse's runners
  follow, w2 before w1
- Date: 2026-11-14
- Related: [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the runner model ADR](2026-11-09-one-runner-per-managed-thing.md),
  [the private secrets repository ADR](2026-11-11-secrets-in-a-private-sops-repository.md)

## Context

Repository work runs in Amp-hosted orbs, and their hours are nearly used up.
Home hardware has spare capacity, but the host runners are unprivileged on
purpose: no sudo, a read-only system and prompts for anything beyond Amp's
built-in rules. Threads that do repository work need what an orb gives them:
root in a disposable machine, no approval prompts, and a checkout they can make
worktrees of.

pannu already runs the agents VM: 8 cores, 32 GiB, 200 GiB on `/home`, with a
host firewall and passwordless root for its T3 agent.

## Decision

- **Compute runners stand in for orbs** until a better solution replaces them,
  with no set date.
- **On pannu, the runner lives in the agents VM** as its own user, `amp`, with
  runner ID `compute-pannu`, not in a new microVM. The VM keeps its network
  access unchanged.
- **It works like an orb.** `local.ampRunner.sudo` gives `amp` passwordless
  root and drops the service hardening that would stop sudo, and the runner
  allows every tool call without a prompt. The VM is the boundary.
- **It serves a workspace**, `/home/amp/workspace` on the VM's large volume.
  The runner clones `kahlstrm/config` there when the checkout is missing and
  serves the checkouts beneath it with `--discover-dirs`, so threads can create
  worktrees.
- **No GitHub credentials** for now; threads clone public repositories over
  HTTPS. A read-only deploy key is acceptable if one is needed.
- **The access key** is one per runner, created by a maintainer. On pannu, root
  writes it into `/var/lib/microvms/agents/amp-runner.token`, which the host
  creates empty and QEMU passes to the guest as the system credential
  `amp-runner.token`. The runner stays skipped while the file is empty, and
  reads a new key on the VM's next boot. It moves to the private secrets
  repository with pannu's other runner token.
- **klusse** gets the same kind of runner in a VM on worker w2 first, and on w1
  only after w2 is verified.

## Consequences

- With root in the agents VM, the runner's threads read that VM's credentials:
  the T3 agent's GitHub App key, the read-only cluster token and the Talos
  `os:reader` talosconfig. They also use its network exceptions: pannu's cache,
  the Kubernetes API, the Talos APIs and the ops link. The runner is not
  internet-only, unlike an orb.
- The T3 agent and the runner share the VM's CPU, memory and disks. Heavy
  builds on either slow the other, and the VM's 32 GiB limit applies to both.
- Commands and output from these threads are stored by Amp, as for any runner.
- Changing the credential file is part of the VM's host contract, so it needs
  pannu's deploy and a restart of `microvm@agents`, which ends T3 sessions.
