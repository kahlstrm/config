# cilium-terraform

```sh
nix develop .#talos --command just talos run cilium-terraform
TALOS_LAB_CONTROL_PLANES=3 nix develop .#talos --command just talos run cilium-terraform
```

Provisions the cluster through production's
[talos-cluster](../../../../modules/talos-cluster) module instead of
talosctl's configs, then switches it to Cilium and back with the module's
`cni` setting, as production's cutover would.

talosctl's QEMU provisioner boots the nodes without a config
(`--skip-injecting-config`), so they wait in maintenance mode like new
production nodes. [terraform/main.tf](terraform/main.tf) applies the module to
them with local state under the run directory: the module's CNI patches and
the Cilium manifest, production's patches that suit QEMU VMs, the API VIP
template with `10.5.0.10` and the user volume template with the workers'
second disk, and the lab's own patches (Flux without sync, no NTP). The
installer is production's worker installer from the Image Factory. The nodes
are `c1` (to `c3`) and `w1`, `w2`. The rest of the platform, the probers and
the monitor are those of the
[CNI migration scenarios](../../README.md#cni-migration-scenarios).

One control plane by default, which fits a CI runner; three need about
15 GiB of RAM and 12 GiB of disk.

1. **flannel-probes**: with `cni = "flannel"`, the netpol-baseline probes:
   ADR 4's first-packet window, blocked external connections at +3 s, and the
   policy shapes. A plan afterwards must have no changes.
2. **tf-controlplanes**: set `cni = "cilium"` and apply each control plane
   on its own (`-target=module.cluster.talos_machine.controlplane["c1"]`),
   then wait for Cilium on every node. Talos installs Cilium from the first
   control plane's config.
3. **tf-workers**: apply each worker on its own. Asserts that Flannel and
   kube-proxy still run.

Every apply must change only its target. Control planes go first because a
worker's `talos_machine` depends, through the kubeconfig and the etcd
bootstrap, on every control plane's: targeting a worker also applies any
pending control-plane change.

4. **upgrade-k8s**, **restart-pods**, **rolling-reboot**, **cilium-steady**:
   the rest of the [cilium-migration](../cilium-migration/README.md)
   sequence, with its checks. A plan afterwards must have no changes.
5. **rollback-tf-controlplanes**, **rollback-tf-workers**: `cni = "flannel"`
   and the same applies, in the same order; waits for Talos to recreate Flannel and kube-proxy.
6. **rollback-upgrade-k8s**: asserts that `upgrade-k8s` deletes Cilium.
7. **rollback-reboot**, **rollback-steady**: reboots as
   [cilium-rollback](../cilium-rollback/README.md) does, asserts that no node
   has anything of Cilium left, that every signal is up, and that Flannel's
   policies block policed pods at +3 s. A plan afterwards must have no
   changes.

For every apply, `results.txt` records how long it took, the kube-system
DaemonSets right after it, and which nodes rebooted by the end of the step.
The Terraform output of each apply is kept as `terraform/apply-*.log`.
