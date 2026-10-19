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
  Loki, Alloy, kube-prometheus-stack and Harbor. HelmRelease `dependsOn`
  orders services inside the layer, e.g. Loki → Alloy.
- `apps`: workloads, each in its own directory with a `kustomization.yaml`.

Each component is one file holding its Namespace, chart source and HelmRelease,
or a directory when it also has plain manifests.
Put new components in the lowest layer whose dependencies are already satisfied.
## Secrets from Secret Manager

The External Secrets Operator syncs internet-usable credentials from the
`local-kubernetes` secret in Google Secret Manager, a JSON object edited with
`just edit` from this directory. Only the namespaces listed in the
`gcp-secret-manager` ClusterSecretStore may read it. Reference a key with an
`ExternalSecret`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: gcp-secret-manager
  data:
    - secretKey: api-token
      remoteRef:
        key: local-kubernetes
        property: cloudflare_api_token
```

## SOPS-encrypted Secrets

Secrets that aren't usable from the internet are committed encrypted with SOPS
as `<secret-name>.sops.yaml` and listed in the kustomization. The `platform` and
`apps` layers decrypt them with the cluster's age key, which the `sops-age`
ExternalSecret provides. The repository's [.sops.yaml](../../.sops.yaml) encrypts
to the administrator SSH key and the cluster key, both in
[lib/ssh-keys.nix](../../lib/ssh-keys.nix); after changing them, run
`just sops-config` and `sops updatekeys` on each file.

```bash
sops edit platform/observability/grafana-admin.sops.yaml   # needs SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519
sops encrypt -i apps/myapp/myapp-credentials.sops.yaml     # new Secret; only public keys needed
```

Write new Secrets with `stringData`; only `data` and `stringData` are encrypted.

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
