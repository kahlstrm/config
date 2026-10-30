# cilium

```sh
nix develop .#talos --command just talos run cilium
```

Cilium replaces Talos's Flannel, its kube-network-policies sidecar and
kube-proxy, as production's `cni = "cilium"` would set it up: the
talos-cluster module's [none.yaml](../../../../modules/talos-cluster/cni/none.yaml)
sets `cluster.network.cni.name: none` and `cluster.proxy.disabled: true`, and
production's rendered
[manifests/cilium.yaml](../../../../local-talos/manifests/cilium.yaml) is a
control-plane `cluster.inlineManifests` entry, so Talos installs Cilium at
bootstrap. Its [values](../../../../local-talos/cilium/values.yaml) use
KubePrism (`localhost:7445`), `kubeProxyReplacement`, the capabilities and
cgroup settings Talos needs, Hubble relay with certificates from a CronJob (no
keys in the machine config) and Hubble metrics, and roll pods out when their
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
- Inbound first packet: the scan reaches every unpoliced server, and no
  server behind default-deny ingress accepts a connection.
- A pod started while the API is down (see the
  [lab README](../../README.md#scenarios)): with production's Cilium, what it
  reaches while the API is down is recorded; with the `reserved:init` policy
  it must not reach the external address then. In both, once the API is back,
  it reaches the allowed pod and never the external address.
