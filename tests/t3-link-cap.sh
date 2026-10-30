#!/usr/bin/env bash
# Checks that a linked T3 environment holds the link's runtime-mode ceiling.
#
# Usage: t3-link-cap.sh <path to t3> <settings.json>
#
# Starts an "ops" and a "hub" server with the given settings, links the hub to
# ops at each access level, and calls ops' /mcp with the link's own token as an
# agent claiming full-access. Launching an idle thread starts no provider.
set -euo pipefail

t3=$1
settings=$2
work=$(mktemp -d)
export HOME=$work/home
servers=()
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
  for pid in "${servers[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

serve() {
  local name=$1 port=$2
  mkdir -p "$work/$name/userdata" "$work/$name-work"
  cp "$settings" "$work/$name/userdata/settings.json"
  (cd "$work/$name-work" && exec "$t3" serve --base-dir "$work/$name" --host 127.0.0.1 --port "$port" "$work/$name-work") \
    >"$work/$name.log" 2>&1 &
  servers+=("$!")
  timeout 120 bash -c "until curl -sf -o /dev/null http://127.0.0.1:$port/; do sleep 1; done" ||
    { cat "$work/$name.log" >&2; exit 1; }
}

serve ops 3795
serve hub 3796
project=$("$t3" project add --base-dir "$work/ops" "$work/ops-work" | grep -oE '[0-9a-f-]{36}')

link() {
  local linked
  linked=$("$t3" environment list --base-dir "$work/hub" | grep -oE '^\S+ \([0-9a-f-]{36}\)' | grep -oE '[0-9a-f-]{36}' || true)
  for id in $linked; do "$t3" environment unlink --base-dir "$work/hub" "$id" >/dev/null; done
  code=$("$t3" pair --base-dir "$work/ops" --ttl 5m | sed -n 's/^Token: //p')
  "$t3" environment link --base-dir "$work/hub" --pairing-code "$code" --access "$1" http://127.0.0.1:3795 >"$work/link.log" 2>&1 ||
    { grep -v '^\s*at ' "$work/link.log" >&2; exit 1; }
}

# Prints "allowed" or the error code for launching an idle thread on ops in the given mode.
launch() {
  local token headers session
  token=$(cat "$work"/hub/userdata/secrets/peer-link-*.bin)
  headers=(-H "Authorization: Bearer $token" -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream' -H 'T3-Mode-Limit: full-access/default')
  session=$(curl -sf -D - -o /dev/null http://127.0.0.1:3795/mcp "${headers[@]}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t3-link-cap","version":"0"}}}' |
    grep -i '^mcp-session-id' | cut -d' ' -f2 | tr -d '\r')
  curl -sf http://127.0.0.1:3795/mcp "${headers[@]}" -H "Mcp-Session-Id: $session" -d "$(jq -cn \
    --arg project "$project" --arg mode "$1" \
    '{jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "t3_thread_launch", arguments: {
      projectId: $project, title: "cap probe", runtimeMode: $mode,
      modelSelection: {instanceId: "claudeAgent", model: "claude-haiku-5-5"}}}}')" |
    sed 's/^data: //' | grep '^{' | jq -r '.result | if .isError then (.content[0].text | fromjson | .code) else "allowed" end'
}

expect() {
  local actual
  actual=$(launch "$2")
  [ "$actual" = "$3" ] || { echo "link $1, launch $2: expected $3, got $actual" >&2; exit 1; }
}

link full-access
expect full-access full-access allowed

link approval-required
expect approval-required full-access runtime_mode_escalation_denied
expect approval-required auto runtime_mode_escalation_denied
expect approval-required approval-required allowed
echo "link ceiling holds"
