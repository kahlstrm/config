if [ "$#" -ne 3 ]; then
  echo 'Usage: agent-kube-setup <bootstrap-kubeconfig> <credential-helper> <reader-kubeconfig>' >&2
  exit 1
fi

bootstrap=$1
helper=$2
destination=$3
umask 077

if ! configuration=$(kubectl --kubeconfig="$bootstrap" config view --raw --minify --flatten --output=json 2>/dev/null); then
  echo 'Unable to read Kubernetes bootstrap enrollment.' >&2
  exit 1
fi

if ! printf '%s' "$configuration" | jq -e '
  (.clusters | length == 1) and (.users | length == 1) and
  (.clusters[0].cluster.server | startswith("https://")) and
  (.clusters[0].cluster["insecure-skip-tls-verify"] != true) and
  (.clusters[0].cluster["certificate-authority-data"] | type == "string" and length > 0) and
  (.users[0].name == "agent-debug-issuer") and
  (.users[0].user.token | type == "string" and length > 0)
' >/dev/null 2>&1; then
  echo 'Bootstrap enrollment must contain the issuer identity and a TLS-verified cluster CA.' >&2
  exit 1
fi

temporary=$(mktemp "${destination}.XXXXXX")
trap 'rm -f "$temporary"' EXIT
printf '%s' "$configuration" | jq --arg bootstrap "$bootstrap" --arg helper "$helper" '{
  apiVersion: "v1",
  kind: "Config",
  clusters: .clusters,
  users: [{name: "agent-debug-reader", user: {exec: {
    apiVersion: "client.authentication.k8s.io/v1",
    command: $helper,
    args: [$bootstrap],
    interactiveMode: "Never"
  }}}],
  contexts: [{name: "agent-debug", context: {
    cluster: .clusters[0].name, user: "agent-debug-reader", namespace: "default"
  }}],
  "current-context": "agent-debug"
}' > "$temporary"
mv "$temporary" "$destination"
