# Runs ops' credential tool as its boot services do: keys are generated once and kept on
# reruns, and committed public material turns them into a talosconfig and a service account
# key file that talosctl and Google's auth library read, readable only by their owner.
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
      python
    ];
  }
  ''
    set -euo pipefail
    export HOME=$PWD OPS_TALOS_CLIENT_IP=10.83.0.6
    mode() { stat -c %a "$1"; }
    expect() { [ "$2" = "$3" ] || { echo "$1: expected $3, got $2" >&2; exit 1; }; }
    files="talos.key talos.csr gcp.key gcp.crt"

    ops-credentials generate state
    expect "state directory" "$(mode state)" 700
    for key in talos.key gcp.key; do expect "$key" "$(mode state/$key)" 400; done
    (cd state && sha256sum $files) > before
    ops-credentials generate state
    (cd state && sha256sum $files) | diff before - || { echo "a rerun replaced keys" >&2; exit 1; }
    # A missing public half is recreated from the kept key.
    rm state/gcp.crt
    ops-credentials generate state
    (cd state && sha256sum talos.key gcp.key) | diff <(grep -E 'talos.key|gcp.key' before) -

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
    touch "$out"
  ''
