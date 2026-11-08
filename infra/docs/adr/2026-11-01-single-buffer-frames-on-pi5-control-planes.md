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
| Stalls per Pi | 25–30 an hour | to 15:00Z on 2026-11-02: c1 4 in 19 h, c2 2 in 21 h, c3 32 in 19 h |
| etcd leader changes | 43 in 89 min | 2 in 18 h from 21:00Z, each after a stall on the leader |
| API server → etcd request p99 | 494 ms | 22 ms |
| etcd peer round-trip p99 | 170–200 ms | 13–38 ms |
| softirq / system CPU per Pi | 0.35–0.40% / 1.5–1.8% | unchanged |

The later stalls are real. At each one, etcd on that node logged `ReadIndex`
retries and applies of 1–2 s. Single-buffer frames therefore make the race
rarer but do not remove it.

From 2026-11-02 to 2026-11-06, c3 stalled about 45 times a day; c1 and c2
stalled 4–5 times a day each. Nothing measured explained the difference:

- c3 was never the etcd leader and sends the fewest packets: 231 a second,
  against 253 and 275 for c1 and c2.
- c3's VXLAN traffic and CPU are the same as the others'.
- c2 and c3 are both board Rev 1.1; c1 is Rev 1.0.
- None of the three shows link flaps or interface errors.

Before the change all three stalled at about the same rate.

On 2026-11-06 at 20:45Z, c2's and c3's cables were swapped at the Pi end, to see
whether the high rate followed the cable and switch port or stayed with c3. The
Pis are powered over Ethernet, so the swap also cold-booted both. In the next
24 h, c1 stalled 2 times, c2 3 times and c3 3 times. The high rate followed
neither the cable nor the board; it disappeared with c3's reboot. A state that
builds up on a running Pi, and that a power cycle clears, is the likeliest
explanation, but the swap cannot tell it from the change of cable.

When c3 stalls, it also stops hearing the leader for over a second. It starts
a pre-vote, gets no votes and follows the same leader again within about
350 ms. etcd's pre-vote keeps those events from moving leadership, so only
requests served by c3 wait 1–2 s. Real leader changes come only from stalls on
the leader.

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
move etcd leadership often again.

## Consequences

- Stalls continue, each freezing the node's traffic for 1–2 s: about 3–5 a
  day on each Pi. Expect slow requests on the stalling node, and an
  occasional leader change when the leader stalls.
- If one Pi's rate climbs well above the others' again, power-cycle it on its
  own, which keeps etcd's quorum, before suspecting the hardware. Unplugging a
  Pi's cable cuts its power, so move at most one control plane's cable at a
  time.
- Every frame's payload is copied into one buffer by the CPU. That is
  negligible at the control planes' traffic, but limits throughput near line
  rate.
- The workaround depends on the NIC, not the CNI. Cilium in its default VXLAN
  mode
  ([the Cilium ADR](0011-replace-flannel-with-cilium.md)) sends the same kind
  of frames, so keep the `EthernetConfig` through and after the migration.
- Talos's watchdog stays the recovery path. Without it, recovery would rely
  on the 5 s `ndo_tx_timeout`.
