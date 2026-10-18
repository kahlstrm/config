# Kubernetes GitOps

Flux reconciles this directory from `main`. Talos applies the Flux Operator and
the `FluxInstance` from [local-talos](../local-talos/README.md#flux-operator-upgrades),
which points Flux at `clusters/klusse`.

## Layers

`clusters/klusse` defines one Flux Kustomization per layer. Each layer waits for
the previous one to become healthy:

```
infrastructure-controllers → infrastructure-configs → platform
```

- `infrastructure/controllers`: operators and CRDs, such as OpenEBS, MetalLB,
  cert-manager and the Prometheus Operator CRDs.
- `infrastructure/configs`: resources that need those CRDs or controllers, such as
  the `local-storage` StorageClass, MetalLB address pools and the ClusterIssuer.
- `platform`: shared services that applications use, such as Traefik and
  external-dns.

Each component is one file holding its Namespace, chart source and HelmRelease.
Put new components in the lowest layer whose dependencies are already satisfied.
Kubernetes Secrets still come from Terraform; see [infra/AGENTS.md](../AGENTS.md#secret-management).

Argo CD still runs the Applications in `apps-talos/` and `apps/`.

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
```
