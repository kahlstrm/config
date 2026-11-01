# 10. Run agent VMs on QEMU's q35 machine type

- Status: accepted
- Date: 2026-11-01
- Related: [ADR 9](0009-approval-capped-ops-environment.md)

## Context

microvm.nix defaults `microvm.qemu.machine` to QEMU's `microvm` machine type on
x86_64, whose devices are virtio-mmio. Its documentation lists `microvm` or
`q35` as values, and its CHANGELOG says to set `q35` if the `microvm` default
breaks.

The ops VM's first boot (ADR 9) hung in the initrd store seed, where
`agent-store-seed` copies about 2.8 GiB onto the empty `/nix` volume. Every
guest writer was blocked in `blk_mq_get_tag`. QEMU had completed and signalled
every request on `vdd` (avail idx = used idx = signalled-used = 2045), but the
guest's `used_event` stayed at 1956: the guest never handled the completion
interrupt. On the `microvm` machine type, virtio-mmio completion interrupts are
sometimes lost.

Reproduced on pannu with the pre-fix ops guest:

| Machine type, images | Seed stalled |
|---|---|
| `microvm`, sparse | 1 of 3 |
| `microvm`, preallocated | 1 of 4 |
| `microvm`, preallocated, direct I/O | 1 of 5 |
| `microvm`, preallocated | 1 of 4 |
| `q35`, preallocated | 0 of 14 |

Sparse images and host buffering are ruled out. At the `microvm` rate, 14 clean
`q35` boots would happen by chance about 2% of the time. Whether QEMU or the
guest kernel loses the interrupt is unconfirmed.

The agents VM's one previous full seed (2026-10-13, 30 s) happened not to hang.
All VM tests boot through the NixOS test driver on virtio-pci, so CI never ran
virtio-mmio.

## Decision

Run agent VMs on `q35` (`microvm.qemu.machine = "q35"` in
`modules/agents/vm/guest.nix`), where virtio-pci devices signal completions
through MSI-X. Introduced in kahlstrm/config#252.

Revisit when upstream fixes virtio-mmio interrupt delivery, or when a CI test
that boots through microvm.nix's runner can show that `microvm` is safe again.

## Consequences

- QEMU emulates a slightly larger device model.
- Guest devices get PCI names. Nothing broke: guest NICs match on MAC and disks
  on virtio serial.
- The bug is avoided, not fixed upstream.
- VMs pick up `q35` only on their next restart; the agents VM still needs one.
