set -euo pipefail

credential_script=$1
setup_script=$2
enroll_script=$(realpath "$3")
package=$4
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
export PATH="$fixture/bin:$PATH"
export TEST_KUBE_CALLS="$fixture/calls"
export TEST_KUBE_MODE=success
printf '#!%s\n' "$(command -v bash)" > "$fixture/bin/kubectl"
cat >> "$fixture/bin/kubectl" <<'EOF'
printf '%s\n' "$*" >> "$TEST_KUBE_CALLS"
case "$TEST_KUBE_MODE" in
  success) printf '%s\n' '{"status":{"token":"test-reader-token","expirationTimestamp":"2099-01-01T00:00:00Z"}}' ;;
  failure) printf 'do not disclose test-bootstrap-token\n' >&2; exit 1 ;;
  malformed) printf '%s\n' '{"status":{"token":"test-reader-token"}}' ;;
  expired) printf '%s\n' '{"status":{"token":"test-reader-token","expirationTimestamp":"2000-01-01T00:00:00Z"}}' ;;
  configuration) cat "$TEST_BOOTSTRAP_CONFIG" ;;
  enrollment)
    if [[ "$*" == *'get secret'* ]]; then
      printf '%s\n' '{"data":{"token":"dGVzdC1ib290c3RyYXAtdG9rZW4="}}'
    else
      cat "$TEST_BOOTSTRAP_CONFIG"
    fi ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

bash "$credential_script" "$fixture/bootstrap" > "$fixture/result"
jq -e '.apiVersion == "client.authentication.k8s.io/v1" and .kind == "ExecCredential" and .status.token == "test-reader-token" and .status.expirationTimestamp == "2099-01-01T00:00:00Z"' "$fixture/result" > /dev/null
rg -q -- '--namespace=agent-debug.*create token agent-debug-reader.*--duration=1h.*--output=json' "$TEST_KUBE_CALLS"
! rg -q -- '--token=' "$TEST_KUBE_CALLS"

for mode in failure malformed expired; do
  export TEST_KUBE_MODE=$mode
  if bash "$credential_script" "$fixture/bootstrap" > "$fixture/result" 2> "$fixture/error"; then
    echo "Accepted $mode credentials" >&2
    exit 1
  fi
  test ! -s "$fixture/result"
  ! rg -q 'test-(reader|bootstrap)-token' "$fixture/error"
done

export TEST_KUBE_MODE=configuration
export TEST_BOOTSTRAP_CONFIG="$fixture/bootstrap.json"
cat > "$TEST_BOOTSTRAP_CONFIG" <<'EOF'
{"apiVersion":"v1","kind":"Config","clusters":[{"name":"klusse","cluster":{"server":"https://10.10.10.11:6443","certificate-authority-data":"dGVzdC1jYQ=="}}],"users":[{"name":"agent-debug-issuer","user":{"token":"test-bootstrap-token"}}],"contexts":[{"name":"issuer","context":{"cluster":"klusse","user":"agent-debug-issuer"}}],"current-context":"issuer"}
EOF
"$package/bin/agent-kube-setup" "$TEST_BOOTSTRAP_CONFIG" /test/agent-kube-credential "$fixture/actual-reader.json"
jq -e '."current-context" == "agent-debug" and .users[0].user.exec.args[0] == env.TEST_BOOTSTRAP_CONFIG' "$fixture/actual-reader.json" > /dev/null
! rg -q 'test-bootstrap-token' "$fixture/actual-reader.json"
bash "$setup_script" "$TEST_BOOTSTRAP_CONFIG" /test/agent-kube-credential "$fixture/reader.json"
jq -e '.users[0].user.exec.command == "/test/agent-kube-credential" and .users[0].user.exec.interactiveMode == "Never" and .users[0].user.exec.args[0] == env.TEST_BOOTSTRAP_CONFIG and .clusters[0].cluster.server == "https://10.10.10.11:6443"' "$fixture/reader.json" > /dev/null
! rg -q 'test-bootstrap-token' "$fixture/reader.json"
test "$(stat -c '%a' "$fixture/reader.json")" = 600
cp "$fixture/reader.json" "$fixture/original.json"
jq '.clusters[0].cluster["insecure-skip-tls-verify"] = true' "$TEST_BOOTSTRAP_CONFIG" > "$fixture/insecure.json"
export TEST_BOOTSTRAP_CONFIG="$fixture/insecure.json"
if bash "$setup_script" "$TEST_BOOTSTRAP_CONFIG" /test/agent-kube-credential "$fixture/reader.json" > "$fixture/result" 2> "$fixture/error"; then
  echo 'Accepted insecure cluster TLS' >&2
  exit 1
fi
cmp "$fixture/original.json" "$fixture/reader.json"
test ! -s "$fixture/result"
! rg -q 'test-bootstrap-token' "$fixture/error"

export TEST_KUBE_MODE=enrollment
export TEST_BOOTSTRAP_CONFIG="$fixture/bootstrap.json"
mkdir -p "$fixture/repository/secrets"
git -C "$fixture/repository" init -q
touch "$fixture/repository/secrets/secrets.nix"
printf '#!%s\n' "$(command -v bash)" > "$fixture/bin/nix"
cat >> "$fixture/bin/nix" <<'EOF'
printf '%s\n' '["test-enrollment-recipient"]'
EOF
printf '#!%s\n' "$(command -v bash)" > "$fixture/bin/age"
cat >> "$fixture/bin/age" <<'EOF'
test "$(cat "$3")" = test-enrollment-recipient
while [ "$1" != --output ]; do shift; done
jq -e '.users[0].name == "agent-debug-issuer" and .users[0].user.token == "test-bootstrap-token" and .clusters[0].cluster.server == "https://10.10.10.11:6443"' "$3" > /dev/null
printf 'test-encrypted-enrollment\n' > "$2"
EOF
chmod +x "$fixture/bin/nix" "$fixture/bin/age"
(cd "$fixture/repository" && bash -euo pipefail "$enroll_script" operator-context > "$fixture/result")
test "$(cat "$fixture/repository/secrets/agent-kubernetes.age")" = test-encrypted-enrollment
! rg -q 'test-bootstrap-token' "$fixture/result"
test "$(stat -c '%a' "$fixture/repository/secrets/agent-kubernetes.age")" = 600
