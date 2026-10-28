# 6. Run kube-network-policies from its upstream manifest

- Status: accepted
- Date: 2026-10-28
- Supersedes: [ADR 4](0004-network-policies-apply-seconds-after-pod-start.md)

## Context

Talos's `cluster.network.cni.flannel.kubeNetworkPoliciesEnabled` adds
kube-network-policies to its Flannel DaemonSet as a second container, but does
not mount containerd's NRI socket (`/var/run/nri`) or the pod network
namespaces (`/var/run/netns`). Without them the controller learns pod IPs only
through the Kubernetes API, so a new pod's connections bypass its policies for
about two seconds (ADR 4).

Talos's template follows the Flannel Helm chart, which predates the NRI
support kube-network-policies added in 2025. kube-network-policies' own
`install.yaml` mounts both paths, and containerd on Talos has NRI enabled. No
upstream issue tracks the missing mounts, and Talos accepts contributions only
when the contributor writes every part of them.

## Decision

Disable Talos's option and deploy kube-network-policies with Flux from a copy of
its upstream `install.yaml`
([kube-network-policies.yaml](../../local-kubernetes/infrastructure/controllers/kube-network-policies.yaml)),
with the image pinned by digest.

Return to Talos's option once its sidecar mounts the NRI socket, or drop both
when moving to a CNI with its own policy engine.

## Consequences

- Policies apply from a pod's first packet. The `netpol-canary` CronJob checks
  this every 15 minutes.
- kube-network-policies no longer follows Talos's defaults through
  `upgrade-k8s`. Update the copy and its image digest from upstream releases.
- [ADR 2](0002-no-node-wide-packet-sockets-under-network-policies.md) still
  applies: the controller queues packets the same way.
