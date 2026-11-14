# Run temporary compute runners at home that work like orbs

- Status: accepted, implemented on pannu (`pannu-agents`); klusse's runners
  follow, `klusse-w2` before `klusse-w1`
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
  runner ID `pannu-agents`, named after its host and VM, not in a new microVM.
  The VM keeps its network access unchanged.
- **It works like an orb.** `local.ampRunner.sudo` gives `amp` passwordless
  root and drops the service hardening that would stop sudo, and the runner
  allows every tool call without a prompt. The VM is the boundary.
- **It serves a workspace**, `/home/amp/workspace` on the VM's large volume.
  The runner clones `kahlstrm/config` there when the checkout is missing and
  serves the checkouts beneath it with `--discover-dirs`, so threads can create
  worktrees.
- **No GitHub credentials** for now; threads clone public repositories over
  HTTPS. A read-only deploy key is acceptable if one is needed.
- **The access token** is the account's one Amp access token, which every
  runner shares; Amp has no token per runner, and a new one would sign out the
  others. On pannu it stays where pannu's own runner reads it,
  `/etc/credstore.encrypted/amp-runner.token`. Before each boot of the agents
  VM, `microvm@agents` imports it and copies it as root to
  `/run/agent-vm-credentials/agents/amp-runner.token`, readable by the VM's user
  only, which QEMU passes to the guest as the system credential
  `amp-runner.token`. Without it the file is empty and the runner stays
  skipped. A new token reaches the VM on its next boot. It moves to the private
  secrets repository with pannu's runner token.
- **klusse** gets the same kind of runner in a VM on worker w2 first, as
  `klusse-w2`, and on w1, as `klusse-w1`, only after `klusse-w2` is verified.
- **A klusse runner is a KubeVirt VM** with 8 vCPUs (a request of 1), 12 GiB
  reserved in full and a 100 GiB `local-storage` claim, in the
  `compute-runners` namespace. It boots a minimal NixOS guest
  (`machines/klusse-w2.nix`, `modules/klusse-runner`) from a containerDisk
  holding the kernel, the initrd and its store as an erofs image, which CI
  builds, boots and publishes as a tag of the public `amp-runner` package. The
  claim holds `/nix`, `/home`, `/var` and `/tmp`; each boot copies the image's
  store into it, as the agents VM's store does, so builds survive restarts.
  Nested KVM comes from the host CPU model. It reads the account's token from a
  Secret disk, from the same Secret Manager property as the klusse runner pod.
- **Its boundary is the namespace's NetworkPolicy**, since its threads have
  root: no inbound traffic, and outbound only TCP 80 and 443 to public
  addresses and DNS to two public resolvers, which the guest uses instead of
  the cluster's. A guest firewall allows the same, as a second layer that root
  can lift. A pod's traffic to its own node's address is policed: from a pod
  on w2, the node's kubelet and Talos ports timed out on its LAN address and
  its pod gateway.
- **The runner starts only after an isolation check**, on every boot: the
  check must reach the internet and must not reach the nodes, the Kubernetes
  API, Services, cluster DNS, the ingress address, the routers or pannu. It
  bypasses the guest firewall, so it tests the cluster's policy; a target that
  answers, even with a refusal, keeps the runner down.

## Consequences

- With root in the agents VM, the runner's threads read that VM's credentials:
  the T3 agent's GitHub App key, the read-only cluster token and the Talos
  `os:reader` talosconfig. They also use its network exceptions: pannu's cache,
  the Kubernetes API, the Talos APIs and the ops link. The runner is not
  internet-only, unlike an orb.
- The T3 agent and the runner share the VM's CPU, memory and disks. Heavy
  builds on either slow the other, and the VM's 32 GiB limit applies to both.
- Commands and output from these threads are stored by Amp, as for any runner.
- One token serves pannu's runner, `pannu-agents` and later the klusse
  runners. Revoking or regenerating it signs out all of them, and a thread
  with root in the agents VM reads it and can act as the Amp account.
- Changing the credential file is part of the VM's host contract, so it needs
  pannu's deploy and a restart of `microvm@agents`, which ends T3 sessions.
- A klusse runner's guest changes only with a new image: CI publishes it, a PR
  pins its digest, and the VM boots it on its next restart, for example after
  its virt-launcher pod is deleted. Its threads cannot reach pannu's cache, so
  builds download more than on pannu.
- Removing a klusse runner's disk needs a PR labelled `allow-destroy` and a
  manual delete of the retained volume on its node.
