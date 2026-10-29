# cilium-rollback

```sh
nix develop .#talos --command just talos run cilium-rollback
```

Rolls a cluster back from Cilium to production's Flannel,
kube-network-policies and kube-proxy twice:

- **mid-migration**: after the [cilium-migration](../cilium-migration/README.md)
  config changes and `upgrade-k8s`, before any pod was recreated, so Flannel's
  pods have lost their network.
- **completed**: after the whole cutover, including the reboots.

Each rollback:

1. **-config**: patch the workers with
   [flannel-worker.yaml](../../patches/flannel-worker.yaml) and the control
   plane with [flannel-controlplane.yaml](../../patches/flannel-controlplane.yaml)
   and [remove-cilium.yaml](../../patches/remove-cilium.yaml), as restoring
   production's Terraform patches would. Waits for Talos to recreate Flannel
   and kube-proxy, which it does without `upgrade-k8s`.
2. **-upgrade-k8s**: asserts that `upgrade-k8s` deletes Cilium, waits for its
   agents to go and records the outages.
3. **-restart-pods** (mid-migration only): records each node's leftovers and
   whether a new pod starts without a reboot. Cilium's CNI config stays first
   in `/etc/cni/net.d` and Flannel's stays renamed, so the kubelet keeps
   calling Cilium's plugin, which fails without its agent.
4. **-reboot**: reboots the control plane, then each worker, waiting between
   nodes only for the node and Flannel: pods whose network Cilium set up
   recover only when their own node reboots. Then waits for every workload and
   asserts that no node has anything of Cilium left: links, routes, CNI config
   or `lxc` interfaces.
5. **-steady**: asserts that every signal is up and that kube-network-policies
   blocks fresh policed pods' external connections three seconds after they
   start (ADR 4's window still applies to their first packets).
