# Talos lab

Disposable Talos clusters on QEMU for testing cluster-level changes, such as
the CNI and NetworkPolicy enforcement, before they reach `klusse`. Each
scenario boots one control plane and one or two workers, runs its checks and
destroys the cluster.

The lab consumes production configuration instead of copies of it:

- Talos and Kubernetes versions from
  [local-talos/versions.json](../../local-talos/versions.json). Nix fetches that
  Talos release's `talosctl`, kernel and initramfs in [assets.nix](assets.nix);
  a Talos bump needs its hashes there.
- The machine-config contract version (`talos_config_version`) from
  [local-talos/main.tf](../../local-talos/main.tf), so configs have production's
  style.
- Production patches from [local-talos/patches](../../local-talos/patches):
  `metrics-*`, `openebs-controlplane` and `containerd-worker` in every scenario,
  and the [talos-cluster module's CNI patches](../../modules/talos-cluster/cni)
  for the scenario's starting CNI, as production's `cni` setting adds them.
  `openebs-worker` (2 GiB of hugepages and a Mayastor mount), `nvidia-worker`
  and the templates (install disk, hostname, API VIP, service-account issuer,
  user volumes) configure hardware or identity the lab lacks, except that the
  [CNI migration scenarios](#cni-migration-scenarios) render the user volume
  template for a lab disk.
- Cilium from [local-talos/cilium](../../local-talos/cilium): scenarios that
  install production's Cilium use the committed
  [manifests/cilium.yaml](../../local-talos/manifests/cilium.yaml) as is.
  Scenarios that change Cilium render the pinned chart, or the older release
  in [assets.nix](assets.nix), with production's values followed by their own
  additions. No lab-only Cilium values are needed.
- For the CNI migration scenarios, the Flux Operator and `FluxInstance` from
  [local-talos/flux.tf](../../local-talos/flux.tf) without the `FluxInstance`'s
  `sync`, so Flux runs as in production but does not reconcile this
  repository, and production's OpenEBS, MetalLB and `local-storage`
  manifests from local-kubernetes.
- The netpol canary's probe image and its `pod-network-only` policy from
  [local-kubernetes](../../local-kubernetes/platform/netpol-canary).

[patches/lab.yaml](patches/lab.yaml) is the only lab-only patch every scenario
uses: it disables NTP, which some hosts block. The other files in
[patches](patches) change a running cluster's CNI as the Terraform patches
would.

## Running

Requires x86_64 Linux, `/dev/kvm`, passwordless `sudo` (talosctl's QEMU
provisioner creates a bridge and runs the VMs as root), about 6 GiB of free
RAM (10 GiB for the CNI migration scenarios), 4 GiB of free disk (8 GiB) and HTTPS access to GitHub, container registries and
`1.1.1.1:80`. From `infra/`:

```sh
nix develop .#talos --command just talos run netpol-baseline
nix develop .#talos --command just talos run cilium
```

`just talos run SCENARIO` runs `go test` with the `integration` build tag and a
110-minute timeout, then destroys any cluster an interrupted run left behind
(`just talos cleanup` does only the latter). The Nix shell pins `talosctl`,
QEMU, kubectl, Helm, Go and the Cilium charts.

Every command gets the run's own `KUBECONFIG` and `TALOSCONFIG`; the caller's
are removed from its environment, and `talosctl cluster create` runs with
`--skip-kubeconfig`, so a run cannot touch another cluster's configuration.

Each run keeps its evidence under `$XDG_STATE_HOME/talos-lab/<scenario>/<run>/`
(default `~/.local/state`): `results.txt` with every probe's log and summary,
for the CNI migration scenarios `samples.txt` with every monitor sample and
the `upgrade-k8s-*.log` outputs, `create.log`, the VM console logs and the run's talosconfig and kubeconfig.
VM disks are sparse and deleted with the cluster.

Fast tests need no KVM:

```sh
nix develop .#talos --command go -C experiments/talos test -count=1 ./...
```

## Scenarios

Both scenarios measure first-packet enforcement with fresh probe pods that
run like the netpol canary: busybox, the restricted Pod Security profile and
no service-account token. Each probe connects, as its first action, to
`1.1.1.1:80` (external) and to an echo pod on the control plane (allowed,
cross-node), and again at +1 s and +3 s. Ten probes run in `np-control`, which
has no policy, and ten in `np-policed`, whose policy allows only the pod
network and cluster DNS. The allowed echo pod connecting from the first packet
shows that a blocked external connection is the policy, not a pod network that
is not ready yet.

Both run the **packet-socket check**: probes in `np-allow`, whose policy also
allows `1.1.1.1:80`, and in `np-policed` while a privileged hostNetwork pod
holds a node-wide `ETH_P_ALL` packet socket on the worker, once with
`tcpdump -i any` and once with a socket read without a ring, as FRR's `bfdd`
reads its own
([ADR 2](../../docs/adr/0002-no-node-wide-packet-sockets-under-network-policies.md)).

Both also run the **policy shape check**: three probes each under the
production `pod-network-only` policy (`ipBlock: 10.244.0.0/16`) and under the
same policy rewritten to `to: [{namespaceSelector: {}}]`, five seconds after
start. They connect to the echo pod, its ClusterIP Service, cluster DNS and
the external address.

- [netpol-baseline](scenarios/netpol-baseline/README.md): production's stack,
  Talos Flannel with its kube-network-policies sidecar and kube-proxy.
- [cilium](scenarios/cilium/README.md): Cilium replacing Flannel,
  kube-network-policies and kube-proxy, installed at bootstrap through
  `cluster.inlineManifests`.

## CNI migration scenarios

These rehearse moving production from Flannel, kube-network-policies and
kube-proxy to Cilium, and the alternatives around it. Each starts a control
plane and two workers, each worker with a second, sparse disk that
production's `local-storage` user volume template selects by serial. Unless
the scenario says otherwise, the cluster runs production's stack (as
netpol-baseline), and the test adds:

- Flux from the production bootstrap patch, without sync, then production's
  OpenEBS and MetalLB HelmReleases, the `local-storage` StorageClass and the
  MetalLB pool, with its range moved to the lab's `10.5.0.200-10.5.0.220`.
- [manifests/migration.yaml](manifests/migration.yaml): a LoadBalancer Service
  like Traefik's, with a backend on each worker, and a pod whose
  `local-storage` volume holds known data that the test checks after
  disruptive steps.
- In `mig-policed`, the netpol canary's `pod-network-only` policy rewritten to
  `namespaceSelector: {}`, which both stacks enforce alike.
- [Probers](manifests/prober.yaml) on each worker in `mig-control` (no policy)
  and `mig-policed`, which every second check cluster DNS, the web Service, a
  web pod and the external address, and report each result to an HTTP sink
  the test runs on the host's bridge address. A policy allows the policed
  probers to reach the sink.
- A privileged [node shell](manifests/node-shell.yaml) for reading what each
  CNI leaves on a node and for killing node processes.

A monitor also checks the API every second and the LoadBalancer address from
the host every 250 ms. The test names each step, and `results.txt` ends with
a table of each signal's longest outage per step, which includes up to one
sampling interval, and how often a policed prober reached the external
address. Pods restarted on the same node keep their prober's signal.

Hard failures freeze a VM by stopping its QEMU process (`SIGSTOP`), which
silences it at once as a power loss or a hang would, then let it run again
(`SIGCONT`). Killing QEMU would also end talosctl's launcher, which does not
start the VM again.

- [cilium-migration](scenarios/cilium-migration/README.md): the cutover to
  Cilium owned by Talos through an inline manifest, step by step.
- [cilium-upgrade](scenarios/cilium-upgrade/README.md): a values change and a
  patch release of Talos-owned Cilium.
- [cilium-helm-handover](scenarios/cilium-helm-handover/README.md): Flux takes
  over Cilium after the cutover; what later `upgrade-k8s` runs do to it.
- [cilium-l2](scenarios/cilium-l2/README.md): LoadBalancer failover with
  MetalLB's L2 mode on Cilium, and with Cilium's L2 announcements instead.
- [cilium-rollback](scenarios/cilium-rollback/README.md): back to production's
  stack from the middle of the cutover and from its end.
- [cilium-failures](scenarios/cilium-failures/README.md): a worker reboot
  during the cutover, and a node whose Cilium agent is removed or killed.
- [netpol-frr](scenarios/netpol-frr/README.md): production's stack with
  MetalLB's FRR mode, which ADR 2 blames for dropped egress.

## Host notes

- On NixOS, the `nixos-fw` INPUT chain drops DHCP, DNS and config-server
  traffic from the lab bridge. The lab inserts
  `-i talos+ -m comment --comment talos-lab -j nixos-fw-accept` for the run and
  removes it on teardown. Hosts without `nixos-fw` are left alone.
- Teardown destroys the cluster, removes that rule and the iptables rules and
  chains the provisioner and its CNI plugins added (comparing with a snapshot
  from before the run), and deletes the VM state. If `talosctl cluster destroy`
  fails, it kills the cluster's QEMU and talosctl helper processes and deletes
  the bridge itself. It then fails the test if a lab process, a `talos*` link
  or one of those rules remains. It runs on test failure too; if the test
  binary itself is killed, the `run` command's sweep does the same.
- QEMU's monitor socket paths must stay under 108 bytes, so talosctl gets the
  state directory through a short symlink in `/tmp`.
- One lab runs at a time per state directory; clusters use `10.5.0.0/24`. The
  CNI migration scenarios' sink listens on `10.5.0.1:18080`.
- Kernel assets are amd64 only, so the `talos` dev shell exists only on
  `x86_64-linux`.

## CI

[talos-lab.yml](../../../.github/workflows/talos-lab.yml) runs the fast tests
and each scenario as its own job on `ubuntu-24.04` runners with KVM, for pull
requests that touch the lab or the production configuration it consumes
(versions, `main.tf`, patches, the Cilium pin and render, the netpol canary), and on manual dispatch. It
keeps `results.txt`, `samples.txt`, the `upgrade-k8s` logs, `create.log` and
the VM console logs as artifacts; the run's talosconfig and kubeconfig stay on
the runner.

The CNI migration scenarios take 15 to 40 minutes on the agent VM's 8 CPUs,
longer than a pull request job's 20 minutes on a 4-CPU runner, so they run
only when the workflow is dispatched with a `scenario` (one, or `all`), each
as its own job with a 120-minute limit.
