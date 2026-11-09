# Keeps the ops VM's infrastructure private keys on the VM.
#
#   ops-credentials generate <state directory>
#     Creates, once, the Talos client key and CSR, the GCP key and certificate, and the
#     SSH key that ops-deploy accounts on the machines trust (modules/ops-deploy.nix).
#     Existing files are kept, so committed certificates stay valid.
#   ops-credentials assemble <state directory> <runtime directory>
#     Writes a talosconfig and a GCP service account key file from the private keys
#     and the public material in the environment, for each service that has it:
#       OPS_TALOS_CA, OPS_TALOS_CRT  PEM files; OPS_TALOS_ENDPOINTS (space-separated)
#       OPS_GCP_EMAIL, OPS_GCP_KEY_ID, OPS_GCP_PROJECT
#   ops-credentials kubeconfig <bucket>/<prefix> <runtime directory>
#     Writes the cluster's admin kubeconfig from the kubeconfig output in local-talos'
#     Terraform state, the object <prefix>/default.tfstate in GCS, without printing it. It
#     reads the object with a token for the runtime directory's assembled GCP key, so it needs
#     no Terraform, providers or checkout. curl comes from PATH.
#   ops-credentials routeros <bucket>/<prefix> <runtime directory> <host>
#     Writes a netrc for the RouterOS user ops on <host> from local-networking's
#     ops_routeros_password output the same way.
#   ops-credentials home-assistant <bucket>/<prefix> <runtime directory>
#     Writes a curl header file with Home Assistant's token from local-networking's
#     ops_home_assistant_token output the same way.
set -euo pipefail
umask 077

temporary=
trap '[ -z "$temporary" ] || rm -rf "$temporary"' EXIT

generate() {
  local state
  install -d -m 0700 "$1"
  # Absolute, since talosctl writes into the temporary directory it runs in.
  state=$(realpath "$1")
  temporary=$(mktemp -d "$state/.generate.XXXXXX")
  if [ ! -e "$state/talos.key" ]; then
    (cd "$temporary" && talosctl gen key --name talos >/dev/null)
    install -m 0400 "$temporary/talos.key" "$state/talos.key"
  fi
  if [ ! -e "$state/talos.csr" ]; then
    # talosctl writes the CSR beside the key. apid ignores a client certificate's
    # addresses, but the CSR requires one.
    cp "$state/talos.key" "$temporary/talos.key"
    (cd "$temporary" && talosctl gen csr --key talos.key --roles os:admin --ip "$OPS_TALOS_CLIENT_IP" >/dev/null)
    install -m 0444 "$temporary/talos.csr" "$state/talos.csr"
  fi
  if [ ! -e "$state/gcp.key" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$temporary/gcp.key" 2>/dev/null
    install -m 0400 "$temporary/gcp.key" "$state/gcp.key"
  fi
  if [ ! -e "$state/gcp.crt" ]; then
    # GCP takes the key's expiry from the certificate and wants a generic subject.
    openssl req -x509 -key "$state/gcp.key" -days 365 -subj /CN=unused -out "$temporary/gcp.crt"
    install -m 0444 "$temporary/gcp.crt" "$state/gcp.crt"
  fi
  if [ ! -e "$state/deploy.key" ]; then
    ssh-keygen -q -t ed25519 -N "" -C ops-deploy -f "$temporary/deploy.key"
    install -m 0400 "$temporary/deploy.key" "$state/deploy.key"
  fi
  if [ ! -e "$state/deploy.pub" ]; then
    ssh-keygen -y -f "$state/deploy.key" >"$temporary/deploy.pub"
    install -m 0444 "$temporary/deploy.pub" "$state/deploy.pub"
  fi
}

# Writes stdin to the file through a private temporary, leaving it readable only by its owner.
place() {
  local file=$1
  rm -f "$file.new"
  cat >"$file.new"
  chmod 0400 "$file.new"
  mv -f "$file.new" "$file"
}

assemble() {
  local state=$1 runtime=$2
  install -d -m 0700 "$runtime"
  if [ -n "${OPS_TALOS_CA:-}" ] && [ -n "${OPS_TALOS_CRT:-}" ]; then
    # JSON is valid YAML, so talosctl reads it as a talosconfig.
    jq -n --arg ca "$(base64 -w0 "$OPS_TALOS_CA")" --arg crt "$(base64 -w0 "$OPS_TALOS_CRT")" \
      --arg key "$(base64 -w0 "$state/talos.key")" --arg endpoints "$OPS_TALOS_ENDPOINTS" \
      '($endpoints | split(" ")) as $endpoints
        | {context: "ops", contexts: {ops: {endpoints: $endpoints, nodes: [$endpoints[0]], ca: $ca, crt: $crt, key: $key}}}' |
      place "$runtime/talosconfig"
  else
    rm -f "$runtime/talosconfig"
  fi
  if [ -n "${OPS_GCP_EMAIL:-}" ] && [ -n "${OPS_GCP_KEY_ID:-}" ]; then
    jq -n --arg email "$OPS_GCP_EMAIL" --arg id "$OPS_GCP_KEY_ID" --arg project "$OPS_GCP_PROJECT" \
      --rawfile key "$state/gcp.key" \
      '{type: "service_account", project_id: $project, private_key_id: $id, private_key: $key,
        client_email: $email, token_uri: "https://oauth2.googleapis.com/token"}' |
      place "$runtime/gcp.json"
  else
    rm -f "$runtime/gcp.json"
  fi
}

