# snapshot-clone

```sh
nix develop .#talos --command just talos run snapshot-clone
```

Can each CI job, orb or thread machine start from a private copy-on-write
clone of a prepared environment? Production doesn't do this yet. The worker's
lab disk gets the setup
[patches/lvm-thin.yaml](../../patches/lvm-thin.yaml) gives it: Talos loads
`dm_thin_pool` and creates the volume group `lvmvg` (`LVMVolumeGroupConfig`).
The test installs OpenEBS LVM-LocalPV, whose chart brings the snapshot CRDs
and controller, with the thin class and snapshot class in
[manifests/snapshot-clone.yaml](../../manifests/snapshot-clone.yaml).

The test:

- **Bakes** an 8 GiB thin claim with the `nixos/nix` image's store and its
  database, and 100,000 small files.
- **Snapshots** it once its logical volume has closed.
- **Restores** it into `clone-1` and `clone-2`. Each passes
  `nix-store --verify --check-contents` and holds the bake's store paths and
  files, with the same checksum over the files' names and contents. Neither
  sees the other's marker file. `clone-1` writes less than a tenth of the
  bake's bytes to the lab disk.
- **Deletes** `clone-1`, which must not grow the thin pool.
- **Deletes the baked claim**, then restores `clone-3` from the snapshot.
  LVM-LocalPV keeps that claim's volume while the snapshot exists, so the
  test records its state instead of waiting for it to go.

`results.txt` records the bake's size and time, the time from claim to
completed pod for each clone, the bytes each wrote and discarded on the lab
disk (`/proc/diskstats`), and `lvs` at each step.
