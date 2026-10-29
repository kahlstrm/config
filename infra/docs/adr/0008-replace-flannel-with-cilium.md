# 8. Replace Flannel, kube-network-policies and kube-proxy with Cilium

- Status: proposed
- Date: 2026-10-29

## Context

NetworkPolicies carry the agent sandbox and the default-deny policies of the
login stack and Harbor, and egress restrictions are next. Talos's Flannel with
its kube-network-policies sidecar enforces them with two known gaps:

- A new pod is unpoliced for about two seconds, because kube-network-policies
  learns which IPs to police from the Kubernetes API
  ([ADR 4](0004-network-policies-apply-seconds-after-pod-start.md)).
- A node-wide `ETH_P_IP` packet socket, such as MetalLB FRR's `bfdd`, makes
  the kernel drop new connections from policed pods
  ([ADR 2](0002-no-node-wide-packet-sockets-under-network-policies.md)).

Neither has an upstream fix in sight, and both were hard to diagnose because
nothing records the verdicts.

The [Talos lab](../../experiments/talos/README.md) measured Cilium 1.20.4 on
Talos 1.14.4 with production's patches, versus the current stack:

- Fresh policed pods were blocked from their first packet in every run, in
  both directions; the current stack let the first packet through in 10 of 10.
  Cilium's CNI plugin returns only after the pod's policy is programmed.
- With FRR's `bfdd` running, allowed traffic from policed pods kept working
  under Cilium; under the current stack it was dropped.
- Hubble showed each drop with its pods and reason.
- A Cilium agent that stops leaves running traffic and policy in place, but
  new pods on its node cannot start until it is back.

## Decision

Replace Flannel, kube-network-policies and kube-proxy with Cilium, with
kube-proxy replacement, IPAM from Kubernetes and Hubble relay.

**Talos owns Cilium**, as it owns the Flux Operator
([flux.tf](../../local-talos/flux.tf)): `helm template` renders the pinned
chart with our values into `cluster.inlineManifests`, and upgrades go through
Terraform and `talosctl upgrade-k8s`. The lab rolled out a chart upgrade and a
values change this way without disruption. The CNI then does not depend on
Flux, which itself needs the CNI. Handing Cilium to a Flux HelmRelease worked,
but removing the inline manifest afterwards makes the next `upgrade-k8s`
delete every Cilium object unless they are first removed from Talos's
manifest inventory by hand.

**MetalLB keeps announcing LoadBalancer addresses** in L2 mode. On Cilium it
failed over in 0.3 s on a graceful reboot and 6.3 s on a frozen node, against
1.5 s and 16.1 s for Cilium's L2 announcements with default lease timing.

Policies must not select the pod network with an `ipBlock` of the pod CIDR:
Cilium does not match it against pods. Use `namespaceSelector: {}`.

Reconsider Cilium's L2 announcements after tuning their lease, and Flux
ownership if Talos gains a way to hand over a manifest without pruning it.

## Consequences

- Policies apply from a pod's first packet, and node-wide packet sockets no
  longer break policed traffic; ADR 2 and ADR 4 are superseded once the
  migration is done.
- Hubble records verdicts, so policy problems can be traced to a pod and rule.
- Cilium upgrades are ours: bump the pinned chart, re-render, apply and run
  `upgrade-k8s`. They no longer arrive with Talos defaults.
- The cutover interrupts pod networking for about 15 seconds, and each node
  needs a reboot afterwards to clear Flannel's and kube-proxy's leftovers.
  `upgrade-k8s` must wait until Cilium runs on every node: run earlier, with a
  node rebooting, policed pods reached the internet for about 12 seconds in
  the lab. Rolling back also needs every node rebooted.
- Each node runs a Cilium agent of about 90–135 MB on amd64 at idle, plus an
  Envoy proxy; arm64 use on the Pi 5 control planes is unmeasured.
- If the API server is unreachable when a pod starts, Cilium gives it a
  temporary identity whose traffic is allowed until the real one is known
  (Cilium's "init identity"); this was not tested.
