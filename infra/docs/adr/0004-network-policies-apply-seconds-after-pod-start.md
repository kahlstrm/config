# 4. Accept that NetworkPolicies apply only seconds after a pod starts

- Status: accepted
- Date: 2026-10-26

## Context

kube-network-policies decides a connection by mapping its pod IPs to pods and
their policies ([Network Policies](../../local-talos/README.md#network-policies)).
It gets that mapping either from containerd through NRI, at the moment the pod
sandbox is created, or by watching pods through the Kubernetes API.

Talos 1.14 runs containerd with NRI enabled, but its Flannel template does not
mount the NRI socket into the kube-network-policies container. The container
logs `dial unix /var/run/nri/nri.sock: connect: no such file or directory` at
startup and falls back to the API watch. Talos generates and reverts the
DaemonSet, so the mount cannot be added here.

Until the watch reports a new pod and its IP, no policy selects it, and its
connections are allowed in both directions. This is the race described in
[kubernetes/kubernetes#85966](https://issues.k8s.io/85966). Measured from a pod
in `agent-sandbox`: a connection to the cable modem in the pod's first second
succeeded, and the same connection about two seconds later was blocked.

## Decision

Accept the window rather than work around it. Each policed pod is unprotected
only during its first seconds, and every connection opened after that is
checked. Workarounds such as a mandatory sleeping init container for
`agent-sandbox` pods add rules every new pod must follow for a gap this small.

Revisit when Talos mounts the NRI socket into kube-network-policies, which
closes the window, or when moving to a CNI with its own policy engine.

## Consequences

- For about two seconds after it starts, a pod can open connections its
  policies deny, and any pod can connect to it. Connections opened in that
  window stay open afterwards.
- An `agent-sandbox` pod that connects immediately can reach the LAN and the
  internet, so the sandbox does not strictly keep agents off the LAN. Agents
  must not rely on this to reach anything outside the cluster.
- Policy tests must start their checks a few seconds after the pod starts, or
  they can pass or fail for the wrong reason.
