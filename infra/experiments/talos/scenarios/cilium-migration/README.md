# cilium-migration

```sh
nix develop .#talos --command just talos run cilium-migration
```

Moves a cluster running production's stack (see
[CNI migration scenarios](../../README.md#cni-migration-scenarios)) to Cilium
that Talos owns through `cluster.inlineManifests`, as
[local-talos/flux.tf](../../../../local-talos/flux.tf) ships Flux. The inline
manifest is production's
[manifests/cilium.yaml](../../../../local-talos/manifests/cilium.yaml). Each
step is a monitor step.

1. **worker-config**: patch the workers with
   [cni-none-worker.yaml](../../patches/cni-none-worker.yaml) (`cni.name: none`,
   `proxy.disabled: true`). Asserts that Flannel and kube-proxy still run,
   Cilium is not installed and nothing is disrupted.
2. **cp-config**: patch the control plane with
   [cni-none-controlplane.yaml](../../patches/cni-none-controlplane.yaml), which
   also deletes the `flannel` block that Talos rejects without Flannel, and the
   Cilium inline manifest. Talos creates the missing Cilium objects at once,
   without `upgrade-k8s`, and leaves Flannel and kube-proxy running. The test
   waits for Cilium, then 20 more seconds, and asserts that the LoadBalancer
   address is down for at least 15 seconds: once Cilium's agent runs, it takes
   over the node's routes to the pod network, so every pod Flannel networked
   loses its network and stays without it until it is recreated.
3. **upgrade-k8s**: `talosctl upgrade-k8s --to <running version>`, first with
   `--dry-run`. Asserts that both list the Flannel and kube-proxy DaemonSets
   (with their RBAC, ServiceAccounts and ConfigMap) as pruned or deleted.
4. **restart-pods**: recreate the pods left on Flannel's network through
   their owners with
   [cni-pods](../../README.md#recreating-pods-after-the-switch), which waits
   until none is left and every workload is ready. Waits for all probers to
   report and checks the local volume's data, then
   records each node's leftovers: `cni0`, `flannel.1`, Flannel's CNI config
   renamed to `*.cilium_bak`, and the `kube-proxy`, `flannel-*` and
   `kube-network-policies` nftables tables.
5. **no-reboot**: asserts that every signal is up, that no policed prober
   reached the external address, and that fresh policed pods are blocked from
   the external address from the first packet while reaching the echo pod.
6. **rolling-reboot**: reboot the control plane, then each worker, waiting for
   every workload in between. Asserts that no node has anything of Flannel,
   kube-proxy or kube-network-policies left.
7. **steady**: the checks of step 5 again, and the local volume's data.

`results.txt` also records the outages from step 2 to step 4 as one span,
which includes the test's 20-second wait.

The sequence this rehearses for production, as `cutover` in
[migration_test.go](../../migration_test.go) runs it for the other scenarios:
patch the workers, then the control planes, wait for Cilium, run
`upgrade-k8s`, recreate the pods without a CiliumEndpoint, then reboot each
node to clear the leftovers. The reboots are not needed for traffic or
policy; they clear rules that no longer match anything.
