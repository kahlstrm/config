#!/usr/bin/env bash
# Checks that the ops T3 build, with ops' managed settings, offers delegating agents only
# Claude: an MCP client like a linked environment's sees every other provider disabled
# and cannot launch a thread on Codex. Launching an idle thread starts no provider.
#
# Usage: agent-ops-providers.sh <path to t3> <settings.json>
set -euo pipefail

t3=$1
settings=$2
work=$(mktemp -d)
export HOME=$work/home
port=3797
url=http://127.0.0.1:$port/mcp
server=
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
  [ -n "$server" ] && kill "$server" 2>/dev/null
  wait 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$work/ops/userdata" "$work/ops-work"
cp "$settings" "$work/ops/userdata/settings.json"
(cd "$work/ops-work" && exec "$t3" serve --base-dir "$work/ops" --host 127.0.0.1 --port "$port" "$work/ops-work") \
  >"$work/ops.log" 2>&1 &
server=$!
timeout 120 bash -c "until curl -sf -o /dev/null http://127.0.0.1:$port/; do sleep 1; done" ||
  { cat "$work/ops.log" >&2; exit 1; }
project=$("$t3" project add --base-dir "$work/ops" "$work/ops-work" | grep -oE '[0-9a-f-]{36}')
token=$("$t3" auth session issue --base-dir "$work/ops" --subject mcp-client \
  --scope orchestration:read --scope orchestration:operate --ttl 5m --token-only)
headers=(-H "Authorization: Bearer $token" -H 'Content-Type: application/json'
  -H 'Accept: application/json, text/event-stream')
session=$(curl -sf -D - -o /dev/null "$url" "${headers[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent-ops-providers","version":"0"}}}' |
  grep -i '^mcp-session-id' | cut -d' ' -f2 | tr -d '\r')

# Prints the JSON-RPC result of calling the named tool with the given arguments.
call() {
  curl -sf "$url" "${headers[@]}" -H "Mcp-Session-Id: $session" \
    -d "$(jq -cn --arg name "$1" --argjson arguments "$2" \
      '{jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: $name, arguments: $arguments}}')" |
    sed 's/^data: //' | grep '^{' | jq '.result'
}

# Prints "allowed" or the error for launching an idle thread on the given provider instance.
launch() {
  call t3_thread_launch "$(jq -cn --arg project "$project" --arg instance "$1" --arg model "$2" \
    '{projectId: $project, title: "provider probe", runtimeMode: "approval-required",
      modelSelection: {instanceId: $instance, model: $model}}')" |
    jq -r 'if .isError then .content[0].text else "allowed" end'
}

disabled='Provider instance is disabled.'
call orchestrator_capabilities '{}' | jq '(.structuredContent // (.content[0].text | fromjson)).providers
  | map({id: .providerInstanceId, constraints: (.constraints // [])})' >"$work/providers.json"
jq -e --arg disabled "$disabled" '(map(.id) | index("claudeAgent")) != null
  and all(.[]; (.id == "claudeAgent") != (.constraints | index($disabled) != null))' "$work/providers.json" >/dev/null ||
  { echo "a provider other than Claude is enabled, or Claude is disabled:" >&2; cat "$work/providers.json" >&2; exit 1; }

# Expects the launch result to contain the given text.
expect() {
  local actual
  actual=$(launch "$1" "$2")
  [[ $actual == *"$3"* ]] || { echo "launch on $1: expected $3, got $actual" >&2; exit 1; }
}
expect claudeAgent claude-haiku-5-5 allowed
expect codex gpt-5.5 'Provider instance \"codex\" is disabled'
expect opencode opencode/default 'Provider instance \"opencode\" is disabled'
echo "only Claude is offered"
