#!/usr/bin/env bash
set -euo pipefail

seed_command=$1
seed_store() { bash "$seed_command" "$@"; }
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/image-a/hash-old" "$fixture/image-b/hash-new" "$fixture/nix"
printf old > "$fixture/image-a/hash-old/file"
ln -s hash-old/file "$fixture/image-a/hash-link"
printf new > "$fixture/image-b/hash-new/file"

seed_store "$fixture/image-a" "$fixture/nix"
seed_store "$fixture/image-b" "$fixture/nix"
test "$(cat "$fixture/nix/.rw-store/store/hash-old/file")" = old
test "$(cat "$fixture/nix/.rw-store/store/hash-new/file")" = new
test "$(cat "$fixture/nix/.rw-store/store/hash-link")" = old

# A terminated copy must never leave a partial path at its final location.
mkdir -p "$fixture/nix/.agent-store-seed/hash-old"
printf partial > "$fixture/nix/.agent-store-seed/hash-old/file"
seed_store "$fixture/image-a" "$fixture/nix"
test ! -e "$fixture/nix/.agent-store-seed"
test "$(cat "$fixture/nix/.rw-store/store/hash-old/file")" = old

chmod u+w "$fixture/nix/.rw-store/store/hash-old/file"
printf retained > "$fixture/nix/.rw-store/store/hash-old/file"
seed_store "$fixture/image-a" "$fixture/nix"
test "$(cat "$fixture/nix/.rw-store/store/hash-old/file")" = retained

# Copy errors must stop seeding and retain previously completed store paths.
mkdir "$fixture/broken-image"
mknod "$fixture/broken-image/hash-unreadable" p
if timeout 1 bash "$seed_command" "$fixture/broken-image" "$fixture/nix"; then
  echo 'Seeding accepted an invalid store entry' >&2
  exit 1
fi
test "$(cat "$fixture/nix/.rw-store/store/hash-old/file")" = retained
