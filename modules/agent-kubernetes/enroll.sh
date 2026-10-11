# One-time enrollment after applying RBAC and syncing the credential Application.
# Run from the checkout on an operator machine with the administrative context.
# Commit the encrypted output and deploy the agent environment to activate access.
if [ "$#" -ne 1 ]; then
  echo 'Usage: nix run .#agent-kubernetes-enroll -- <admin-context>' >&2
  exit 1
fi

repository=$(git rev-parse --show-toplevel)
umask 077
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

if ! kubectl --context="$1" --namespace=agent-debug get secret agent-debug-issuer-bootstrap --output=json |
  jq -er '.data.token | select(type == "string" and length > 0) | @base64d' > "$temporary/token"; then
  echo 'Bootstrap token is not ready; check the credential Application and issuer service account.' >&2
  exit 1
fi

kubectl --context="$1" config view --raw --minify --flatten --output=json |
  jq -e '.clusters[0].cluster | select(.server | startswith("https://")) | select(."insecure-skip-tls-verify" != true) | select(."certificate-authority-data" | type == "string" and length > 0)' > "$temporary/cluster"
nix eval --json --file "$repository/secrets/secrets.nix" \
  --apply 'secrets: secrets."agent-kubernetes.age".publicKeys' |
  jq -r '.[]' > "$temporary/recipients"
jq -n --slurpfile cluster "$temporary/cluster" --rawfile token "$temporary/token" '{
  apiVersion: "v1", kind: "Config",
  clusters: [{name: "klusse", cluster: $cluster[0]}],
  users: [{name: "agent-debug-issuer", user: {token: ($token | rtrimstr("\n"))}}],
  contexts: [{name: "issuer", context: {cluster: "klusse", user: "agent-debug-issuer"}}],
  "current-context": "issuer"
}' > "$temporary/bootstrap"
age --encrypt --recipients-file "$temporary/recipients" \
  --output "$temporary/encrypted" "$temporary/bootstrap"
mv "$temporary/encrypted" "$repository/secrets/agent-kubernetes.age"
echo 'Created secrets/agent-kubernetes.age; review, commit and deploy the agent environment.'
