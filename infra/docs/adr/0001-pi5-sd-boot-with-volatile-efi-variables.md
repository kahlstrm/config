# 1. Keep sd-boot on the Pi 5 control planes with volatile EFI variables

- Status: accepted
- Date: 2026-10-25

## Context

The Raspberry Pi 5 control planes boot through the Pi firmware, then U-Boot
from [kahlstrm/u-boot](https://github.com/kahlstrm/u-boot), which provides
UEFI, then systemd-boot (sd-boot) and a Talos UKI. Talos installers choose
sd-boot on any UEFI boot, and upgrades keep the boot loader found on disk.
Upstream's Pi disk images use GRUB instead (`bootloader: grub` in
sbc-raspberrypi's profiles), so upstream rarely tests sd-boot on a Pi.

On every install and upgrade, Talos's sd-boot installer writes EFI variables
before running the board installer, which writes U-Boot, the device trees and
`config.txt`:

- `LoaderEntryDefault`: the UKI to boot.
- `LoaderConfigTimeout`: the menu timeout.
- `Boot####`: a firmware boot entry named `Talos Linux UKI`.

The Pi has no firmware-owned flash for EFI variables. U-Boot keeps them in a
file on the EFI partition and cannot write it once Linux owns the disk. Built
without runtime variable support, U-Boot refuses runtime writes, `efivarfs` is
read-only, and the installer stops before the board step, yet the node reboots
into the new UKI with the old U-Boot and device trees.

U-Boot's `CONFIG_EFI_RT_VOLATILE_STORE` accepts runtime writes into memory and
exposes the updated store as the `VarToFile` variable for the OS to save.
Talos does not save it, so the writes last only until the next reboot.

## Decision

Keep sd-boot. Build U-Boot with `CONFIG_EFI_RT_VOLATILE_STORE=y`, so installs
and upgrades complete, including the board step, and accept that EFI
variables written from Talos do not persist.

Moving to GRUB would mean wiping and reinstalling each control plane, as Talos
cannot change the boot loader in place. Reconsider when a control plane is
reinstalled anyway, when Talos saves `VarToFile`, or if upstream drops sd-boot
on arm64 boards.

## Consequences

Without `LoaderEntryDefault`, sd-boot sorts the Talos UKIs by version and
boots the newest. Talos keeps two on the EFI partition: the one it booted and
the one it installs.

- Upgrades to a newer Talos version work.
- Rollback does not: automatic revert after a failed boot and
  `talosctl rollback` both write `LoaderEntryDefault`, which is lost on reboot,
  so the newer UKI boots again.
- Downgrades do not take effect: the newer UKI still sorts first, and the
  Terraform provider times out waiting for the old version.
- Reinstalling the same version with a different UKI, such as a schematic
  change, does not take effect: the new file `Talos-<version>~1.efi` sorts as
  older than `Talos-<version>.efi`. U-Boot, the device trees and `config.txt`
  are outside the UKI and are still updated.
- The sd-boot menu waits 10 seconds (`loader.conf`) instead of 5.
- The missing `Boot####` entry is harmless; U-Boot falls back to
  `EFI/boot/BOOTAA64.efi`, which is sd-boot.

To boot a different UKI, use the UART console:

1. Select the entry in the sd-boot menu. This lasts one boot.
2. While booted from it, reinstall the wanted version, for example with
   `talosctl upgrade --image <installer>`. Talos keeps the booted UKI and
   removes the other one.

This is why upgrades of the Pi control planes require the UART console; see
[OS upgrades](../../local-talos/README.md#os-upgrades).
