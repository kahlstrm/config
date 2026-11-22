# Commission a Minisforum Talos worker

Firmware preparation and Talos maintenance-mode inspection are non-destructive.
Installation runs only through Terraform: `local-networking` gives the machine
its address and name, and a targeted `local-talos` apply wipes the node's disks,
applies its machine configuration and installs Talos. A maintainer first
confirms that nothing on the node's disks needs keeping. `talosctl` is used here
only to read inventory in maintenance mode; never apply a configuration or wipe
a disk with it by hand.

Use the firmware and menu names of the exact model and CPU; never flash one
model's firmware on another.

## Firmware and KVM

Use the KVM from the LAN. If it needs authentication, a maintainer signs in
locally; never paste credentials into a thread.

- `Delete` during POST opens firmware setup, `F7` the one-time boot menu.
  Repeat the key from reset. A black screen or a brief loss of HDMI during POST
  doesn't mean the machine is off.
- Record the existing settings, load optimized defaults, then apply the
  settings the worker needs. Save, reboot, and check the saved values.
- Keep runtime Turbo and dynamic frequency scaling; don't force clocks. Enable
  virtualization (VT-x, VT-d) and restore on AC power loss.
- The firmware must boot the Talos factory image; if it refuses the image's
  signature, adjust the boot security settings accordingly.
- Update firmware only from the vendor's official package for that model,
  after checking its published checksums. Never reset, remove power or media,
  or send input while flashing.

## Talos virtual media and maintenance inspection

Mount the workers' factory `metal-amd64.iso` for the Talos version in
`local-talos/versions.json` as CD/DVD in the KVM, and boot it from the one-time
boot menu. If URL-streamed media hangs, restart the KVM itself and use its
stored media instead. The ISO alone installs nothing.

With the node's maintenance-mode address in `NODE_IP`, collect read-only
inventory from `nix develop` in `infra/`:

```sh
for resource in processors.hardware.talos.dev memorymodules disks links pcidevices; do
  talosctl get "$resource" --insecure -n "$NODE_IP" -o yaml
done
```

Choose the install disk and any data disk from this inventory by serial, never
by NVMe numbering, and note the connected NIC's MAC.

## Commission with Terraform

Report each step's output to the requesting thread, and stop on anything the
step doesn't expect.

1. **MAC address.** A maintainer adds the connected NIC's MAC under `macs` in
   the `local-networking` Secret Manager secret with `just edit`.
2. **Lease and DNS.** Add the node to `k8s_worker_nodes` in `local-networking`;
   after merge, a maintainer plans and applies that layer. The plan adds only
   the node's DHCP lease and DNS records.
3. **Address.** The node keeps its dynamic address until its lease renews;
   wait for that, or boot the ISO again. Then confirm with maintenance-mode
   reads (`talosctl get links` and `get disks --insecure`) that it answers at
   its static address and lists the expected disk serials.
4. **Node entry.** Add the node to `workers` in `local-talos/main.tf`, with its
   disks by serial: `install_disk_serial`, user volume disk selectors, and
   `wipe_disk_serials` for disks that still hold old partitions.
5. **Plan and apply.** After merge, a maintainer runs a targeted plan of the
   node's `talos_machine.worker` from merged `main`. The plan adds only the
   node's disk wipe and its machine. The apply wipes the listed disks through
   the maintenance API, stops if a serial matches no disk or more than one,
   then installs Talos. Unmount the ISO once the node has booted from its disk.
6. **Checks.** `talosctl get systemdisk` shows the chosen disk, each user
   volume is ready, `talosctl health` passes, and the node is Ready with its
   labels and taints.

A taint is registered when the node first joins; changing it later takes
`kubectl taint` as well as the patch.
