# Talos Cluster

Apply `local-networking` first. Node configuration and installer images live in
[main.tf](main.tf). [flux.tf](flux.tf) adds the Flux Operator and
[the FluxInstance](manifests/flux-instance.yaml) to the control-plane config;
Talos creates them and Flux then reconciles
[local-kubernetes](../local-kubernetes/README.md).

## Apply

Run from this directory:

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

For new nodes, configure networking first, boot Talos, and add the node to
`main.tf`. Check installation disks with `talosctl get disks --insecure --nodes <node-ip>`.

## External Secrets Access

[external-secrets.tf](external-secrets.tf) creates the `local-kubernetes`
secret and lets the External Secrets Operator read it through workload identity
federation. GCP checks the operator's service-account tokens against
[the cluster's public keys](service-account-jwks.json); there is no key file.
The ClusterSecretStore in `local-kubernetes` uses the
`external_secrets_audience` output.

## Access

```bash
terraform output -raw talosconfig > ~/.talos/config
terraform output -raw kubeconfig > ~/.kube/talos-config
export KUBECONFIG=~/.kube/talos-config
talosctl -n 10.10.10.11 health   # health takes exactly one node
kubectl get nodes
```

The Kubernetes API endpoint is `https://api.k8s.kalski.xyz:6443`, a DNS name
for a shared address (`k8s_api` in local-networking) that Talos moves to a
healthy control plane, so the API stays reachable while one is down. Point
`talosctl` at the node addresses instead; the shared address only works while
etcd is healthy. Service-account tokens keep the original issuer,
`https://10.10.10.11:6443`, which workload identity federation trusts.

Talos also derives the API server's accepted token audience (`api-audiences`)
from the endpoint. Changing the endpoint therefore rejects every token issued
before the change until it rotates, and processes that keep the token in memory
fail until restarted. To change the endpoint, first list both audiences in
`cluster.apiServer.extraArgs["api-audiences"]` (comma-separated), and drop the
old one once all tokens have rotated.

## Flux Operator Upgrades

Talos owns the operator and the `FluxInstance`; Flux does not manage them. The
operator upgrades Flux itself within the `FluxInstance` version range. To
upgrade the operator or change the `FluxInstance`, edit [flux.tf](flux.tf) or
the manifest, apply, then sync the running cluster:

```bash
talosctl upgrade-k8s --to <current Kubernetes version> --dry-run
talosctl upgrade-k8s --to <current Kubernetes version>
```

Talos only creates missing manifests on its own; `upgrade-k8s` updates them and,
from Talos 1.13, deletes ones removed from the config.

## Raspberry Pi 5 Installer

Upstream's `rpi_5` overlay ships a U-Boot without RP1 or working NVMe boot.
[rpi5-installer](rpi5-installer) replaces it with the `rpi5-u-boot` output of
[kahlstrm/u-boot](https://github.com/kahlstrm/u-boot) (branch `jetkvm-rpi5`),
pinned in [flake.nix](../flake.nix): RP1 and NVMe boot support, USB fixes
that let U-Boot use a JetKVM's virtual disk and keyboard, and runtime EFI
variables. Talos writes its boot entries during installs and upgrades; without
them the installer stops before writing U-Boot and the device trees, yet the
node still reboots into the new Talos version.
[versions.json](versions.json) pins the Talos and overlay versions.

The `Talos Raspberry Pi 5 installer` workflow builds the installer on pull
requests. On `main` it publishes `ghcr.io/kahlstrm/talos-installer-rpi5:<talos>`.
Existing tags are kept, so to roll a U-Boot or overlay change into the current
Talos version, dispatch the workflow with `overwrite`. The package must be
public, because nodes pull it without credentials.

The build renders the EFI files the installer writes to a node: U-Boot, the
Pi 5 device trees and `config.txt`. It fails unless they match
[verified-boot.sha256](rpi5-installer/verified-boot.sha256), which records the
boot chain verified on a control plane. The build is reproducible, so the
hashes stay stable. To change any of these files deliberately, boot the new
U-Boot on a control plane first with the fork's JetKVM launcher image (see its
`jetkvm/README.md`), which leaves the node's disks untouched, then update the
pin and the hashes in the same commit.

Build it locally with:

```bash
nix shell --inputs-from .. nixpkgs#crane nixpkgs#jq --command rpi5-installer/build.sh _out
```

## OS Upgrades

[versions.json](versions.json) holds the Talos version for all nodes.
Raspberry Pi 5 control planes use the installer above; workers use an Image
Factory installer. `talos_machine` upgrades a node whenever its running version
differs from the installer tag. All nodes are `for_each` instances, so an
untargeted apply after a version bump upgrades them all at once and loses etcd
quorum. Keep `talos_machine_configuration.talos_version` at the cluster's
original contract version.

Upgrade one Talos minor at a time:

1. Bump `talos` in `versions.json` and merge. Wait for the installer workflow
   to publish the new tag.
2. Upgrade a control plane only with its UART console attached. Recovery is a
   PoE port toggle on kuberack, plus UART or JetKVM virtual media. Record the
   starting version with `talosctl -n <ip> version`.
3. Apply each node on its own, starting with c1, then c2, c3, w1, and w2:

   ```bash
   terraform apply -target='talos_machine.controlplane["c1.k8s.kalski.xyz"]'
   talosctl -n 10.10.10.11 health
   talosctl -n 10.10.10.11 etcd status
   ```

   Continue only once etcd has all members, and `talosctl -n <node> health` and
   `kubectl get nodes` are healthy. If etcd or the pause container fails with
   `exec format error`, the cached image files are corrupt (zero bytes). Remove
   those images and re-pull them.
4. Finish with an untargeted `terraform plan`. It must show no `talos_machine`
   changes.

Kubernetes stays on `kubernetes` in `versions.json` while Talos is upgraded.
Upgrade it afterwards, one minor at a time, with
`talosctl -n 10.10.10.11 upgrade-k8s --to <version>`. Then set the same
version in `versions.json` before the next apply; an apply in between reverts
the component images.
