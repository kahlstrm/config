#!/usr/bin/env bash
set -euo pipefail

seed_store() { bash "$1" "$2" "$3"; }
seed_command=$1
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
store="$fixture/nix/.rw-store/store"
mkdir -p "$fixture/image-a/hash-old" "$fixture/image-b/hash-new" "$fixture/nix"
printf old > "$fixture/image-a/hash-old/file"
ln -s hash-old/file "$fixture/image-a/hash-link"
printf new > "$fixture/image-b/hash-new/file"

# Replacing the image keeps paths supplied by earlier images.
seed_store "$seed_command" "$fixture/image-a" "$fixture/nix"
seed_store "$seed_command" "$fixture/image-b" "$fixture/nix"
test "$(cat "$store/hash-old/file")" = old
test "$(cat "$store/hash-link")" = old
test "$(cat "$store/hash-new/file")" = new

# Paths already in the store are never replaced by image contents.
chmod u+w "$store/hash-old/file"
printf retained > "$store/hash-old/file"
seed_store "$seed_command" "$fixture/image-a" "$fixture/nix"
test "$(cat "$store/hash-old/file")" = retained

# An interrupted copy is discarded instead of being published.
rm -rf "$store/hash-new"
mkdir -p "$fixture/nix/.agent-store-seed/hash-new"
seed_store "$seed_command" "$fixture/image-b" "$fixture/nix"
test ! -e "$fixture/nix/.agent-store-seed"
test "$(cat "$store/hash-new/file")" = new

# A volume left from the overlay store is refused rather than reused.
mkdir "$fixture/nix/.rw-store/work"
if seed_store "$seed_command" "$fixture/image-a" "$fixture/nix" 2> /dev/null; then
  echo 'Seeding accepted a former overlay store' >&2
  exit 1
fi
