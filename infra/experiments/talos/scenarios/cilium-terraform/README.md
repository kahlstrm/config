# cilium-terraform

```sh
nix develop .#talos --command just talos run cilium-terraform
TALOS_LAB_CONTROL_PLANES=1 nix develop .#talos --command just talos run cilium-terraform
```

Provisions a cluster shaped like production, three control planes behind an
API VIP and two workers, through production's
[talos-cluster](../../../../modules/talos-cluster) module instead of
talosctl's configs. It then switches the cluster to Cilium and back with the
module's `cni` setting and the gated runbook: one Terraform apply per node and
a gate after each phase.

talosctl's QEMU provisioner boots the nodes without a config
(`--skip-injecting-config`), so they wait in maintenance mode like new
production nodes. [terraform/main.tf](terraform/main.tf) applies the module to
them with local state under the run directory: the module's CNI patches and
the Cilium manifest, production's patches that suit QEMU VMs, the API VIP
template with `10.5.0.10` and the user volume template with the workers'
second disk, and the lab's own patches (Flux without sync, no NTP). The
installer is production's worker installer from the Image Factory. The nodes
are `c1` to `c3` and `w1`, `w2`. The kubeconfig points at the VIP, so the
monitor's `api` signal is the API as production's clients see it. The rest
of the platform, the probers and the monitor are those of the
[CNI migration scenarios](../../README.md#cni-migration-scenarios).

Control planes get 2 GiB of RAM and workers 3 GiB, 12 GiB in all, so the
cluster fits a 16 GiB CI runner; `results.txt` records each node's memory use
on Flannel and on Cilium. `TALOS_LAB_CONTROL_PLANES` and
`TALOS_LAB_CONTROL_PLANE_MEMORY` override the defaults.

The gates (in [gates_test.go](../../gates_test.go)) wait for their condition
and fail the run if it does not hold:

- **agents**: a Ready Cilium agent on every node whose `cilium-dbg status
  --brief` is `OK`, and the operator available.
- **endpoints**: every CiliumEndpoint `ready`.
- **traffic**: a fresh pod on every node, control planes included, resolves
  cluster DNS and reaches the echo pod on `c1` and its Service.
- **manifests**: every control plane renders the same Talos manifests, with
  the selected CNI's (`99-cilium`, or `05-flannel` and `10-kube-proxy`)
  identical and the other's absent.
- **etcd**: every member up without errors and agreeing on one leader.

Steps:

1. **flannel-probes**: with `cni = "flannel"`, the netpol-baseline probes:
   ADR 4's first-packet window, blocked external connections at +3 s, and the
   policy shapes. A plan afterwards must have no changes. Gates: etcd,
   manifests (Flannel).
2. **tf-first-controlplane**: set `cni = "cilium"` and apply `c1` alone
   (`-target=module.cluster.talos_machine.controlplane["c1"]`). Talos installs
   Cilium on every node at once, and each node's pods lose their Flannel
   network as its agent starts. Gate: agents.
3. **recreate-pods**: [cni-pods](../../cmd/cni-pods) recreates every pod left
   on Flannel's network through its owner (see
   [Recreating pods](../../README.md#recreating-pods-after-the-switch)), after
   checking that its two ways of finding them agree. Gates: endpoints,
   traffic; then every monitored signal up and the volume's data intact.
   `results.txt` records the outages from step 2 to here.
4. **tf-other-nodes**: apply `c2`, `c3`, `w1` and `w2`, each on its own.
   Asserts that Flannel and kube-proxy still run. Gate: manifests (Cilium).
5. **upgrade-k8s**: gate etcd; the dry run must prune Flannel's and
   kube-proxy's DaemonSets and nothing of Cilium; then the real run must
   delete them. Gates: agents, cni-pods finds nothing left, traffic.
6. **cutover-vip-holder-…**, **cutover-etcd-leader-…**, **cutover-reboot-…**:
   reboot the control plane holding the VIP, then the etcd leader, moving
   leadership off the VIP holder first if one node has both, then the other
   control plane and each worker. Before and after each control plane, the
   etcd gate, so two members stay healthy; after each node, every workload.
   Asserts that no node has anything of Flannel left.
7. **cilium-steady**: every signal up, first-packet enforcement for fresh
   pods, and a plan without changes.
8. **rollback-config**, **rollback-upgrade-k8s**, **rollback-reboot**,
   **rollback-steady**: `cni = "flannel"` applied to every node, control planes
   first; gate manifests (Flannel) and wait for Talos to recreate Flannel and
   kube-proxy; gate etcd, then the `upgrade-k8s` dry run must prune Cilium and
   nothing of Flannel, and the real run delete it; reboot each node with the
   etcd gate, waiting for the node and Flannel only, as pods whose network
   Cilium set up recover only when their own node reboots. Then asserts that
   no node has anything of Cilium left, every signal is up, Flannel's
   policies block policed pods at +3 s, and the plan has no changes.

Every apply must change only its target. Control planes go first because a
worker's `talos_machine` depends, through the kubeconfig and the etcd
bootstrap, on every control plane's: targeting a worker also applies any
pending control-plane change.

For every apply, `results.txt` records how long it took, the kube-system
DaemonSets right after it, and which nodes rebooted by the end of the step.
The Terraform output of each apply is kept as `terraform/apply-*.log`.

[cilium-terraform-abort](../cilium-terraform-abort/README.md) rehearses
abandoning the cutover after the first control plane.
