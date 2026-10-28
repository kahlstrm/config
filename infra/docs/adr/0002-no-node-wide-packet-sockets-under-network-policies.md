# 2. Keep node-wide packet sockets off the nodes while enforcing NetworkPolicies

- Status: accepted
- Date: 2026-10-25

## Context

Talos runs [kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies)
beside Flannel to enforce NetworkPolicies
([Network Policies](../../local-talos/README.md#network-policies)). It hooks
`postrouting` just before Flannel's masquerade and sends the first packet of
each new connection to or from a policed pod to userspace with
`queue flags bypass to 100`.

Talos enables bridge netfilter (`net.bridge.bridge-nf-call-iptables=1`), so a
packet a pod sends through the `cni0` bridge gets its conntrack entry while
still in the bridge, before the node's IP stack receives it. Any `AF_PACKET`
socket listening on all interfaces for IPv4 (`ETH_P_IP`) or all protocols
(`ETH_P_ALL`) receives a clone of that packet, and the clone holds a second
reference to the still-unconfirmed conntrack entry.

Since kernel commit
[7d8dc1c7be8d](https://git.kernel.org/torvalds/c/7d8dc1c7be8d) ("netfilter:
nf_queue: drop packets with cloned unconfirmed conntracks", 2024), nfqueue
refuses to queue such a packet. The error is not one `bypass` covers, so the
kernel drops it without telling userspace.

MetalLB's FRR speaker container runs `bfdd`, which holds such a socket. With it
on every node, connections from policed pods that leave the node, such as
docsight to the cable modem and Flux to GitHub, timed out while enforcement
was on (#115, reverted in #116). Traffic arriving over `flannel.1` gets its
conntrack entry after the clone is taken and was unaffected.

## Decision

Enforce NetworkPolicies with kube-network-policies, and keep the nodes free of
long-lived node-wide `ETH_P_IP` or `ETH_P_ALL` packet sockets. MetalLB runs in
L2 mode with both its FRR speaker container and the FRR-K8s backend disabled
([metallb.yaml](../../local-kubernetes/infrastructure/controllers/metallb.yaml)).
Chart 0.16 enables FRR-K8s by default, so both settings stay explicit.

Reconsider when kube-network-policies queues packets without depending on an
unshared conntrack entry, or when moving to a CNI with its own policy engine.

## Consequences

- MetalLB cannot announce over BGP. Enabling BGP brings FRR back and breaks
  egress from policed pods.
- Any new node-level workload that opens such a socket has the same effect,
  for example DHCP relays, BFD or other routing daemons, and some monitoring
  agents. Check with `talosctl -n <node> read /proc/net/packet`: a row with
  `Iface` 0 and `Proto` 0800 or 0003 is such a socket.
- `tcpdump -i any` or `tcpdump -i cni0` on a node drops egress from policed
  pods for as long as it runs. Capture on a pod's veth or the uplink instead.
- The drop is silent: the controller logs nothing and the queue's packet count
  in `/proc/net/netfilter/nfnetlink_queue` stays the same, while an nftables
  trace shows `verdict queue`.
