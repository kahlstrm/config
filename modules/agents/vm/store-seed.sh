set -euo pipefail
shopt -s nullglob

seed=$1
persistent=$2
store="$persistent/.rw-store/store"
staging="$persistent/.agent-store-seed"

if [ -e "$persistent/.rw-store/work" ]; then
  echo "$persistent holds a former overlay store; recreate the volume" >&2
  exit 1
fi

mkdir -p "$store"
# Only staging is disposable; completed paths and the Nix database survive boots.
rm -rf -- "$staging"
mkdir -p "$staging"

missing=()
for source in "$seed"/*; do
  name=${source##*/}
  [ -e "$store/$name" ] || [ -L "$store/$name" ] || missing+=("$name")
done

for name in "${missing[@]}"; do
  cp -a --reflink=auto -- "$seed/$name" "$staging/$name"
done
sync -f "$staging"
for name in "${missing[@]}"; do
  mv -T -- "$staging/$name" "$store/$name"
done
sync -f "$store"

rmdir "$staging"
