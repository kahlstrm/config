# cilium

```sh
nix develop .#talos --command just talos run cilium
```

Cilium replaces Talos's Flannel, its kube-network-policies sidecar and
kube-proxy. [talos-patch.yaml](talos-patch.yaml) sets
`cluster.network.cni.name: none` and `cluster.proxy.disabled: true`. The test
renders the chart pinned in [assets.nix](../../assets.nix) with
[values.yaml](values.yaml) through `helm template` into a control-plane
`cluster.inlineManifests` patch, so Talos installs Cilium at bootstrap. The
values use KubePrism (`localhost:7445`), `kubeProxyReplacement`, the
capabilities and cgroup settings Talos needs, Hubble relay with certificates
from a CronJob (no keys in the machine config), and roll pods out when their
configuration changes.

The test asserts:

- Without a policy, every probe connects to the external address and the echo
  pod at +0, +1 and +3 s.
- Under the pod-network-and-DNS policy, the external address is blocked at
  every offset in every run, and the echo pod connects from the first packet.
- With a node-wide `ETH_P_ALL` packet socket open on the worker (checked in
  `/proc/net/packet`), policed pods still open new connections: a policy that
  allows the external address connects at every offset, and the
  pod-network-and-DNS policy still blocks it. The check runs twice, with a
  privileged hostNetwork `tcpdump -i any`
  ([tcpdump.yaml](../../manifests/tcpdump.yaml)) and with a socket read one
  packet per call, as FRR's `bfdd` reads its own
  ([packet-socket.yaml](../../manifests/packet-socket.yaml)). These are the
  sockets
  [ADR 2](../../../../docs/adr/0002-no-node-wide-packet-sockets-under-network-policies.md)
  keeps off the production nodes.
- The production `namespaceSelector` shape allows the echo pod, its Service
  and DNS, and blocks the external address, as on the current stack. The
  earlier `ipBlock: 10.244.0.0/16` shape blocks all four: by default Cilium's
  `ipBlock` does not match pod IPs (`policyCIDRMatchMode`).
