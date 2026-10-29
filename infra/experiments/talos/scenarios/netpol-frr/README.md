# netpol-frr

```sh
nix develop .#talos --command just talos run netpol-frr
```

Production's stack, Flannel with kube-network-policies, with production's
MetalLB HelmRelease switched to its FRR mode (`speaker.frr.enabled: true`),
the setup that broke traffic from policed pods in production (#115, reverted
in #116;
[ADR 2](../../../../docs/adr/0002-no-node-wide-packet-sockets-under-network-policies.md)).
FRR's `bfdd` holds an `ETH_P_IP` (`0800`) packet socket on every interface.
The [netpol-baseline](../netpol-baseline/README.md) packet-socket check's
stand-ins hold `ETH_P_ALL` (`0003`) sockets and do not reproduce the drop.

1. The test fails unless FRR holds a node-wide packet socket on the workers
   (`/proc/net/packet`), and records the FRR daemons on a worker.
2. **flannel-frr**: for 60 seconds, the [CNI migration scenarios](../../README.md#cni-migration-scenarios)'
   policed probers, long-running pods that report to the host over allowed
   egress, must not get a single report through. Fresh probes in `np-allow`,
   whose policy allows the external address, must reach neither it nor the
   echo pod on another node three seconds after they start; before the policy
   applies (ADR 4) they do. Fresh probes in `np-policed` are recorded.
3. The [cilium-migration](../cilium-migration/README.md) cutover, with FRR
   still running; the socket check again.
4. **cilium-frr**: every signal up, including the policed probers. Fresh
   `np-allow` probes reach the external address and the echo pod at +0, +1 and
   +3 s; fresh `np-policed` probes reach the echo pod but never the external
   address.

If the drop stops happening on Flannel, the test fails so that ADR 2 and this
scenario are updated together.
