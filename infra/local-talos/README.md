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
talosctl health
kubectl get nodes
```

The Kubernetes API endpoint is `https://api.k8s.kalski.xyz:6443`, a DNS name
for a shared address (`k8s_api` in local-networking) that Talos moves to a
healthy control plane, so the API stays reachable while one is down. Point `talosctl` at the node addresses instead; the
shared address only works while etcd is healthy. Service-account tokens keep the
original issuer, `https://10.10.10.11:6443`, which workload identity federation
trusts.

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
