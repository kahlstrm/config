# Usage: runner-isolation-check [+]host:port[/udp]...
# A target marked + must accept a TCP connection, so the network works. Every other target must
# time out, as a NetworkPolicy drop does; a refused connection or any UDP reply still reached a
# host, so it fails.
set -uo pipefail

probe() {
  local host=${1%:*} port=${1##*:}
  if [[ $port == */udp ]]; then
    # A DNS query for the root's name servers; any reply means the host is reachable.
    # shellcheck disable=SC2016 # The inner shell expands them.
    timeout 5 bash -c 'exec 3<>"/dev/udp/$0/$1" &&
      printf "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x01" >&3 &&
      head -c1 <&3 >/dev/null' "$host" "${port%/udp}" 2>/dev/null
  else
    # shellcheck disable=SC2016 # The inner shell expands them.
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$host" "$port" 2>/dev/null
  fi
  case $? in
    0) echo open ;;
    124) echo timeout ;;
    *) echo refused ;;
  esac
}

results=$(mktemp -d)
trap 'rm -rf "$results"' EXIT
index=0
# The internet first: a private target's timeout shows the policy only once the network works.
for target in "$@"; do
  [[ $target == +* ]] || continue
  index=$((index + 1))
  (
    target=${target#+}
    # The network may still be settling right after boot.
    for _ in 1 2 3 4 5 6; do
      result=$(probe "$target")
      [ "$result" = open ] && break
      sleep 5
    done
    echo "$target $result open" > "$results/$index"
  ) &
done
wait
for target in "$@"; do
  [[ $target == +* ]] && continue
  index=$((index + 1))
  echo "$target $(probe "$target") timeout" > "$results/$index" &
done
wait

failed=0
for file in "$results"/*; do
  read -r target result expected < "$file"
  if [ "$result" = "$expected" ]; then
    echo "isolation check: $target $result, as expected"
  else
    echo "isolation check: $target $result, expected $expected"
    failed=1
  fi
done
if [ "$failed" -ne 0 ]; then
  echo "isolation check failed: the runner stays down"
  exit 1
fi
echo "isolation check passed"