base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Prints a read-only GCS access token for the service account key file, exchanging an
# assertion signed with its key at its token URI, as Google's auth libraries do.
access_token() {
  local key=$1 email id uri header claims now unsigned signature response
  email=$(jq -er .client_email "$key") && id=$(jq -er .private_key_id "$key") &&
    uri=$(jq -er .token_uri "$key") || return 1
  now=$(date +%s)
  header=$(jq -cjn --arg id "$id" '{alg: "RS256", typ: "JWT", kid: $id}' | base64url)
  claims=$(jq -cjn --arg email "$email" --arg uri "$uri" --argjson now "$now" \
    '{iss: $email, aud: $uri, scope: "https://www.googleapis.com/auth/devstorage.read_only",
      iat: $now, exp: ($now + 300)}' | base64url)
  unsigned=$header.$claims
  signature=$(printf %s "$unsigned" |
    openssl dgst -sha256 -binary -sign <(jq -r .private_key "$key") | base64url) || return 1
  # The assertion goes through stdin, and the token is only printed to the caller.
  if ! response=$(printf 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=%s' \
    "$unsigned.$signature" | curl -sS --fail-with-body --data @- "$uri"); then
    printf '%s\n' "$response" >&2
    return 1
  fi
  jq -er '.access_token | strings' <<<"$response" 2>/dev/null
}

# Writes output <name> of the Terraform state at <bucket>/<prefix> to a new file in a private
# temporary directory of the runtime directory without printing it or keeping the rest of the
# state, and sets $fetched to that file. A failure leaves the published file alone.
fetch() {
  local location=$1 runtime=$2 name=$3 what=$4 token object
  object="gs://$location/default.tfstate"
  install -d -m 0700 "$runtime"
  temporary=$(mktemp -d "$runtime/.$name.XXXXXX")
  fetched=$temporary/$name
  if ! token=$(access_token "$runtime/gcp.json"); then
    echo "no GCS token for $runtime/gcp.json; kept the previous $what" >&2
    exit 1
  fi
  # The header comes from a file descriptor, so the token stays out of the process list.
  if ! curl -sS --fail-with-body -H @<(printf 'Authorization: Bearer %s\n' "$token") \
    "https://storage.googleapis.com/storage/v1/b/${location%%/*}/o/${location#*/}%2Fdefault.tfstate?alt=media" |
    jq -ej --arg name "$name" '.outputs[$name].value | strings' >"$fetched" 2>/dev/null; then
    echo "no output $name in $object; kept the previous $what" >&2
    exit 1
  fi
}

# Renamed from this run's own directory, so concurrent refreshes each publish a whole file.
publish() {
  chmod 0400 "$1"
  mv -f "$1" "$2"
}

# Writes the cluster's admin kubeconfig from local-talos' state into the runtime directory
# without printing it; any failure keeps the previous one.
kubeconfig() {
  local location=$1 runtime=$2 server
  fetch "$location" "$runtime" kubeconfig kubeconfig
  # The current context must resolve to a server and an embedded client certificate and key.
  # kubectl's parse errors may quote the file, so only the outcome is reported.
  server=$(kubectl --kubeconfig "$fetched" config view --minify --raw -o json 2>/dev/null |
    jq -er 'select(.users[0].user["client-certificate-data"] and .users[0].user["client-key-data"])
      | .clusters[0].cluster.server' 2>/dev/null) || server=
  if [ -z "$server" ]; then
    echo "the kubeconfig output is no usable kubeconfig; kept the previous one" >&2
    exit 1
  fi
  publish "$fetched" "$runtime/kubeconfig"
  echo "wrote the admin kubeconfig for $server to $runtime/kubeconfig"
}

# Writes a netrc for the RouterOS user ops from local-networking's password output; any
# failure keeps the previous one.
routeros() {
  local location=$1 runtime=$2 host=$3 password
  fetch "$location" "$runtime" ops_routeros_password "RouterOS netrc"
  password=$(cat "$fetched")
  # Terraform generates it alphanumeric, which netrc needs no quoting for.
  if ! [[ $password =~ ^[A-Za-z0-9]{16,}$ ]]; then
    echo "the password output is no usable password; kept the previous RouterOS netrc" >&2
    exit 1
  fi
  printf 'machine %s login ops password %s\n' "$host" "$password" >"$temporary/routeros.netrc"
  publish "$temporary/routeros.netrc" "$runtime/routeros.netrc"
  echo "wrote the RouterOS netrc for ops@$host to $runtime/routeros.netrc"
}

# Writes a curl header file (`curl -H @file`) with Home Assistant's long-lived token from
# local-networking's output; any failure keeps the previous one.
home_assistant() {
  local location=$1 runtime=$2 token
  fetch "$location" "$runtime" ops_home_assistant_token "Home Assistant headers"
  token=$(cat "$fetched")
  # Home Assistant's long-lived tokens are JWTs, which need no quoting in a header.
  if ! [[ $token =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    echo "the token output is no usable token; kept the previous Home Assistant headers" >&2
    exit 1
  fi
  printf 'Authorization: Bearer %s\n' "$token" >"$temporary/home-assistant.headers"
  publish "$temporary/home-assistant.headers" "$runtime/home-assistant.headers"
  echo "wrote the Home Assistant headers to $runtime/home-assistant.headers"
}

case "${1:-}" in
generate) generate "$2" ;;
assemble) assemble "$2" "$3" ;;
kubeconfig) kubeconfig "$2" "$3" ;;
routeros) routeros "$2" "$3" "$4" ;;
home-assistant) home_assistant "$2" "$3" ;;
*)
  echo "usage: ops-credentials generate <state> | assemble <state> <runtime> | kubeconfig <bucket>/<prefix> <runtime> | routeros <bucket>/<prefix> <runtime> <host> | home-assistant <bucket>/<prefix> <runtime>" >&2
  exit 2
  ;;
esac
