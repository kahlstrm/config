set -euo pipefail

enroll_script=$(realpath "$1")
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/repository/secrets"
git -C "$fixture/repository" init -q
age-keygen -o "$fixture/key" 2>/dev/null
export TEST_RECIPIENT
TEST_RECIPIENT=$(age-keygen -y "$fixture/key")
export TEST_CLUSTER="$fixture/cluster.json"
printf '%s\n' '{"clusters":[{"cluster":{"server":"https://10.10.10.11:6443","certificate-authority-data":"dGVzdC1jYQ=="}}],"users":[{"user":{"token":"test-admin-token"}}]}' > "$TEST_CLUSTER"
printf '#!%s\n' "$(command -v bash)" > "$fixture/bin/kubectl"
cat >> "$fixture/bin/kubectl" <<'EOF'
set -euo pipefail
if [[ "$*" == *'get secret'* ]]; then
  [[ "$*" == *'--namespace=agent-debug get secret agent-debug-reader-token'* ]]
  printf '%s\n' '{"data":{"token":"dGVzdC1yZWFkZXItdG9rZW4="}}'
else
  cat "$TEST_CLUSTER"
fi
EOF
printf '#!%s\n' "$(command -v bash)" > "$fixture/bin/nix"
cat >> "$fixture/bin/nix" <<'EOF'
jq -n --arg recipient "$TEST_RECIPIENT" '[$recipient]'
EOF
chmod +x "$fixture/bin/kubectl" "$fixture/bin/nix"
export PATH="$fixture/bin:$PATH"

(cd "$fixture/repository" && bash -euo pipefail "$enroll_script" operator-context > "$fixture/result")
encrypted="$fixture/repository/secrets/agent-kubernetes.age"
age --decrypt --identity "$fixture/key" "$encrypted" > "$fixture/reader.json"
jq -e '.users | length == 1' "$fixture/reader.json" > /dev/null
jq -e '.users[0].name == "agent-debug-reader" and .users[0].user.token == "test-reader-token" and .users[0].user.exec == null and ."current-context" == "agent-debug" and .clusters[0].cluster.server == "https://10.10.10.11:6443"' "$fixture/reader.json" > /dev/null
! rg -q 'test-admin-token' "$fixture/reader.json"
! rg -q 'test-(admin|reader)-token' "$fixture/result" "$encrypted"
test "$(stat -c '%a' "$encrypted")" = 600
cp "$encrypted" "$fixture/original.age"
jq '.clusters[0].cluster["insecure-skip-tls-verify"] = true' "$TEST_CLUSTER" > "$fixture/insecure.json"
export TEST_CLUSTER="$fixture/insecure.json"
if (cd "$fixture/repository" && bash -euo pipefail "$enroll_script" operator-context > "$fixture/result" 2> "$fixture/error"); then
  echo 'Accepted insecure cluster TLS' >&2
  exit 1
fi
cmp "$fixture/original.age" "$encrypted"
! rg -q 'test-(admin|reader)-token' "$fixture/error"
