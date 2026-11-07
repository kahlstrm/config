# Runs ops' credential tool as its boot services do: keys are generated once and kept on
# reruns, and committed public material turns them into a talosconfig and a service account
# key file that talosctl and Google's auth library read, readable only by their owner. The
# RouterOS SSH key is used in place, so only its public half is checked against it.
{ pkgs }:
let
  tool = pkgs.callPackage ../modules/agent-ops/credentials-package.nix { };
  python = pkgs.python3.withPackages (packages: [ packages.google-auth ]);
in
pkgs.runCommand "agent-ops-credentials"
  {
    nativeBuildInputs = [
      tool
      pkgs.talosctl
      pkgs.openssl
      pkgs.jq
      pkgs.kubectl
      pkgs.openssh
      python
    ];
  }
  ''
    set -euo pipefail
    export HOME=$PWD OPS_TALOS_CLIENT_IP=10.83.0.6
    mode() { stat -c %a "$1"; }
    expect() { [ "$2" = "$3" ] || { echo "$1: expected $3, got $2" >&2; exit 1; }; }
    files="talos.key talos.csr gcp.key gcp.crt routeros routeros.pub"

    ops-credentials generate state
    expect "state directory" "$(mode state)" 700
    for key in talos.key gcp.key routeros; do expect "$key" "$(mode state/$key)" 400; done
    expect "routeros.pub" "$(mode state/routeros.pub)" 444
    (cd state && sha256sum $files) > before
    ops-credentials generate state
    (cd state && sha256sum $files) | diff before - || { echo "a rerun replaced keys" >&2; exit 1; }
    # A missing public half is recreated from the kept key.
    rm state/gcp.crt state/routeros.pub
    ops-credentials generate state
    (cd state && sha256sum talos.key gcp.key routeros routeros.pub) |
      diff <(grep -E ' (talos.key|gcp.key|routeros|routeros.pub)$' before) -
    # The committed public half names ops and matches the private key ssh uses.
    expect "routeros.pub" "$(cut -d' ' -f1,3 state/routeros.pub)" "ssh-ed25519 ops"
    expect "routeros key pair" "$(ssh-keygen -y -f state/routeros)" "$(cat state/routeros.pub)"

    # Without public material nothing is assembled.
    ops-credentials assemble state runtime
    expect "runtime directory" "$(mode runtime)" 700
    expect "runtime files" "$(ls runtime | wc -l)" 0

    # The operator signs the CSR with the os CA; GCP returns a key ID for the certificate.
    talosctl gen ca --organization test --hours 1 >/dev/null
    talosctl gen crt --ca test --csr state/talos.csr --hours 1 --name client >/dev/null
    OPS_TALOS_CA=test.crt OPS_TALOS_CRT=client.crt \
      OPS_TALOS_ENDPOINTS="10.10.10.11 10.10.10.12 10.10.10.13" \
      OPS_GCP_EMAIL=ops-test@infra-464520.iam.gserviceaccount.com OPS_GCP_KEY_ID=0123abcd \
      OPS_GCP_PROJECT=infra-464520 ops-credentials assemble state runtime
    for file in talosconfig gcp.json; do expect "$file" "$(mode runtime/$file)" 400; done

    talosctl --talosconfig runtime/talosconfig config info -o json > info.json
    jq -e '.context == "ops" and .endpoints == ["10.10.10.11", "10.10.10.12", "10.10.10.13"]
      and .nodes == ["10.10.10.11"] and (.roles | index("os:admin"))' info.json >/dev/null ||
      { cat info.json >&2; exit 1; }

    # Google's auth library loads the key file and signs with the key whose certificate GCP holds.
    python3 - <<'EOF'
    from google.oauth2 import service_account
    credentials = service_account.Credentials.from_service_account_file("runtime/gcp.json")
    assert credentials.service_account_email == "ops-test@infra-464520.iam.gserviceaccount.com"
    assert credentials.signer.key_id == "0123abcd"
    open("signature", "wb").write(credentials.signer.sign(b"probe"))
    EOF
    printf probe > data
    openssl x509 -in state/gcp.crt -pubkey -noout > gcp.pub
    openssl dgst -sha256 -verify gcp.pub -signature signature data

    # Withdrawn public material removes the assembled file.
    ops-credentials assemble state runtime
    expect "runtime files after withdrawal" "$(ls runtime | wc -l)" 0

    # The admin kubeconfig comes from local-talos' Terraform output, written but never printed.
    mkdir -p bin layer
    cat > bin/terraform <<'EOF'
    #!${pkgs.runtimeShell}
    [ "$1" = -chdir=layer ] || { echo "unexpected directory: $1" >&2; exit 1; }
    case "$2 $3 $4" in
    "init -input=false -no-color") echo "Terraform has been successfully initialized!" ;;
    "output -raw kubeconfig") cat "$KUBECONFIG_OUTPUT" ;;
    *) echo "unexpected command: $*" >&2; exit 1 ;;
    esac
    EOF
    chmod +x bin/terraform
    cat > kubeconfig.yaml <<'EOF'
    apiVersion: v1
    kind: Config
    clusters: [{name: klusse, cluster: {server: "https://api.k8s.kalski.xyz:6443"}}]
    users: [{name: admin@klusse, user: {client-certificate-data: Q0VSVA==, client-key-data: U0VDUkVUS0VZREFUQQ==}}]
    contexts: [{name: admin@klusse, context: {cluster: klusse, user: admin@klusse}}]
    current-context: admin@klusse
    EOF
    PATH=$PWD/bin:$PATH KUBECONFIG_OUTPUT=kubeconfig.yaml ops-credentials kubeconfig layer runtime > printed 2>&1
    grep -q U0VDUkVUS0VZREFUQQ printed && { echo "the kubeconfig was printed" >&2; exit 1; }
    expect kubeconfig "$(mode runtime/kubeconfig)" 400
    expect "kubeconfig server" "$(kubectl --kubeconfig runtime/kubeconfig config view --raw \
      -o jsonpath='{.clusters[0].cluster.server} {.users[0].user.client-key-data}')" \
      "https://api.k8s.kalski.xyz:6443 U0VDUkVUS0VZREFUQQ=="
    # Concurrent refreshes each publish a complete kubeconfig.
    for run in 1 2 3 4 5 6 7 8; do
      PATH=$PWD/bin:$PATH KUBECONFIG_OUTPUT=kubeconfig.yaml ops-credentials kubeconfig layer runtime > printed.$run 2>&1 &
    done
    for run in 1 2 3 4 5 6 7 8; do wait -n || { cat printed.* >&2; echo "a concurrent refresh failed" >&2; exit 1; }; done
    cmp runtime/kubeconfig kubeconfig.yaml
    expect "kubeconfig after concurrent refreshes" "$(mode runtime/kubeconfig)" 400
    # A failed, empty or unusable output keeps the previous kubeconfig and fails.
    printf 'not: [a kubeconfig' > broken.yaml
    cat > incomplete.yaml <<'EOF'
    apiVersion: v1
    kind: Config
    clusters: [{name: klusse, cluster: {server: "https://api.k8s.kalski.xyz:6443"}}]
    EOF
    for output in broken.yaml /dev/null missing.yaml incomplete.yaml; do
      if PATH=$PWD/bin:$PATH KUBECONFIG_OUTPUT=$output ops-credentials kubeconfig layer runtime > printed 2>&1; then
        echo "kubeconfig from $output succeeded" >&2; exit 1
      fi
      cmp runtime/kubeconfig kubeconfig.yaml
    done
    expect "runtime files with a kubeconfig" "$(ls -A runtime)" kubeconfig
    touch "$out"
  ''
