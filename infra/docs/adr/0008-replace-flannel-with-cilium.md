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
Talos 1.14.4 with production's patches against the current stack, on QEMU
VMs on GitHub's 4-CPU runners:

- **Egress from new pods**: under Cilium, fresh policed pods never reached a
  denied address, at their first connection or 1 s and 3 s later, in 10 of 10
  pods per run in every run. Under the current stack 10 of 10 reached it on
  their first connection. Cilium's CNI plugin returns only after the pod's
  policy is programmed.
- **Inbound to new pods**: a scanner kept connecting to every address of a
  node's pod range while servers started behind default-deny ingress. Under
  the current stack, 3 of 5 servers accepted a connection, 0.26 to 0.52 s
  after starting. Under Cilium none of 5 did. The scan reached every
  unpoliced server within 1 s of its start. A round of the scan takes about a
  second, so this does not exclude a shorter window.
- **Pods started while the API is unreachable**: with the control plane
  frozen, a static pod in a policed namespace reached neither its denied
  external address nor an allowed pod on its node during the 75 s outage. Its
  allowed traffic began about 60 s after the API returned, and it never
  reached the denied address. This was the same with and without a
  CiliumClusterwideNetworkPolicy that selects Cilium's init identity
  (`reserved:init`): Cilium fails closed here, so production needs neither
  that policy nor a change of `policyEnforcementMode`. The lab did not record
  which identity the endpoint had during the outage.
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

- Policies apply from a new pod's first packet in both directions, as far as
  the lab can observe, and node-wide packet sockets no longer break policed
  traffic; ADR 2 and ADR 4 are superseded once the migration is done.
- Hubble records verdicts, so policy problems can be traced to a pod and rule.
- Cilium upgrades are ours: bump the pinned chart, re-render, apply and run
  `upgrade-k8s`. They no longer arrive with Talos defaults.
- The switch is one outage for every pod-network pod. The first control
  plane's new config makes Talos install Cilium on every node at once. Each
  node's pods lose their network when its agent starts, and get it back only
  when recreated. In the lab, the outage ran from the agents' start until
  recreation:
  - 44 s with one control plane and two workers, where the agents were ready
    within a minute;
  - 2 min 35 s and 5 min 18 s for the LoadBalancer (3 min 10 s and 6 min
    32 s into the policed backend) in two passing runs on three control
    planes and two workers, gated as the runbook is: the agents were Ready on
    every node 1 min 58 s and 2 min 53 s after the apply, and recreating the
    pods, slowed by the loaded runner, took the rest.
  The API, through the VIP, was unavailable for 23 s and 70 s at the longest
  in those runs while the control planes' agents started, and in another run
  for 110 s, flapping for several minutes. The lab's control planes share four CPUs with the workers,
  so production's Pis may fare better or worse; the runbook stops if the API
  is gone for more than 30 s. Production's duration depends on how fast its
  agents start, which the lab cannot predict.
- Cilium's Kubernetes IPAM can give a pod the first address of its node's pod
  range, which Flannel's `cni0` bridge holds until the node reboots; such a
  pod cannot be reached. One recreated pod got it in four of about 30 lab
  cutovers. `cni-pods` recreates such pods again.
- Every node needs a reboot afterwards to clear Flannel's and kube-proxy's
  leftovers. `upgrade-k8s` must wait until Cilium runs on every node and every
  control plane renders the same manifests: run earlier, with a node
  rebooting, policed pods reached the internet for about 12 seconds in the
  lab. With three control planes, rebooting the VIP holder interrupted the
  API for 1.2–3.4 s and rebooting the etcd leader for 1.1–2.1 s, with every
  etcd member healthy before and after each. `upgrade-k8s` failed now and
  then on the loaded runner (an etcd request timeout mid-prune, a kubelet
  health check) and finished when run again.
- Going back after Cilium has run on a node needs that node rebooted, under
  the same etcd gate. Abandoning the switch after only the first control
  plane's apply worked with Terraform alone: `upgrade-k8s` pruned the 33
  Cilium objects and nothing of Flannel, and the reboots recovered every
  workload. If Cilium's agents never become ready, they never touch the
  nodes' networks: pods' traffic carried on, with checks delayed by at most
  4.5 s on the loaded runner, and new pods started after the rollback without
  reboots.
- Each node runs a Cilium agent of about 90–135 MB on amd64 at idle, plus an
  Envoy proxy; arm64 use on the Pi 5 control planes is unmeasured.

Not covered by the lab, and so gated at the cutover instead:

- **Cilium's datapath on the Pi 5 control planes** (arm64, the `macb` NIC
  `end0`, known transmit stalls; c2 runs a TCP offload experiment). The first
  control-plane apply is the first time it runs, on all three at once.
- **Production's webhooks and aggregated APIs** (cert-manager,
  external-secrets, KubeVirt, metrics-server), which the API server reaches
  from the host network, and KubeVirt's virtual machines, which `cni-pods`
  leaves alone.
- **Timing**: the lab's numbers come from overcommitted VMs; production's
  agents may start faster, but are on different hardware.
- **Agent access**: the agent environment can delete pods but cannot read
  CiliumEndpoints or exec into pods, so the endpoint and agent-status gates
  need an administrator; `cni-pods` falls back to sandbox ages.
