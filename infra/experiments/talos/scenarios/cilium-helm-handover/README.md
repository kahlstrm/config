# cilium-helm-handover

```sh
nix develop .#talos --command just talos run cilium-helm-handover
```

Runs the [cilium-migration](../cilium-migration/README.md) cutover, then hands
Cilium from Talos's inline manifest to Flux, as production would to let Flux
own Cilium after bootstrap. Talos records every object it applies in the
`talos-bootstrap-manifests-inventory` ConfigMap, and since Talos 1.13
`upgrade-k8s` deletes inventory objects that are no longer in the machine
config.

1. **handover**: create a `cilium-values` ConfigMap from
   [../cilium/values.yaml](../cilium/values.yaml) and apply
   [cilium-helmrelease.yaml](../../manifests/cilium-helmrelease.yaml), a
   HelmRelease of the same chart version with Flux's defaults, which take
   ownership of existing objects and apply server-side. Asserts that the
   release becomes ready with nothing disrupted, and records the DaemonSet's
   field managers (Talos's and Flux's).
2. **flux-change**: add
   [monitor-aggregation.yaml](../cilium/monitor-aggregation.yaml) to the
   values and reconcile; waits for the agents' ConfigMap to change.
3. **inline-upgrade-k8s**: `upgrade-k8s` (and its dry run) while the inline
   manifest is still in the config. Asserts that it reverts Flux's change.
4. **flux-restores**: reconciling the HelmRelease restores Flux's value.
5. **remove-inline**: delete the inline manifest from the config with
   [remove-cilium.yaml](../../patches/remove-cilium.yaml). Asserts that Talos
   leaves Cilium running.
6. **no-prune**: `upgrade-k8s --manifests-no-prune`. Asserts that it deletes
   nothing and leaves Cilium's objects in the inventory.
7. **prune**: `upgrade-k8s` without the flag, after a dry run that must list
   the Cilium DaemonSet. Asserts that it deletes the DaemonSet, waits for the
   agents to go, and records traffic for 20 seconds and whether a new pod
   starts.
8. **flux-recreates**: reconciling the HelmRelease recreates Cilium (drift
   detection is on). Asserts that a later `upgrade-k8s` deletes nothing; the
   prune also emptied the inventory.
9. **readd-inline**: put the inline manifest back and run `upgrade-k8s`;
   waits for Talos to list Cilium in its inventory again, then lets Flux
   restore its values.
10. **inventory-edit**: delete the inline manifest again and remove Cilium's
    entries from the inventory ConfigMap. Asserts that `upgrade-k8s`, dry run
    and real, then prunes nothing and nothing is disrupted.
11. **steady**: every signal up, no policed prober reaches the external
    address, first-packet enforcement for fresh pods, and the local volume's
    data.

After every control-plane patch the test waits until Talos has rendered the
changed inline manifest: `upgrade-k8s` reads Talos's rendered manifests, so
one started right after a patch can still act on the previous ones.
