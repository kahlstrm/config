set -euo pipefail

seed=$1
persistent=$2
store="$persistent/.rw-store/store"
staging="$persistent/.agent-store-seed"

mkdir -p "$store"
# Only staging is disposable; completed paths and the Nix database survive boots.
rm -rf -- "$staging"
mkdir -p "$staging"

for source in "$seed"/*; do
  [ -e "$source" ] || [ -L "$source" ] || continue
  name=${source##*/}
  if [ ! -f "$source" ] && [ ! -d "$source" ] && [ ! -L "$source" ]; then
    echo "Invalid seed store entry: $source" >&2
    exit 1
  fi
  # Old overlay whiteouts have no meaning in the standalone persistent store.
  if [ -c "$store/$name" ] && [ "$(stat -c '%t:%T' "$store/$name")" = 0:0 ]; then
    rm -- "$store/$name"
  fi
  if [ -e "$store/$name" ] || [ -L "$store/$name" ]; then
    continue
  fi
  cp -a --reflink=auto -- "$source" "$staging/$name"
  sync -f "$staging"
  mv -T -- "$staging/$name" "$store/$name"
  sync -f "$store"
done

rmdir "$staging"
