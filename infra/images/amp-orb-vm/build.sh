#!/usr/bin/env bash
# Builds the orb VM image into <out>: disk.qcow2 (read-only root filesystem labelled
# orb-root, booted with root=LABEL=orb-root ro), vmlinuz and
# initrd.img for KubeVirt's kernel boot, and the containerDisk Containerfile.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "$1" && cd "$1" && pwd)

docker build --platform linux/amd64 -f "$here/Containerfile" -t amp-orb-vm-rootfs "$here"
container=$(docker create --platform linux/amd64 amp-orb-vm-rootfs)
root=$(mktemp -d)
trap 'docker rm -f "$container" >/dev/null; sudo rm -rf "$root"' EXIT

# Under sudo's umask, directories missing from the export would be created 0700.
docker export "$container" | sudo sh -c "umask 022 && tar -x -p -C '$root'"
sudo chmod 0755 "$root"
# Docker bind-mounts /etc/resolv.conf during builds, so point it at resolved's stub here.
sudo ln -sfn ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
sudo cp -L "$root/boot/vmlinuz" "$root/boot/initrd.img" "$out/" 2>/dev/null ||
  sudo cp -L "$root/vmlinuz" "$root/initrd.img" "$out/"
truncate -s 16G "$out/rootfs.img"
sudo mkfs.ext4 -q -F -L orb-root -d "$root" "$out/rootfs.img"
# Uncompressed: guest reads skip zlib, and the zstd layer compresses it better.
qemu-img convert -O qcow2 "$out/rootfs.img" "$out/disk.qcow2"
rm "$out/rootfs.img"
sudo chown "$(id -u):$(id -g)" "$out"/*
cp "$here/Containerfile.disk" "$out/Dockerfile"
