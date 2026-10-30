# cilium-terraform-abort

```sh
nix develop .#talos --command just talos run cilium-terraform-abort
```

The cluster of [cilium-terraform](../cilium-terraform/README.md), three
control planes and two workers through production's talos-cluster module,
abandons the cutover after the first control plane's apply twice and rolls
back with Terraform:

1. **broken-first-controlplane**: `cni = "cilium"` with a Cilium manifest
   rendered from production's values plus `k8sServicePort: 7446`, where
   KubePrism does not listen, applied to `c1` only. The ready gate must fail
   within four minutes. Since the agents fail in their first init container,
   before they touch a node's network, the step asserts that no signal was
   down for more than 30 s; an agent that took over would cut pods off for
   minutes. Load on the CI runner alone has delayed signals by up to 11 s.
2. **broken-rollback-…**: `cni = "flannel"` applied to `c1`; every control
   plane must render Flannel again; the `upgrade-k8s` dry run must prune
   Cilium and nothing of Flannel, and the real run delete it. Without
   rebooting, a new pod must start on each worker, then every signal must be
   up, Flannel's policies must block policed pods at +3 s, and the plan must
   have no changes.
3. **partial-first-controlplane**: production's Cilium applied to `c1` only.
   The ready gate passes; the step waits 20 seconds, as an operator deciding
   to abort would, and records the outages while pods have lost Flannel's
   network.
4. **partial-rollback-…**: as step 2, then each node rebooted with the etcd
   gate before and after each control plane; asserts that no node has
   anything of Cilium left, the data is intact and every signal is up.
