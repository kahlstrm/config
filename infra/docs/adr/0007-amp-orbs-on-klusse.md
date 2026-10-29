# 7. Run Amp orbs on klusse, with LAN access only through runners

- Status: abandoned
- Date: 2026-10-28

Orbs worked and using them in threads was good enough, but provisioning orb
VMs on our own hardware was a large job Amp leaves to us, Amp has no Linux
app, and we do not need it. The outcome below records what we learnt.

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

- **Orbs run Amp's image as KubeVirt VMs on the workers w1 and w2**, from a
  personal orb provider in the operator's Amp account. The image plus Debian's
  kernel and systemd boots as a VM, so an orb gets its own kernel, full Docker
  and nested KVM, at the cost of KubeVirt and an image build in CI.

  gVisor pods, the runtime of Amp's own chart, were built and dropped. Amp's
  setup never started in them (no `setup.log`, even for a thread without a
  repository), they cannot run Docker or KVM, and they need user namespaces,
  which Talos disables by default for every pod on the node.
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

- Workers keep Talos' defaults: no gVisor extension, user namespaces off.
- Orb VMs boot from a containerDisk image this repository builds from Amp's
  image, so a new Amp image reaches orbs only through a rebuild and a pinned
  digest.
- An agent in an orb can still start a thread on a personal runner through
  Agent to Agent, so runners need narrow users, narrow credentials and approval
  rules for risky commands. Network isolation of orbs does not limit what a
  runner does on an orb's behalf.
- Threads, prompts and the code context of orb work go through Amp's servers.
- Pausing keeps an orb's files but not its processes, unless guest
  hibernation is added.

## Outcome

Orbs reached production: about 15 s from spawn to a connected thread, also
right after an image change; pausing hibernated the VM and freed its memory,
keeping about 50 MB on disk; resuming took about 10 s with the orb's processes
still running. Real threads spawned, paused and resumed. Getting there took
these, none of which Amp's self-hosting covers:

- **Self-hosting means writing the platform.** Amp's chart supports only GKE,
  EKS and AKS. On klusse we wrote the dispatch program, built a bootable VM
  image from Amp's container image in CI, added a state disk with an overlay
  root, a swap disk for hibernation, an image pre-pull and an orb bench.
- **Amp assumes its Debian image.** A NixOS orb needed six fixes and still
  could not run Amp's services; Amp also writes `/etc`.
- **gVisor did not work.** Amp's setup never started, and pods cannot run
  Docker or KVM.
- **Keeping processes across a pause needs hibernation, and resuming a VM in a
  new KubeVirt pod broke in several ways.** libvirt shut the guest down
  through its agent instead of the power button; the q35 TCO watchdog reset the
  restored guest about 20 s later; ACPI left the power button disabled;
  kvm-clock stalled the guest for as long as it had run before the pause
  (fixed with the TSC clocksource and the RTC); logind fell back to suspend
  when hibernation was impossible; and the state disk was not synced at
  power-off.
- **KubeVirt's defaults were slow on klusse.** Its 15m and 10m CPU limits on
  support containers throttled their start to 10–20 s each, so any VM took
  34 s to start. Raising the limits (still in
  `infrastructure/configs/kubevirt.yaml`) brought a minimal VM to about 4.5 s.
  Recreating a VM under the same name waited about 9 s on virt-handler's
  cleanup backoff.
- **Local disks pin orbs to a node.** With full memory reservations, an orb
  could not resume while its node was full, even with room on the other
  worker.
- **The image is large.** A 1.4–1.8 GB containerDisk took 50–70 s to pull, so
  spawns had to keep the previous image until both workers had the new one.
- **Etcd timeouts on the control plane** occasionally delayed any pod's
  scheduling by 7–15 s.
