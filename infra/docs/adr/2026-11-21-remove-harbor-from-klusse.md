# Remove Harbor and the router throughput endpoint from klusse

- Status: accepted
- Date: 2026-11-21
- Related: [ADR 7](0007-amp-orbs-on-klusse.md)

## Context

klusse is refocusing its workers on orbs, and memory on w1 is the tightest in
the cluster. Harbor 1.18 ran on w1 as seven pods (core, portal, the registry with its
controller, job service, PostgreSQL, Redis and Trivy) with no resource
requests, and held five `local-storage` claims there: registry 50 Gi,
database 5 Gi, Trivy 5 Gi, Redis 1 Gi and the job service log (the chart's
1 Gi default).

Its one consumer was the router throughput endpoint
(`apps/router-throughput`): a host-network iperf3 server on w1 for routed LAN
tests from pannu, pulling an image built from
`experiments/network-diagnostics/iperf3-image.nix` and pushed only to Harbor
by hand. The routed LAN tests it served ran in September. Every other workload pulls from
public registries or GHCR. The `agent-sandbox` image policy also allowed
Harbor images, but no test pod used one.

## Decision

- **Remove Harbor:** its namespace, chart, admin password, network policies and
  ingress, and the `harbor.kube.kalski.xyz/` prefix in the `agent-sandbox` image
  policy. external-dns drops the record with the ingress. There were no
  Harbor alerts or dashboards.
- **Remove the router throughput endpoint and its image build** rather than move
  the image to GHCR. Nothing else used either. For a one-off throughput test, a
  maintainer runs an ad hoc iperf3 pod with host networking in
  `monitoring-privileged` on the node under test and deletes it afterwards.
- **Keep the data until a maintainer deletes it.** The namespace keeps its
  prune protection in the cluster, Helm keeps the claims, and `local-storage`
  volumes are `Retain`, so the merge stops Harbor without deleting anything.

## Consequences

- w1 regains the memory Harbor's pods used. Its disk comes back only when a
  maintainer deletes the data: deleting the `harbor` namespace deletes the
  claims, but their volumes are `Retain`, so they become Released and keep
  their data. Deleting those PersistentVolumes and their directories under
  `/var/mnt/local-storage` on w1 then frees up to 62 Gi of claims (see
  [local-kubernetes](../../local-kubernetes/README.md#data-survives-its-removal-from-git)).
  Harbor's images and scan data are not backed up and are lost then.
- The cluster has no registry of its own. Images built from this repository
  are published to GHCR by GitHub Actions, as the Amp runner image is.
- The Cilium cutover runbook still checks Harbor in T1 and T3; drop those
  checks before the window runs.

## Restoring it

Restore `platform/harbor.yaml`, `harbor-network-policy.yaml` and
`harbor-admin-password.sops.yaml` from the commit before this one, and list
them in `platform/kustomization.yaml`. Check the chart version against the
current upstream release first. What the data does depends on how far the
removal went:

- **The namespace still exists:** the new release reuses the claims left
  there, and Harbor starts with its old data and its old admin password.
- **The namespace is gone but the Released volumes remain:** new claims would
  get new, empty volumes. To reuse the old data, do this before restoring the
  HelmRelease: recreate the namespace, set each old volume's `claimRef` to just
  the name and namespace of its Harbor claim (without the old UID, so no other
  claim can bind it), create that claim with `volumeName` set to the volume,
  and check that it is Bound. The database keeps the old admin password,
  because Harbor sets the admin password from the Secret only on a database
  without one; keep the old Secret or reset the password in the database.
- **The volumes are deleted:** Harbor starts empty, and a newly generated
  admin password works.

A possible reason to restore a registry is a pull-through cache for the
roughly 7 GiB Amp orb image, so that new orbs do not pull it over the WAN.
Today's orbs pull it through the Docker daemon in the klusse-w1 runner VM,
which reaches only the internet, from Google Artifact Registry rather than
Docker Hub. A cache for them would mean pointing
`local.klusseRunner.orbs.image` at the cache's image URL and letting the VM
reach the cache; neither has been tried.
