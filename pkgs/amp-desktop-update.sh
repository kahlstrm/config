#!/usr/bin/env bash
# Bumps pkgs/amp-desktop.nix to the newest .deb in Amp's apt repository, and
# fails if that .deb bundles a different amp-passkey-helper or Electron major
# than the package builds, since those need manual edits.
set -euo pipefail

nix_file="$(dirname "$0")/amp-desktop.nix"
index_url="https://static.ampcode.com/linux/dists/stable/main/binary-amd64/Packages"

index="$(curl -fsSL "$index_url")" || { echo "failed to fetch $index_url" >&2; exit 1; }
# The index can list several versions; the last stanza is the newest.
version="$(awk '/^Version:/ {v=$2} END {print v}' <<<"$index")"
sha256="$(awk -v v="$version" '/^Version:/ {cur=$2} /^SHA256:/ && cur==v {print $2}' <<<"$index")"
[[ -n "$version" && -n "$sha256" ]] || { echo "no version or SHA256 in $index_url" >&2; exit 1; }

current="$(sed -nE 's/^  version = "([^"]+)";/\1/p' "$nix_file")"
if [[ "$version" == "$current" ]]; then
  echo "amp-desktop is already at $version"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
deb="$work/amp-desktop.deb"
curl -fsSL -o "$deb" "https://static.ampcode.com/linux/$version/amp-desktop-$version-amd64.deb" \
  || { echo "failed to download the $version .deb" >&2; exit 1; }
echo "$sha256  $deb" | sha256sum -c --quiet - || { echo "downloaded .deb does not match the index SHA256" >&2; exit 1; }

(cd "$work" && ar x "$deb" && tar xf data.tar.* ./opt/amp/amp-desktop ./opt/amp/resources/amp-passkey-helper.NOTICE)
helper="$(sed -nE '1s/^amp-passkey-helper ([0-9.]+) .*/\1/p' "$work/opt/amp/resources/amp-passkey-helper.NOTICE")"
electron="$(grep -aoEm1 'Electron/[0-9]+' "$work/opt/amp/amp-desktop")"
electron="${electron%%$'\n'*}"
electron="${electron#Electron/}"

nix_helper="$(sed -nE '/pname = "amp-passkey-helper"/{n;s/.*version = "([^"]+)";/\1/p}' "$nix_file")"
nix_electron="$(sed -nE 's/^  electron_([0-9]+),$/\1/p' "$nix_file")"
mismatch=0
if [[ "$helper" != "$nix_helper" ]]; then
  echo "the .deb bundles amp-passkey-helper $helper; $nix_file builds $nix_helper" >&2
  mismatch=1
fi
if [[ "$electron" != "$nix_electron" ]]; then
  echo "the .deb ships Electron $electron; $nix_file uses electron_$nix_electron" >&2
  mismatch=1
fi
((mismatch == 0)) || { echo "update those by hand, then rerun" >&2; exit 1; }

sri="$(nix hash convert --hash-algo sha256 --to sri "$sha256")"
sed -i -E \
  -e "s|^  version = \"$current\";|  version = \"$version\";|" \
  -e "/amp-desktop-\\\$\\{finalAttrs.version\\}-amd64.deb/{n;s|hash = \"[^\"]+\";|hash = \"$sri\";|}" \
  "$nix_file"
echo "amp-desktop: $current -> $version"
