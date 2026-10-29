# netpol-baseline

```sh
nix develop .#talos --command just talos run netpol-baseline
```

Production's stack: Talos's Flannel with the kube-network-policies sidecar
([flannel-controlplane.yaml](../../../../modules/talos-cluster/cni/flannel-controlplane.yaml))
and kube-proxy.

The test asserts:

- Without a policy, every probe connects to the external address and the echo
  pod at +0, +1 and +3 s.
- Under the pod-network-and-DNS policy, the echo pod connects at every offset.
- The known window of
  [ADR 4](../../../../docs/adr/0004-network-policies-apply-seconds-after-pod-start.md):
  at least one probe reaches the external address with its first packet, and
  none reach it at +3 s. If no first packet gets through any more, the test
  fails so that ADR 4 and this baseline are updated together.
- Both policy shapes, production's `namespaceSelector` and the earlier
  `ipBlock`, allow the echo pod, its Service and DNS, and block the external
  address.

It also runs the [cilium](../cilium/README.md) scenario's packet-socket check
and records the results without asserting them.
[ADR 2](../../../../docs/adr/0002-no-node-wide-packet-sockets-under-network-policies.md)
expects allowed connections that leave the node to be dropped once the policy
applies, but the lab has not reproduced that with either socket holder.
`results.txt` records the worker's kernel and
`net.bridge.bridge-nf-call-iptables` next to the results.

The +0 and +1 s counts can vary between runs; `results.txt` records them.
