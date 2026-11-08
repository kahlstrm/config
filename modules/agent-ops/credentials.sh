# Keeps the ops VM's infrastructure private keys on the VM.
#
#   ops-credentials generate <state directory>
#     Creates, once, the Talos client key and CSR and the GCP key and certificate.
#     Existing files are kept, so committed certificates stay valid.
#   ops-credentials assemble <state directory> <runtime directory>
#     Writes a talosconfig and a GCP service account key file from the private keys
#     and the public material in the environment, for each service that has it:
#       OPS_TALOS_CA, OPS_TALOS_CRT  PEM files; OPS_TALOS_ENDPOINTS (space-separated)
#       OPS_GCP_EMAIL, OPS_GCP_KEY_ID, OPS_GCP_PROJECT
#   ops-credentials kubeconfig <local-talos directory> <runtime directory>
#     Writes the cluster's admin kubeconfig from the layer's Terraform output, which the GCP
#     key already reads, without printing it. Terraform comes from PATH.
#   ops-credentials routeros <local-networking directory> <runtime directory> <host>
#     Writes a netrc for the RouterOS user ops on <host> from the layer's
#     ops_routeros_password output the same way.
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

# Writes the layer's Terraform output to a new file in a private temporary directory of the
# runtime directory without printing it, and sets $fetched to that file. A failure leaves
# the published file alone.
fetch() {
  local layer=$1 runtime=$2 name=$3 what=$4
  install -d -m 0700 "$runtime"
  temporary=$(mktemp -d "$runtime/.$name.XXXXXX")
  fetched=$temporary/$name
  terraform -chdir="$layer" init -input=false -no-color >&2
  if ! terraform -chdir="$layer" output -raw "$name" >"$fetched"; then
    echo "terraform output failed; kept the previous $what" >&2
    exit 1
  fi
}

# Renamed from this run's own directory, so concurrent refreshes each publish a whole file.
publish() {
  chmod 0400 "$1"
  mv -f "$1" "$2"
}

# Writes the cluster's admin kubeconfig from the layer's Terraform output into the runtime
# directory without printing it; any failure keeps the previous one.
kubeconfig() {
  local layer=$1 runtime=$2 server
  fetch "$layer" "$runtime" kubeconfig kubeconfig
  # The current context must resolve to a server and an embedded client certificate and key.
  # kubectl's parse errors may quote the file, so only the outcome is reported.
  server=$(kubectl --kubeconfig "$fetched" config view --minify --raw -o json 2>/dev/null |
    jq -er 'select(.users[0].user["client-certificate-data"] and .users[0].user["client-key-data"])
      | .clusters[0].cluster.server' 2>/dev/null) || server=
  if [ -z "$server" ]; then
    echo "terraform output is no usable kubeconfig; kept the previous one" >&2
    exit 1
  fi
  publish "$fetched" "$runtime/kubeconfig"
  echo "wrote the admin kubeconfig for $server to $runtime/kubeconfig"
}

# Writes a netrc for the RouterOS user ops from the layer's password output; any failure
# keeps the previous one.
routeros() {
  local layer=$1 runtime=$2 host=$3 password
  fetch "$layer" "$runtime" ops_routeros_password "RouterOS netrc"
  password=$(cat "$fetched")
  # Terraform generates it alphanumeric, which netrc needs no quoting for.
  if ! [[ $password =~ ^[A-Za-z0-9]{16,}$ ]]; then
    echo "terraform output is no usable password; kept the previous RouterOS netrc" >&2
    exit 1
  fi
  printf 'machine %s login ops password %s\n' "$host" "$password" >"$temporary/routeros.netrc"
  publish "$temporary/routeros.netrc" "$runtime/routeros.netrc"
  echo "wrote the RouterOS netrc for ops@$host to $runtime/routeros.netrc"
}

case "${1:-}" in
generate) generate "$2" ;;
assemble) assemble "$2" "$3" ;;
kubeconfig) kubeconfig "$2" "$3" ;;
routeros) routeros "$2" "$3" "$4" ;;
*)
  echo "usage: ops-credentials generate <state> | assemble <state> <runtime> | kubeconfig <local-talos> <runtime> | routeros <local-networking> <runtime> <host>" >&2
  exit 2
  ;;
esac
