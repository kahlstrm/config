#!/usr/bin/env bash
# Smoke-tests a T3 Code build before it replaces the agents' server.
#
# Usage: tools/t3-smoke/smoke.sh <path to t3> [provider:model ...]
#
# Starts the build on loopback with a throwaway data directory and runs one
# real turn per provider. The harnesses use the sign-ins already in this
# user's home; each turn calls T3's own MCP server, which answers from the
# throwaway server, so live threads are neither seen nor changed.
set -euo pipefail

t3=${1:?usage: $0 <path to t3> [provider:model ...]}
shift
if [ $# -gt 0 ]; then checks=("$@"); else checks=(claudeAgent:claude-haiku-5-5 codex:gpt-5.6-luna); fi
turn_timeout=${T3_SMOKE_TURN_TIMEOUT:-180}

work=$(mktemp -d "${TMPDIR:-/tmp}/t3-smoke.XXXXXX")
chmod 700 "$work"
server=""
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
  # The server leads its own process group, so this also stops the harnesses it started.
  if [ -n "$server" ]; then
    kill -- "-$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

port=$(shuf -i 40000-49999 -n 1)
mkdir "$work/repo"
git -C "$work/repo" init -q
git -C "$work/repo" -c user.name=smoke -c user.email=smoke@localhost commit -q --allow-empty -m init

setsid "$t3" serve --base-dir "$work/home" --host 127.0.0.1 --port "$port" "$work/repo" >"$work/serve.log" 2>&1 &
server=$!
for _ in $(seq 60); do
  curl -sf -o /dev/null "http://127.0.0.1:$port/" && break
  kill -0 "$server" 2>/dev/null || { echo "FAIL server exited during startup" >&2; tail -20 "$work/serve.log" >&2; exit 1; }
  sleep 1
done
curl -sf -o /dev/null "http://127.0.0.1:$port/" || { echo "FAIL server did not answer within 60s" >&2; exit 1; }
echo "ok   server $("$t3" --version) on port $port"

cd "$work/repo"
"$t3" project add --base-dir "$work/home" . >/dev/null

# Each turn adds a thread, so the count proves the MCP call reached this server.
failed=0
expected=0
for check in "${checks[@]}"; do
  provider=${check%%:*} model=${check#*:}
  expected=$((expected + 1))
  started=$SECONDS
  status=0
  reply=$(timeout "$turn_timeout" "$t3" thread start --base-dir "$work/home" --provider "$provider" --model "$model" --wait . \
    "Call the t3_thread_list tool (load it first if your tools are deferred), then reply with exactly: OK <number of threads it returned>" 2>&1) || status=$?
  answer=$(tail -1 <<<"$reply")
  if [ "$status" -eq 0 ] && [ "$answer" = "OK $expected" ]; then
    echo "ok   $provider/$model in $((SECONDS - started))s"
  else
    failed=1
    [ "$status" -eq 124 ] && why="no reply within ${turn_timeout}s" || why="exit $status, reply '$answer', expected 'OK $expected'"
    echo "FAIL $provider/$model: $why" >&2
    # The provider log shows harness errors that T3 may not surface, such as an unsupported model.
    grep -h -o '"error":{"message":"[^"]*"' "$work"/home/userdata/logs/provider/*.log 2>/dev/null | sort -u | tail -5 >&2 || true
  fi
done
exit "$failed"
