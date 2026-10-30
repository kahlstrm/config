# cilium-terraform-abort

```sh
nix develop .#talos --command just talos run cilium-terraform-abort
```

The cluster of [cilium-terraform](../cilium-terraform/README.md), three
control planes and two workers through production's talos-cluster module,
abandons the cutover after the first control plane's apply three times and
rolls back with Terraform:

1. **broken-first-controlplane**: `cni = "cilium"` with a Cilium manifest
   rendered from production's values plus `k8sServicePort: 7446`, where
   KubePrism does not listen, applied to `c1` only. The agents fail in their
   first init container, before they touch a node's network. The ready gate
   must fail within four minutes, and no signal may be down for more than
   30 s; an agent that took over would cut pods off for minutes. Load on the
   CI runner alone has delayed signals by up to 11 s.
2. **broken-rollback-…**: `cni = "flannel"` applied to `c1`; every control
   plane must render Flannel again; the `upgrade-k8s` dry run must prune
   Cilium and nothing of Flannel, and the real run delete it. Without
   rebooting, a new pod must start on each worker, then every signal must be
   up, Flannel's policies must block policed pods at +3 s, and the plan must
   have no changes. This shows recovery only from a failure before takeover.
3. **mixed-first-controlplane**: production's Cilium applied to `c1`. Once
   the agent on the last worker has started, after its init containers set
   the node up, the test kills it every second through the node shell, while
   the other four nodes are taken over. The ready gate must fail.
4. **mixed-rollback-…**: the rollback of step 2, then every node rebooted,
   with the etcd gate before and after each control plane and, between nodes,
   only the node and Flannel awaited. A node whose agent was killed keeps
   Cilium's CNI config through its reboot, sorted before Flannel's, so no new
   pod starts there; the test removes it through the privileged node shell
   and records where it had to. Then asserts that no node has anything of
   Cilium left, the data is intact, every signal is up and the plan is empty.
5. **partial-first-controlplane**: production's Cilium applied to `c1`; the
   ready gate passes; the step waits 20 seconds, as an operator deciding to
   abort would.
6. **partial-rollback-…**: with `c2` and `c3` frozen, so etcd has no quorum
   and the Kubernetes API is down, `cni = "flannel"` is applied to `c1`
   through its Talos API. Then `c2` and `c3` resume, and once the API and etcd
   are back, the rest of step 4 follows.

Every `upgrade-k8s` waits for Ready nodes and the etcd gate, and runs again,
up to three times, if it fails. After it prunes Cilium, every rollback records
each node's taints and removes `node.cilium.io/agent-not-ready`: Cilium's
operator puts it on nodes whose agent is not ready
(`set-cilium-node-taints`), and nothing removes it once Cilium is gone, so no
new pod would be scheduled there.
