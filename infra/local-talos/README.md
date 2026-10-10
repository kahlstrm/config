# Talos Cluster

Apply `local-networking` first. Node configuration, installer images, and storage
settings live in [main.tf](main.tf).

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

For the agent VM, use [dedicated debugging access](agent-debug.md). The commands
below export operator credentials.

```bash
terraform output -raw talosconfig > ~/.talos/config
terraform output -raw kubeconfig > ~/.kube/talos-config
export KUBECONFIG=~/.kube/talos-config
talosctl health
kubectl get nodes
```

## OS Upgrades

Use verified installer tags matching the exact Talos version; avoid digest
references with the pinned provider. Upgrade one node at a time and check health
before continuing. Upgrades are not automatically serialized.
