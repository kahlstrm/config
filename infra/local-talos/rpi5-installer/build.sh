#!/usr/bin/env bash
# Builds the Raspberry Pi 5 Talos installer into <output-dir>/installer-arm64.tar:
# the upstream rpi_5 overlay with our U-Boot. Requires nix, crane, jq and docker.
set -euo pipefail

out=$(realpath "${1:?usage: build.sh <output-dir>}")
here=$(dirname "$(realpath "$0")")
versions=$here/../versions.json
talos=$(jq -er .talos "$versions")
overlay=ghcr.io/siderolabs/sbc-raspberrypi:$(jq -er .sbc_raspberrypi "$versions")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

u_boot=$(nix build --no-link --print-out-paths "$here/../..#rpi5-u-boot")/u-boot.bin

# The imager runs the overlay's options binary on the host and embeds the target-arch overlay.
for arch in amd64 arm64; do
  mkdir "$work/overlay-$arch"
  crane export --platform "linux/$arch" "$overlay" - | tar -x -C "$work/overlay-$arch"
  install -m 0644 "$u_boot" "$work/overlay-$arch/artifacts/arm64/u-boot/rpi_generic/u-boot.bin"
  tar -C "$work/overlay-$arch" -cf "$work/overlay-$arch.tar" .
done

# PoE does not negotiate a 5 A supply, so firmware refuses USB (recovery) boot without this.
host_arch=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
jq -n \
  --arg version "$talos" \
  --arg host "/work/overlay-$host_arch.tar" \
  '{
    baseProfileName: "installer",
    arch: "arm64",
    version: $version,
    input: {overlayInstaller: {tarballPath: "/work/overlay-arm64.tar"}},
    overlay: {
      name: "rpi_5",
      image: {tarballPath: $host},
      options: {configTxtAppend: "usb_max_current_enable=1"}
    }
  }' >"$work/profile.yaml"

docker run --rm -i -v "$work:/work:ro" -v "$out:/out" \
  "ghcr.io/siderolabs/imager:$talos" - <"$work/profile.yaml"

# Render the EFI files the installer writes on a node and compare them with the verified boot chain.
mkdir -p "$work/installer" "$work/node/boot/EFI"
tar -xf "$out/installer-arm64.tar" -C "$work/installer"
for layer in $(jq -r '.[0].Layers[]' "$work/installer/manifest.json"); do
  tar -xzf "$work/installer/$layer" -C "$work/installer" overlay 2>/dev/null || true
done
{
  printf 'mountPrefix: %s\nartifactsPath: %s\nextraOptions:\n' "$work/node" "$work/installer/overlay/artifacts"
  sed 's/^/  /' "$work/installer/overlay/extra-options"
} | "$work/overlay-$host_arch/installers/rpi_5" install
(cd "$work/node/boot/EFI" && sha256sum --check --strict "$here/verified-boot.sha256")
