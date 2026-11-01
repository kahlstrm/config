# Send single-buffer frames from the Pi 5 control planes

- Status: accepted
- Date: 2026-11-01

## Context

The Pi 5 control planes' Ethernet (`end0`: Cadence GEM in the RP1 southbridge,
driven by `macb`) sometimes stops sending. The queue is non-empty but the MAC
neither transmits nor reports completions until something kicks it again. The
Talos v1.14 kernel (kernel.org 6.18 plus
[siderolabs/pkgs patches 0001–0003](https://github.com/siderolabs/pkgs/tree/release-1.14/kernel/build/patches))
runs a 1 s watchdog that restarts the queue and logs
`TX stall detected on queue 0 (tail=… head=…); re-kicking TSTART`. Each stall
froze sends for 1–2 s, longer than etcd's 1 s election timeout. In October
2026 every Pi stalled 25–30 times an hour and etcd changed leader about 30
times an hour.

There is no upstream root-cause fix. Upstream suspects a doorbell (`TSTART`)
write to the MAC that gets lost over PCIe, or a completion interrupt that is
missed:

- Mainline's only change is
  [e438ec3e9e95](https://git.kernel.org/linus/e438ec3e9e95) (v7.2, 6.18.40),
  which restarts the queue from `ndo_tx_timeout`. Its message says the root
  cause "is not yet fully understood". That timeout fires only after the
  queue has been stopped for 5 s, so on its own it gives longer freezes than
  the watchdog.
- Raspberry Pi reverted a similar watchdog and a register read-back after a
  completion check
  ([raspberrypi/linux#7472](https://github.com/raspberrypi/linux/pull/7472)).
  Candidate fixes are open and unmerged
  ([raspberrypi/linux#7667](https://github.com/raspberrypi/linux/pull/7667)).
  Our kernel already has the read-back that #7667 adds (Talos patch 0002) and
  stalled anyway.
- Users report that turning off TCP segmentation offload and scatter-gather
  avoids the stalls, and that turning off segmentation offload alone does not
  ([LP #2133877](https://bugs.launchpad.net/ubuntu/+source/linux-raspi/+bug/2133877),
  [cilium/cilium#43198](https://github.com/cilium/cilium/issues/43198)).

How the driver queues a frame explains why those features matter. With
scatter-gather or segmentation offload on, a TCP frame from the host network
takes two or more buffer descriptors: headers and payload pages, or an
offload header plus payload. Without scatter-gather, every frame is one linear
buffer and one descriptor, because the 1500-byte MTU is far below GEM's
16,320-byte buffer limit. The kernel drops segmentation offload and generic
segmentation offload whenever scatter-gather is off, so turning off
scatter-gather alone gives the same result.

Stalls tracked Flannel's VXLAN (`flannel.1`) packets: about one per 1,150.
`macb` declares no offloads for tunnelled packets (`hw_enc_features`), so the
kernel already sends VXLAN frames as single linear buffers with software
checksums. More VXLAN traffic is therefore not more multi-descriptor frames;
it comes with the flows that are multi-descriptor, or makes the race more
likely some other way. That part is unexplained.

Measured on 2026-11-01. The change took effect on c2 at 18:24Z, on c1 at 20:26Z
and on c3 at 20:28Z. The baseline window is 16:55–18:24Z, the c2-only window
18:26–20:25Z, and the all-nodes window 20:29–21:20Z:

| | Before | After |
| --- | --- | --- |
| Stalls per Pi | 25–30 an hour | c2: 0 in 3 h; c1 and c3: 1 each in under 1 h |
| etcd leader changes | 43 in 89 min | 12 in 119 min with only c2 changed; 0 in 51 min with all three |
| API server → etcd request p99 | 494 ms | 22 ms |
| etcd peer round-trip p99 | 170–200 ms | 13–38 ms |
| softirq / system CPU per Pi | 0.35–0.40% / 1.5–1.8% | unchanged |

The two later stalls were real: etcd logged `ReadIndex` retries and applies of
1.1 s on c1 and 1.8 s on c3 at the same moments. Single-buffer frames
therefore make the race much rarer but do not remove it. The workaround leaves
c1 and c3 with an expected rate of about 0.5 an hour, so c2's 3 clean hours
are not evidence that c2 differs.

The Pis send about 1 Mbit/s on average and under 10 Mbit/s at peak, so the
cost of copying payloads into linear buffers does not show. Throughput near
line rate was not measured.

## Decision

Keep sending single-buffer frames from the Pi 5 control planes, using the
`EthernetConfig` in
[rpi5-ethernet-offloads.yaml](../../local-talos/patches/rpi5-ethernet-offloads.yaml).
Turning off segmentation offload as well as scatter-gather is redundant but
harmless, and states the intent.

Do not carry kernel patches in the Pi 5 installer. Talos builds the kernel
from siderolabs/pkgs rather than the overlay, so a patch would mean building
our own kernel and keeping it in step with every Talos release. No candidate
patch has been shown to remove the stall.

Revisit when a Talos release's kernel carries a root-cause fix accepted
upstream (watch raspberrypi/linux#7667 and netdev `macb` changes), when the
Pis need sustained throughput near line rate, or when the remaining stalls
cause etcd elections again.

## Consequences

- About 0.5 stalls an hour per Pi remain, each freezing sends for 1–2 s.
  Expect a rare etcd election or a slow request.
- Every frame's payload is copied into one buffer by the CPU. That is
  negligible at the control planes' traffic, but limits throughput near line
  rate.
- The workaround depends on the NIC, not the CNI. Cilium in its default VXLAN
  mode
  ([the Cilium ADR](0011-replace-flannel-with-cilium.md)) sends the same kind
  of frames, so keep the `EthernetConfig` through and after the migration.
- Talos's watchdog stays the recovery path. Without it, recovery would rely
  on the 5 s `ndo_tx_timeout`.
