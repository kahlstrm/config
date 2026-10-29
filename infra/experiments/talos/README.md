# Talos lab

Disposable Talos clusters on QEMU for testing cluster-level changes, such as
the CNI and NetworkPolicy enforcement, before they reach `klusse`. Each
scenario boots one control plane and one worker, runs its checks and destroys
the cluster.

The lab consumes production configuration instead of copies of it:

- Talos and Kubernetes versions from
  [local-talos/versions.json](../../local-talos/versions.json). Nix fetches that
  Talos release's `talosctl`, kernel and initramfs in [assets.nix](assets.nix);
  a Talos bump needs its hashes there.
- The machine-config contract version (`talos_config_version`) from
  [local-talos/main.tf](../../local-talos/main.tf), so configs have production's
  style.
- Production patches from [local-talos/patches](../../local-talos/patches):
  `metrics-*`, `openebs-controlplane` and `amp-orbs-worker` in every scenario,
  and `network-policy-controlplane` where the scenario keeps Talos's Flannel.
  `openebs-worker` (2 GiB of hugepages and a Mayastor mount), `nvidia-worker`
  and the templates (install disk, hostname, API VIP, service-account issuer,
  user volumes) configure hardware or identity the lab lacks. The Flux
  bootstrap patch would make the lab reconcile this repository, so it is
  skipped too.
- The netpol canary's probe image and its `pod-network-only` policy from
  [local-kubernetes](../../local-kubernetes/platform/netpol-canary).

[patches/lab.yaml](patches/lab.yaml) is the only lab-only patch: it disables
NTP, which some hosts block.

## Running

Requires x86_64 Linux, `/dev/kvm`, passwordless `sudo` (talosctl's QEMU
provisioner creates a bridge and runs the VMs as root), about 6 GiB of free
RAM, 4 GiB of free disk and HTTPS access to GitHub, container registries and
`1.1.1.1:80`. From `infra/`:

```sh
nix develop .#talos --command just talos run netpol-baseline
nix develop .#talos --command just talos run cilium
```

`just talos run SCENARIO` runs `go test` with the `integration` build tag and a
40-minute timeout, then destroys any cluster an interrupted run left behind
(`just talos cleanup` does only the latter). The Nix shell pins `talosctl`,
QEMU, kubectl, Helm, Go and the Cilium chart.

Every command gets the run's own `KUBECONFIG` and `TALOSCONFIG`; the caller's
are removed from its environment, and `talosctl cluster create` runs with
`--skip-kubeconfig`, so a run cannot touch another cluster's configuration.

Each run keeps its evidence under `$XDG_STATE_HOME/talos-lab/<scenario>/<run>/`
(default `~/.local/state`): `results.txt` with every probe's log and summary,
`create.log`, the VM console logs and the run's talosconfig and kubeconfig.
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
- One lab runs at a time per state directory; clusters use `10.5.0.0/24`.
- Kernel assets are amd64 only, so the `talos` dev shell exists only on
  `x86_64-linux`.

## CI

[talos-lab.yml](../../../.github/workflows/talos-lab.yml) runs the fast tests
and each scenario as its own job on `ubuntu-24.04` runners with KVM, for pull
requests that touch the lab or the production configuration it consumes
(versions, `main.tf`, patches, the netpol canary), and on manual dispatch. It
keeps `results.txt`, `create.log` and the VM console logs as artifacts; the
run's talosconfig and kubeconfig stay on the runner.
