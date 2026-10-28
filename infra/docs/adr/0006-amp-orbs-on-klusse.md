# 6. Run Amp orbs on klusse, with LAN access only through runners

- Status: proposed
- Date: 2026-10-28

## Context

Agent threads should be stored in one place, and agents should decide
themselves when work needs another machine. Amp provides both: threads live at
ampcode.com, each thread can get an orb (a disposable machine), and an agent
can hand work to an orb or to a runner on a specific host through Agent to
Agent.

Self-hosted orbs run on our hardware. Amp's `amp orb provider` connects out to
Amp and runs a dispatch program for each `spawn`, `pause` and `delete` job.
Amp's Helm chart supports only GKE, EKS and AKS, because it stores paused orbs
in their object storage through their workload identity, so klusse needs its
own dispatch program.

Amp configures an orb as if it were Amp's Debian image: a trial with a NixOS
orb needed six fixes (a fixed `PATH`, a `user` group, `/bin/bash`, a writable
`/usr/local/bin` and more) and still cannot run Amp services, which Amp installs
into `/etc/systemd/system`. Orbs therefore use Amp's own image.

Amp's image is a container image without a kernel or init. It can run as a pod
or be made bootable for a VM; each choice limits the orb differently.

## Decision

- **Orbs run Amp's image on the workers w1 and w2**, from a personal orb
  provider in the operator's Amp account. Two variants are built and compared
  before one is kept:
  - **gVisor pods**: the image runs under the `gvisor` RuntimeClass, as in
    Amp's own chart. Docker is limited and there is no KVM.
  - **KubeVirt VMs**: the image plus a kernel and systemd boots as a VM. The
    orb gets full Docker and nested KVM, at the cost of KubeVirt and an image
    build.
- **Orbs get internet access only.** A NetworkPolicy denies private
  destinations, like the agent VM's network policy. Work that needs the LAN
  goes to an Amp runner on the host that has it; runners stay personal so
  workspace members cannot reach them.
- **Orb disks live on dedicated disks.** Each worker's spare NVMe becomes the
  `orb-storage` user volume, so orbs cannot fill the disk that holds
  Prometheus, Loki and Harbor. A paused orb resumes on the node that holds its
  disk.
- **The provider token is an internet-usable credential**, so it lives in
  Secret Manager and reaches the cluster through an `ExternalSecret`.

A workspace provider for shared use, such as a hackathon with others on their
own Amp subscriptions, is deferred. It would be a second provider with its own
namespace, quota and NetworkPolicy, and must not reach any runner.

## Consequences

- Workers carry the `siderolabs/gvisor` extension and `vm.max_map_count =
  4194304` even if the KubeVirt variant wins; remove them then.
- An agent in an orb can still start a thread on a personal runner through
  Agent to Agent, so runners need narrow users, narrow credentials and approval
  rules for risky commands. Network isolation of orbs does not limit what a
  runner does on an orb's behalf.
- Threads, prompts and the code context of orb work go through Amp's servers.
- Pausing keeps an orb's files but not its processes, unless the KubeVirt
  variant adds guest hibernation.
