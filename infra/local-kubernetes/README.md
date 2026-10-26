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
  Pocket ID (OIDC login), Loki, Alloy, kube-prometheus-stack and Harbor. HelmRelease `dependsOn`
  orders services inside the layer, e.g. Loki → Alloy.
- `apps`: workloads, each in its own directory with a `kustomization.yaml`.

Each component is one file holding its Namespace, chart source and HelmRelease,
or a directory when it also has plain manifests.
Put new components in the lowest layer whose dependencies are already satisfied.
## Secrets from Secret Manager

The External Secrets Operator syncs internet-usable credentials and bearer URLs
from the `local-kubernetes` secret in Google Secret Manager, a JSON object edited
with `just edit` from this directory. Only the namespaces listed in the
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

## Login

Pocket ID (`https://id.kube.kalski.xyz`) issues passkey logins. Apps with OIDC
support, such as Grafana, use it directly. Protect any other Ingress by adding
this annotation; it requires membership in the `admins` group:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: oauth2-proxy-forward-auth@kubernetescrd
```

Users, groups and OIDC clients are declared in
[identity.json](apps/pocket-id-sync/identity.json). The `pocket-id-sync` Job applies
it through Pocket ID's API with a key generated in the cluster, and deletes
clients and groups that aren't declared; users are only ever disabled. Add a
client in the same PR as its app. Clients are public and use PKCE, so no client
secrets reach the cluster. Test changes to the script with
`nix build .#checks.x86_64-linux.pocket-id-sync`.

To register a passkey on a new device, issue a one-time login link:

```bash
kubectl -n pocket-id exec deploy/pocket-id -- /app/pocket-id one-time-access-token <username>
```

## Network Policies

NetworkPolicies are enforced (see
[local-talos](../local-talos/README.md#network-policies)). The login stack and
Harbor deny inbound traffic by default and allow only their known clients,
mainly Traefik; docsight allows only Traefik and Prometheus. When adding a
client of these apps, or a ServiceMonitor for them, extend their policy in the
same PR. Outbound traffic is not restricted yet, except for docsight.

The [netpol-canary](platform/netpol-canary) CronJob checks enforcement every 15
minutes: its pod must not reach the cable modem, either at start or 10 seconds
later. `NetworkPolicyCanaryFailing` fires when it has not succeeded for 40
minutes. It fails while policies apply only seconds after a pod starts
([ADR 4](../docs/adr/0004-network-policies-apply-seconds-after-pod-start.md)).

## Validation

```bash
nix develop .#kubernetes --command local-kubernetes/scripts/validate.sh
```

The script renders every kustomization and checks it against Kubernetes and CRD
schemas. CI runs it on every infrastructure change.

Alert rule unit tests live in `platform/observability/tests/` and run as a flake
check, also in CI:

```bash
nix build .#checks.x86_64-linux.alert-rules -L
```

The check extracts each PrometheusRule's `spec` to `rules/<metadata.name>.yaml`
and runs `promtool test rules` on the test files, which load rules from there.

## Operations

```bash
flux get kustomizations
flux get helmreleases --all-namespaces
flux reconcile kustomization flux-system --with-source
kubectl -n flux-system port-forward svc/flux-operator 9080:9080  # Flux web UI
```
