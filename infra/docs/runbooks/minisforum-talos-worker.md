# Commission a Minisforum Talos worker

This procedure separates non-destructive firmware preparation and Talos
maintenance-mode inspection from installation. Installation runs only through
Terraform: `local-networking` gives the machine its address and name, and a
targeted `local-talos` apply wipes the node's disks, applies its machine
configuration and installs Talos ([Commission with Terraform](#commission-with-terraform)).
A maintainer must first confirm that nothing on the node's disks needs keeping.
`talosctl` is used here only to read inventory in maintenance mode; never
apply a configuration or wipe a disk with it by hand.

The recorded example is the MS-01 intended as `w3.k8s.kalski.xyz` in klusse.
An MS-A2 needs its own model- and CPU-specific BIOS and menu names; never flash
an MS-01 image on an MS-A2. Reinspect disk serials, NIC MACs and link state on
every machine instead of copying the example's hardware identifiers.

## Firmware and KVM

Open <http://jet.k8s.kalski.xyz/> from a browser on the kuberack LAN. If
authentication is needed, have a maintainer sign in locally; never paste
credentials into a thread. Focus the video before sending keyboard input.

MS-01 keys during POST:

- `Delete`: firmware entry; select **Setup**.
- `F7`: one-time boot device menu.
- Repeat the key from reset until the menu appears. A black screen or transient
  **No HDMI signal** during POST is not evidence that the machine is off.
  Check power and KVM status before resetting again.

Record the existing settings before **Save & Exit → Load Optimized Defaults**.
Then apply the settings below, **Save Changes and Reset**, and inspect the
saved values after a reboot. Dropdowns can be selected with arrow keys and
Enter; verify the displayed value before leaving the page.

### BIOS version and download verification

The MS-01 reported American Megatrends BIOS **1.27**, built
**2025-04-03 17:14:59** (core 5.27, UEFI 2.8 / PI 1.7). The
[official support page](https://www.minisforum.com/pages/product-info) still
listed 1.27 as the newest MS-01 BIOS when checked on 2026-11-21. Thus the old
and final version are both **1.27**: no flash was needed or started.

The official page linked
[MS-01-AHWSA-V1.27_4_28_V2.zip](https://pc-file.s3.us-west-1.amazonaws.com/ms-01/Bios/MS-01-AHWSA-V1.27_4_28_V2.zip).
The downloaded ZIP passed `unzip -t` and had SHA-256:

```text
cf6710534f1de22f0f94515a0bd91b6d95d78e002a060cbe85dfd788865e57d6
```

The included `Release_Note.txt` publishes BIOS checksum `4CE9`. Summing all
bytes of `AHWSA.1.27_250403/AHWSA.bin` modulo 65536 gave `4CE9`. This is a
vendor checksum match, not a cryptographic signature; the ZIP SHA-256 above
is a locally recorded digest, not an independently published trust anchor.
The release notes say C-state support arrived in 1.26.

For a future machine that actually needs an update, download only its exact
model/CPU package from official support and check published checksums or
signatures. Prepare a FAT32 USB disk image containing the extracted update
and an x86-64 UEFI shell at `EFI/BOOT/BOOTX64.EFI`. The 1.27 ZIP contains
`AfuEfix64.efi` and `AfuEfiFlash.nsh`, but **does not contain a UEFI shell**;
obtain the shell from a trusted TianoCore release and record its provenance
and digest. Mount the image in JetKVM as **Disk** (USB mass storage), use F7
to boot it, find its filesystem with `map -r`, `fs0:`, `ls` (or `fs1:`, etc.),
change to the extracted update directory, and run the package's `.nsh`
script. For this package it is `AfuEfiFlash.nsh`; inspect it before execution.
Do not substitute scripts or firmware from another model.

Never reset, remove power/media or send more input while flashing. Wait for
the automatic reboot and POST, which may take several minutes. If a flash
reports an error, stop and report the screen rather than retrying. Once POST
returns, confirm the new version, load defaults, then reapply and verify the
server settings. No FAT32 flash image was made for w3 because it was current.

### BIOS settings

Paths below start at **Setup**. Preserve runtime Turbo and dynamic frequency
scaling; do not force high clocks. Boot performance is only the initial
pre-OS state, not a runtime CPU-frequency cap.

| Setting | Menu path | Before | After | Reason |
| --- | --- | --- | --- | --- |
| Optimized defaults | Save & Exit → Load Optimized Defaults | Existing settings | Loaded | Establish the vendor baseline before server tuning. |
| Boot performance mode | Advanced → CPU Configuration | Turbo Performance | Max Battery | Start at a low-power state; let the OS manage runtime frequency. |
| HD Audio | Advanced → Onboard Devices settings | Enabled | Disabled | Unused on this worker. |
| Restore On AC Power Loss | Advanced → ACPI settings | Always Off | Always On | Recover unattended after loss of AC. |
| Secure Boot | Security → Secure Boot → Secure Boot | Enabled | Disabled | The workers' schematic builds a metal image that the firmware's Secure Boot keys reject. Confirmed Disabled after a reboot. |
| PCIE4.0x4 SSD ASPM | Advanced → Onboard Devices settings → SA-PCIE PORT | Disabled | L0sL1 | Permit the available PCIe link low-power states. |
| I226-V NIC ASPM | Advanced → Onboard Devices settings → PCH-PCIE PORT | Disabled | Auto | Allow firmware to configure supported link power saving. |
| PCIE3.0x4 SSD ASPM | Advanced → Onboard Devices settings → PCH-PCIE PORT | Disabled | Auto | Allow firmware to configure supported link power saving. |
| PCIE3.0x2 SSD ASPM | Advanced → Onboard Devices settings → PCH-PCIE PORT | Disabled | Auto | Allow firmware to configure supported link power saving. |
| I226-LM ASPM | Advanced → Onboard Devices settings → PCH-PCIE PORT | Disabled | Auto | Allow firmware to configure supported link power saving. |

Already enabled and retained: VT-d, Intel VMX (VT-x), Hyper-Threading,
Intel SpeedStep (EIST), Intel Speed Shift, C states, Turbo Mode and Wake Up
On LAN. All P-cores and E-cores remain enabled. Boot entries remain UEFI;
the one-time virtual-media choice does not change persistent boot order.
Deep S5 remains disabled, preserving wake capability. No fixed CPU ratios,
memory speed or power limits were set.

The exposed menus did not offer a package C-state limit, native PCIe power
management switch, Wi-Fi/Bluetooth disable switch or serial-port switch.
PCIe slot ASPM and X710 NIC ASPM were greyed out as Disabled; they were not
forced. Enabled C states is not proof that the running system reaches its
deepest package state: measure residency and wall power after installation.

## Talos virtual media and maintenance inspection

The existing workers have no extensions. `infra/local-talos/main.tf` declares
the factory schematic as `customization: {}`. Posting that schematic to
`https://factory.talos.dev/schematics` returned:

```text
376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
```

Mount this exact image in JetKVM **Virtual Media → Add New Media → URL
Mount → Continue**, as **CD/DVD**:

```text
https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.14.4/metal-amd64.iso
```

Use F7 and choose **UEFI: JetKVM Virtual Media**, or use the same entry under
**Save & Exit → Boot Override**. Wait for the Talos dashboard to show
maintenance mode. Read the DHCP address and linked NIC's MAC there. The ISO
alone does not install Talos; do not send a machine configuration yet.

With the node's current address in `NODE_IP`, collect read-only inventory:

```sh
talosctl version --client
for resource in processors.hardware.talos.dev memorymodules disks links pcidevices; do
  talosctl get "$resource" --insecure -n "$NODE_IP" -o yaml
done
```

If needed, use `nix develop` from `infra/` for `talosctl`. Record RAM module
part numbers and sizes, disk serials/models/sizes and existing partitioning,
and all NIC MACs, drivers and carrier state. Choose the installation disk and
separate orb-storage disk from this inventory, not from guessed NVMe numbering.

## Problems encountered

- The initial console showed Windows first-run setup. `Shift+F10` opened its
  command prompt. `shutdown /r /fw /t 0` failed with Windows error 203;
  ordinary restart was used instead. Windows later delayed a requested
  shutdown (error 1115 on another request). JetKVM's ATX extension exposes
  **Reset**, which was used to return to POST; never do this during a flash.
- The ISO initially failed with **Secure Boot Violation / Invalid signature
  detected**. A setup entry reached after the failure had greyed-out Secure
  Boot controls. Resetting and deliberately pressing Delete during POST
  exposed the editable control. Selecting Disabled with ArrowUp and Enter
  showed the changed value, and **Save Changes and Reset** kept it: setup
  showed Secure Boot Disabled after the reboot, and the ISO then booted. No
  Secure Boot keys were deleted and no BIOS password was set.
- Browser connectivity occasionally dropped. After reconnecting, inspect
  the current screen before repeating any action: a disconnected tool call
  may already have taken effect.
- Firmware screens and POST can remain black or lose HDMI temporarily.
  Do not infer a powered-off host from that alone.
- URL-streamed virtual media hung at a black screen. Later stored-media
  mount attempts also hung; repeated boot attempts did not resolve it.
  **JetKVM Settings → General → Reboot Device** cleared the virtual-media
  state. This restarts the KVM, not the host; never do it during flashing.
  After reconnecting, upload the ISO to JetKVM's stored media and mount it
  as **CD/DVD**, rather than resuming the URL stream. The working stored
  filename was `talos-v1.14.4-metal-amd64.iso`.
- The browser file-upload interface rejected files larger than 50 MB; the
  ISO is 364,195,840 bytes. A temporary HTTP server bound to
  `127.0.0.1:8765` served the downloaded ISO with CORS restricted to
  `http://jet.k8s.kalski.xyz`. In the laptop browser, fetching it as a Blob,
  wrapping it in a File, and assigning it through DataTransfer to the
  upload input before dispatching its change event used JetKVM's normal
  upload path without the browser tool's upload-size limit. This was a
  local upload workaround, not a public ISO mirror. The temporary server
  was stopped after upload; JetKVM keeps its stored copy independently.
  The downloaded ISO SHA-256 was
  `3571abef273960a9e070c8d12607f6801a2e5619a7a823cdb9852dd5d04575fb`.
- With stored media mounted after the KVM restart, a fresh BIOS
  **Save Changes and Reset**, then F7 and the UEFI virtual-media entry,
  booted Talos successfully after roughly 45 seconds. The ISO remains
  mounted and the MS-01 remains in maintenance mode. No machine config
  was applied, no firmware was flashed, and neither disk was wiped.
- The requested comma-separated `talosctl get` resource list did not work
  with the installed 1.14.3 client, and `cpus` was ambiguous. The separate
  resource commands above worked, including the fully qualified processor
  resource name.

## Inventory

The maintenance dashboard and API reported `10.10.10.254/24` from the pool,
gateway and DNS `10.10.10.1`. That address is a dynamic lease and changes
once the static lease exists. The connected NIC reaches a CRS305 SFP+ port at
10G; which port was not recorded.

| Hardware | Recorded inventory |
| --- | --- |
| BIOS | American Megatrends 1.27, the newest MS-01 release; Secure Boot off, VT-x and VT-d on |
| CPU | Intel Core i5-12600H, 12 cores / 16 threads (Hyper-Threading on), maximum 4500 MHz |
| RAM | One 32768 MiB Micron CT32G56C46S5.M8BA module, serial EB7CE510; SMBIOS speed 5600; second slot empty; dashboard 31 GiB usable |
| System disk | Micron MTFDKBA256TFK (2450), 256060514304 bytes, serial 220535669A25, firmware 7003V5LN; observed as nvme0n1 |
| `orb-storage` disk | KINGSTON OM8TAP41024K1-A00, 1024209543168 bytes, serial 50026B7384341BE2, firmware P4ER3B31; observed as nvme1n1 |
| Connected NIC | Intel X710, enp2s0f0np0, 38:05:25:35:28:48, PCI 02:00.0, i40e, 10G full duplex DirectAttach, carrier up |
| Other X710 port | enp2s0f1np1, 38:05:25:35:28:49, PCI 02:00.1, i40e, carrier down |
| Intel I226-V | enp87s0, 38:05:25:35:28:4a, PCI 57:00.0, igc, carrier down |
| Intel I226-LM | enp89s0, 38:05:25:35:28:4b, PCI 59:00.0, igc, carrier down |
| Other devices | MT7922 Wi-Fi at PCI 5a:00.0 with no network driver or link; AMT SOL remains enumerated; audio absent after the BIOS disable |

Both disks still hold old partition tables: the Micron a Microsoft reserved
partition, the Kingston a Windows EFI system, reserved, data and recovery
partition that fill it. A maintainer confirmed that nothing on either disk
needs keeping. The node's entry in `infra/local-talos/main.tf` names both
disks by serial, never by NVMe number: the system disk in
`install_disk_serial`, the `orb-storage` user volume in its disk selector,
and both in `wipe_disk_serials`.

## Commission with Terraform

The node is `w3.k8s.kalski.xyz` at `10.10.10.23`: a worker with the workers'
installer image and patches (the user-namespace sysctl included), the label
`orbs.kalski.xyz/pool=dedicated` and the taint
`orbs.kalski.xyz/pool=dedicated:NoSchedule`
([orb-dedicated-worker.yaml](../../local-talos/patches/orb-dedicated-worker.yaml)),
and an `orb-storage` user volume on the Kingston. Report each step's output
to the requesting thread, and stop on anything the step does not expect.

1. **MAC address.** On a maintainer's machine, add the connected NIC's MAC
   to the `local-networking` Secret Manager secret, beside the other nodes'
   entries under `macs`:

   ```sh
   cd infra/local-networking
   just edit   # add "w3_k8s": "38:05:25:35:28:48" under "macs"
   ```

   Until it exists, every `local-networking` plan fails on the missing key.

2. **Lease and DNS.** After the `local-networking` change merges, a
   maintainer plans and applies `local-networking` from their machine
   ([Applying Changes](../../AGENTS.md#applying-changes)). For this node
   the plan adds three resources and changes or destroys nothing:

   - `module.kuberack.module.rb5009.module.dhcp_lan.routeros_ip_dhcp_server_lease.static_lease["w3.k8s.kalski.xyz"]`
   - `module.kuberack.module.rb5009.module.dns.routeros_ip_dns_record.a_record["w3.k8s.kalski.xyz"]`
   - `module.stationary.module.rb5009.module.dns.routeros_ip_dns_record.a_record["w3.k8s.kalski.xyz"]`

   Changes from other merged PRs may appear beside them; compare those with
   their own rollouts.

3. **Address.** The node renews its lease within the 30-minute lease time
   and moves to `10.10.10.23`. To move it sooner, reset it from JetKVM and
   boot the mounted ISO again with F7 and the UEFI virtual-media entry.
   Confirm the address and the disks with maintenance-mode reads:

   ```sh
   talosctl get links --insecure -n 10.10.10.23 -o yaml | grep -A1 'hardwareAddr: 38:05:25:35:28:48'
   talosctl get disks --insecure -n 10.10.10.23
   ```

   The disks must list serials `220535669A25` and `50026B7384341BE2`.

4. **Plan the node.** After the `local-talos` change merges, a maintainer
   runs from merged `main`, in `nix develop` from `infra/` so that `talosctl`
   and `jq` are on `PATH`:

   ```sh
   cd infra/local-talos
   terraform init
   terraform plan -target='module.cluster.talos_machine.worker["w3.k8s.kalski.xyz"]' -out=w3.tfplan
   ```

   The plan adds two resources and changes or destroys nothing:

   - `module.cluster.module.wipe_disks["w3.k8s.kalski.xyz"].terraform_data.this`,
     with the two serials above;
   - `module.cluster.talos_machine.worker["w3.k8s.kalski.xyz"]`, on node
     `10.10.10.23` with the workers' factory installer image
     (`factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.4`).

   Its machine configuration is sensitive in the plan, and state holds none
   for w3 before its first apply. To review it, render it from a plan with
   `terraform console -plan` in the same directory:
   `nonsensitive(module.cluster.machine_configurations["w3.k8s.kalski.xyz"])`.
   It must show `diskSelector` with serial `220535669A25` and no `disk`
   path, the `orbs.kalski.xyz/pool` label, `registerWithTaints`, and the
   `orb-storage` `UserVolumeConfig` selecting `50026B7384341BE2`.

5. **Apply.** `terraform apply w3.tfplan`. Terraform first wipes both disks
   through the maintenance API, resolving each serial to its device. It
   stops before configuring the node if a serial matches no disk or more
   than one, or if the node is no longer in maintenance mode. It then
   applies the configuration; Talos installs onto the Micron, reboots and
   joins the cluster. Once the node has rebooted from its disk, unmount the
   ISO in JetKVM; unmounting earlier pulls the running maintenance system
   from under it.

6. **Checks**, with a maintainer's `talosconfig` and kubeconfig:

   ```sh
   talosctl -n 10.10.10.23 get systemdisk                 # the Micron, serial 220535669A25
   talosctl -n 10.10.10.23 get volumestatus u-orb-storage # phase ready, on the Kingston
   talosctl -n 10.10.10.11 health
   kubectl get node w3.k8s.kalski.xyz -L orbs.kalski.xyz/pool
   kubectl get node w3.k8s.kalski.xyz -o jsonpath='{.spec.taints}'
   ```

   The node is Ready with the label, and its taints include
   `orbs.kalski.xyz/pool=dedicated:NoSchedule`. Only pods that tolerate the
   taint schedule there, so DaemonSets without a matching toleration skip
   the node.

The taint is registered when the node first joins. NodeRestriction stops the
kubelet from changing its own taints afterwards, so on a joined node a change
to the taint takes `kubectl taint` as well as the patch.
