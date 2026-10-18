# Kubernetes GitOps

Flux reconciles this directory from `main`. Talos applies the Flux Operator and
the `FluxInstance` from [local-talos](../local-talos/README.md#flux-operator-upgrades),
which points Flux at `clusters/klusse`.

## Layers

`clusters/klusse` defines one Flux Kustomization per layer. Each layer waits for
the previous one to become healthy:

```
infrastructure-controllers → infrastructure-configs → platform → apps
```

- `infrastructure/controllers`: operators and CRDs, such as OpenEBS, MetalLB,
  cert-manager and the Prometheus Operator CRDs.
- `infrastructure/configs`: resources that need those CRDs or controllers, such as
  the `local-storage` StorageClass, MetalLB address pools and the ClusterIssuer.
- `platform`: shared services that applications use: Traefik, external-dns,
  MinIO, Loki, Alloy, kube-prometheus-stack and Harbor. HelmRelease `dependsOn`
  orders services inside the layer, e.g. MinIO → Loki → Alloy.
- `apps`: workloads, each in its own directory with a `kustomization.yaml`.

Each component is one file holding its Namespace, chart source and HelmRelease,
or a directory when it also has plain manifests.
Put new components in the lowest layer whose dependencies are already satisfied.
Kubernetes Secrets still come from Terraform; see [infra/AGENTS.md](../AGENTS.md#secret-management).

## Validation

```bash
nix develop .#kubernetes --command local-kubernetes/scripts/validate.sh
```

The script renders every kustomization and checks it against Kubernetes and CRD
schemas. CI runs it on every infrastructure change.

## Operations

```bash
flux get kustomizations
flux get helmreleases --all-namespaces
flux reconcile kustomization flux-system --with-source
kubectl -n flux-system port-forward svc/flux-operator 9080:9080  # Flux web UI
```
