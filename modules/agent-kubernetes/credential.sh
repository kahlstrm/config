if [ "$#" -ne 1 ]; then
  echo 'Usage: agent-kube-credential <bootstrap-kubeconfig>' >&2
  exit 1
fi

if ! response=$(kubectl --kubeconfig="$1" --namespace=agent-debug --request-timeout=15s \
  create token agent-debug-reader --duration=1h --output=json 2>/dev/null); then
  echo 'Unable to obtain Kubernetes reader credentials; check bootstrap enrollment and API connectivity.' >&2
  exit 1
fi

if ! printf '%s' "$response" | jq -e '
  (.status.token | type == "string" and length > 0) and
  (.status.expirationTimestamp | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
' >/dev/null 2>&1; then
  echo 'The API returned invalid reader credentials.' >&2
  exit 1
fi

expiration=$(printf '%s' "$response" | jq -r '.status.expirationTimestamp')
if ! expires_at=$(date --date="$expiration" +%s 2>/dev/null) || [ "$expires_at" -le "$(date +%s)" ]; then
  echo 'The API returned expired reader credentials.' >&2
  exit 1
fi

printf '%s' "$response" | jq -c '{
  apiVersion: "client.authentication.k8s.io/v1",
  kind: "ExecCredential",
  status: {token: .status.token, expirationTimestamp: .status.expirationTimestamp}
}'
