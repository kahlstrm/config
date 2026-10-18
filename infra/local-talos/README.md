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
[rpi5-installer](rpi5-installer) rebuilds it from U-Boot with
[one patch](rpi5-installer/patches/0001-rpi5-rp1-usb-nvme.patch) and layers it
onto the upstream overlay. [versions.json](versions.json) pins the Talos and
overlay versions.

The `Talos Raspberry Pi 5 installer` workflow builds the installer on pull
requests. On `main` it publishes `ghcr.io/kahlstrm/talos-installer-rpi5:<talos>`.
Existing tags are kept, so to roll a U-Boot or overlay change into the current
Talos version, dispatch the workflow with `overwrite`. The package must be
public, because nodes pull it without credentials.

The build renders the EFI files the installer writes to a node: U-Boot, the
Pi 5 device trees and `config.txt`. It fails unless they match
[verified-boot.sha256](rpi5-installer/verified-boot.sha256), which records the
boot chain verified on c1. The build is reproducible, so the hashes stay stable.
To change any of these files deliberately, verify the new installer on c1 over
UART first, then update the hashes in the same commit.

Build it locally with:

```bash
nix shell --inputs-from .. nixpkgs#crane nixpkgs#jq --command rpi5-installer/build.sh _out
```

## OS Upgrades

Use verified installer tags matching the exact Talos version; avoid digest
references with the pinned provider. Upgrade one node at a time and check health
before continuing. Upgrades are not automatically serialized.
