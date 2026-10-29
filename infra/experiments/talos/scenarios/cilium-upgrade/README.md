# cilium-upgrade

```sh
nix develop .#talos --command just talos run cilium-upgrade
```

Changes Cilium that Talos owns through an inline manifest, as production
would after the [cilium-migration](../cilium-migration/README.md) cutover.
The cluster boots with the previous Cilium patch release from
[assets.nix](../../assets.nix) (`ciliumPrevious`) and
production's [values](../../../../local-talos/cilium/values.yaml), and otherwise has the
[CNI migration scenarios](../../README.md#cni-migration-scenarios)' platform
and probers.

1. **values-config**: replace the inline manifest with one rendered with
   [monitor-aggregation.yaml](../cilium/monitor-aggregation.yaml) added.
   Asserts that the agents' ConfigMap is unchanged (Talos only creates missing
   objects) and nothing is disrupted.
2. **values-upgrade-k8s**: `upgrade-k8s`, after a dry run that must list
   `cilium-config` as changed. Asserts the new value and that every agent pod
   was replaced (`rollOutCiliumPods`), and that no policed prober reached the
   external address.
3. **version-config** and **version-upgrade-k8s**: the same with the chart
   production moves to. Asserts that every agent runs the new image, and
   that no policed prober reached the external address.
4. **steady**: every signal up, first-packet enforcement for fresh pods, and
   the local volume's data.

Talos appends inline manifests from a patch instead of merging them by name,
so the test deletes the old manifest in the same apply
([remove-cilium.yaml](../../patches/remove-cilium.yaml)). Terraform
regenerates the whole config and needs no such step.
