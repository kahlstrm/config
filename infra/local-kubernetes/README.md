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

- `infrastructure/controllers`: operators and CRDs, such as OpenEBS, MetalLB, KubeVirt,
  cert-manager and the Prometheus Operator CRDs. The descheduler evicts pods from
  the busier worker every 10 minutes until both run a similar number, since a
  rolling reboot leaves most pods on the worker rebooted first.
- `infrastructure/configs`: resources that need those CRDs or controllers, such as
  the `local-storage` StorageClass, MetalLB address pools, the ClusterIssuer and
  the KubeVirt deployment.
- `platform`: shared services that applications use: Traefik, external-dns,
  Pocket ID (OIDC login), Loki, Alloy, kube-prometheus-stack and Harbor. HelmRelease `dependsOn`
  orders services inside the layer, e.g. Loki → Alloy. Alloy reads pod logs from
  each node's files rather than through the Kubernetes API
  ([ADR 5](../docs/adr/0005-collect-pod-logs-from-node-files.md)).
- `apps`: workloads, each in its own directory with a `kustomization.yaml`.

Each component is one file holding its Namespace, chart source and HelmRelease,
or a directory when it also has plain manifests.
Put new components in the lowest layer whose dependencies are already satisfied.

## Data survives its removal from Git

Removing a volume from Git, by mistake or on purpose, leaves its data on the node
([the frictionless shipping ADR](../docs/adr/2026-11-10-agents-ship-without-approvals.md)):

- Each layer's Kustomization in `clusters/klusse` marks every
  PersistentVolumeClaim and CustomResourceDefinition it applies with
  `kustomize.toolkit.fluxcd.io/prune: disabled`, and sets `deletionPolicy:
  Orphan`, so deleting the Kustomization leaves what it applied.
- A Namespace that holds volumes carries the same annotation itself.
- `local-storage` provisions volumes with reclaim policy `Retain`, and the
  `retain-volumes` Job in `infrastructure/configs` sets every other volume to
  `Retain` within an hour. A chart's claims, which Helm deletes when its release
  goes, keep their data this way.

The [destructive-change guard](../destroy-guard/main.go) fails a pull request
that removes one of these protections or a stateful object, unless it carries
the label `allow-destroy`. Deleting data on purpose is a labelled PR followed by
deleting the released volume and its directory under `/var/mnt/local-storage`.

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
to the offline recovery key and the cluster key, both in
[lib/ssh-keys.nix](../../lib/ssh-keys.nix); after changing them, run
`just sops-config`.

Write a Secret whole, with only public keys, instead of decrypting it to change
one value. Files written before the recovery key replaced the administrator
keys still carry those keys until they are written again; they are not
re-encrypted, since their history stays readable with the old keys anyway.

```bash
sops encrypt -i apps/myapp/myapp-credentials.sops.yaml     # only public keys needed
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
same PR. Outbound traffic is not restricted yet, except for docsight and the Amp runner
(`apps/amp-runner`), which reaches only the cluster DNS, the Kubernetes API and
HTTPS on the internet.

The [netpol-canary](platform/netpol-canary) CronJob checks enforcement every 15
minutes: its pod must not reach the cable modem 10 seconds after it starts.
It does not check a pod's first seconds, which policies do not cover
([ADR 4](../docs/adr/0004-network-policies-apply-seconds-after-pod-start.md)).
`NetworkPolicyCanaryFailing` fires when it has not succeeded for 40 minutes.

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
