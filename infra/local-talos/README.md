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

## Application Credentials

The shared MinIO/Loki password is stored in Secret Manager and read ephemerally
into both Kubernetes Secrets. Both use the Terraform-managed GSM version, so
recreating either Secret preserves the shared credential.

## Access

```bash
terraform output -raw talosconfig > ~/.talos/config
terraform output -raw kubeconfig > ~/.kube/talos-config
export KUBECONFIG=~/.kube/talos-config
talosctl health
kubectl get nodes
```

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

## OS Upgrades

Use verified installer tags matching the exact Talos version; avoid digest
references with the pinned provider. Upgrade one node at a time and check health
before continuing. Upgrades are not automatically serialized.
