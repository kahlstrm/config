# cilium-l2

```sh
nix develop .#talos --command just talos run cilium-l2
```

Runs the [cilium-migration](../cilium-migration/README.md) cutover, then
measures the LoadBalancer address from the host while the node announcing it
fails, first with production's MetalLB in L2 mode on Cilium with kube-proxy
replacement, then with Cilium's LB IPAM and L2 announcements. The web
Service has a backend on each worker.

For each, two failures of the node that answers ARP for the address on the
host (`ip neigh`, matched to the VMs' MAC addresses):

- **-reboot**: `talosctl reboot`, which drains nothing but stops services in
  order.
- **-freeze**: the VM's QEMU process is stopped for 60 seconds, as a power
  loss or a hang would silence it, then resumed.

Each step records the outages, waits for every signal and asserts the local
volume's data afterwards.

Between them:

1. **cilium-l2-config**: replace the inline manifest with one that adds
   [values.yaml](values.yaml) (`l2announcements`, `externalIPs`, a higher
   client rate limit) and run `upgrade-k8s`; asserts that MetalLB still serves
   the address without disruption.
2. **switch**: delete MetalLB's HelmRelease, which uninstalls it, then apply
   [cilium-l2.yaml](../../manifests/cilium-l2.yaml): MetalLB's pool and
   L2Advertisement as a `CiliumLoadBalancerIPPool` and a
   `CiliumL2AnnouncementPolicy` for the workers. Records whether the Service
   keeps its address and how long it is unreachable.
