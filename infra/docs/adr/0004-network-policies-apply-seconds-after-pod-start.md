# 4. Accept that NetworkPolicies apply only seconds after a pod starts

- Status: accepted
- Date: 2026-10-26

## Context

kube-network-policies only queues packets to or from IPs in an nftables set
of policed pods ([Network Policies](../../local-talos/README.md#network-policies)).
It fills that set from each pod's `status.podIPs`, which reaches it through the
Kubernetes API after the kubelet reports the running pod.

Until then a new pod's packets skip the queue, so its connections are allowed in
both directions. This is the race described in
[kubernetes/kubernetes#85966](https://issues.k8s.io/85966). Measured from a pod
in `agent-sandbox`: a connection to the cable modem in the pod's first second
succeeded, and the same connection about two seconds later was blocked.

kube-network-policies can also learn pod IPs from containerd through NRI, at
sandbox creation, but up to v1.1.2 only uses them to identify the pods in a
queued packet. Running its upstream `install.yaml`, which mounts the NRI socket
that Talos's sidecar lacks, left the window unchanged
([ADR 6](0006-run-kube-network-policies-from-its-upstream-manifest.md)).

## Decision

Accept the window rather than work around it. Each policed pod is unprotected
only during its first seconds, and every connection opened after that is
checked. Workarounds such as a mandatory sleeping init container for
`agent-sandbox` pods add rules every new pod must follow for a gap this small.

Revisit when kube-network-policies fills its set of policed IPs from NRI and
Talos mounts the NRI socket into its sidecar, or when moving to a CNI with its
own policy engine.

## Consequences

- For about two seconds after it starts, a pod can open connections its
  policies deny, and any pod can connect to it. Connections opened in that
  window stay open afterwards.
- An `agent-sandbox` pod that connects immediately can reach the LAN and the
  internet, so the sandbox does not strictly keep agents off the LAN. Agents
  must not rely on this to reach anything outside the cluster.
- Policy tests must start their checks a few seconds after the pod starts, or
  they can pass or fail for the wrong reason.
