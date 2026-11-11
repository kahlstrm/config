# Runs ops' credential tool as its boot services do: keys are generated once and kept on
# reruns, and committed public material turns them into a talosconfig and a service account
# key file that talosctl and Google's auth library read, readable only by their owner. The
# kubeconfig and the RouterOS netrc come from Terraform outputs in GCS without being printed.
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
      pkgs.openssh
      pkgs.gawk
      pkgs.jq
      pkgs.kubectl
      python
    ];
  }
  ''
    set -euo pipefail
    export HOME=$PWD OPS_TALOS_CLIENT_IP=10.83.0.6
    mode() { stat -c %a "$1"; }
    expect() { [ "$2" = "$3" ] || { echo "$1: expected $3, got $2" >&2; exit 1; }; }
    files="talos.key talos.csr gcp.key gcp.crt deploy.key deploy.pub"

    ops-credentials generate state
    expect "state directory" "$(mode state)" 700
    for key in talos.key gcp.key deploy.key; do expect "$key" "$(mode state/$key)" 400; done
    # The deploy key is an Ed25519 SSH key whose public half the operator commits.
    expect "deploy key type" "$(ssh-keygen -l -f state/deploy.pub | awk '{print $NF}')" "(ED25519)"
    expect "deploy key comment" "$(cut -d' ' -f3 state/deploy.pub)" ops-deploy
    (cd state && sha256sum $files) > before
    ops-credentials generate state
    (cd state && sha256sum $files) | diff before - || { echo "a rerun replaced keys" >&2; exit 1; }
    # A missing public half is recreated from the kept key.
    rm state/gcp.crt state/deploy.pub
    ops-credentials generate state
    (cd state && sha256sum talos.key gcp.key deploy.key deploy.pub) |
      diff <(grep -E 'talos.key|gcp.key|deploy.key|deploy.pub' before) -

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

    # The kubeconfig and the RouterOS netrc come from outputs in the layers' Terraform state in
    # GCS, read with a token for the assembled key, written but never printed. The fake curl is
    # Google's token endpoint, which checks the key's signed assertion, and the state bucket.
    OPS_GCP_EMAIL=ops-test@infra-464520.iam.gserviceaccount.com OPS_GCP_KEY_ID=0123abcd \
      OPS_GCP_PROJECT=infra-464520 ops-credentials assemble state runtime
    mkdir -p bin
    cat > bin/curl <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    data= header= url=
    while [ $# -gt 0 ]; do
      case "$1" in
      --data) [ "$2" = @- ] && data=$(cat); shift ;;
      -H) header=$(cat "''${2#@}"); shift ;;
      https://*) url=$1 ;;
      esac
      shift
    done
    decode() { local s; s=$(tr -- '-_' '+/'); while [ $(( ''${#s} % 4 )) != 0 ]; do s+==; done; base64 -d <<<"$s"; }
    case "$url" in
    https://oauth2.googleapis.com/token)
      [ "''${data%%&*}" = grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer ] || { echo "grant: $data" >&2; exit 22; }
      IFS=. read -r h c sig <<<"''${data#*&assertion=}"
      decode <<<"$h" | jq -e '.alg == "RS256" and .kid == "0123abcd"' >/dev/null || { echo "header" >&2; exit 22; }
      decode <<<"$c" | jq -e '.iss == "ops-test@infra-464520.iam.gserviceaccount.com"
        and .aud == "https://oauth2.googleapis.com/token"
        and .scope == "https://www.googleapis.com/auth/devstorage.read_only" and .exp - .iat <= 3600' >/dev/null ||
        { echo "claims" >&2; exit 22; }
      signature=$(mktemp)
      decode <<<"$sig" > "$signature"
      printf %s "$h.$c" | openssl dgst -sha256 -verify "$GCP_PUB" -signature "$signature" >/dev/null ||
        { echo '{"error": "invalid_grant"}'; exit 22; }
      echo '{"access_token": "ya29.test", "expires_in": 3599, "token_type": "Bearer"}' ;;
    "https://storage.googleapis.com/storage/v1/b/terraform-state-1751317459/o/$STATE_PREFIX%2Fdefault.tfstate?alt=media")
      [ "$header" = "Authorization: Bearer ya29.test" ] || { echo "header: $header" >&2; exit 22; }
      [ -e "$STATE_OUTPUT" ] || { echo '{"error": {"code": 404}}'; exit 22; }
      cat "$STATE_OUTPUT" ;;
    *) echo "unexpected URL: $url" >&2; exit 22 ;;
    esac
    EOF
    chmod +x bin/curl
    # A state file whose output $2 holds file $1's contents.
    state() { jq -n --rawfile value "$1" --arg name "$2" '{version: 4, outputs: {($name): {value: $value, type: "string", sensitive: true}}}'; }
    fetch() { PATH=$PWD/bin:$PATH GCP_PUB=$PWD/gcp.pub STATE_PREFIX=$1 STATE_OUTPUT=$2 ops-credentials "''${@:3}"; }

    cat > kubeconfig.yaml <<'EOF'
    apiVersion: v1
    kind: Config
    clusters: [{name: klusse, cluster: {server: "https://api.k8s.kalski.xyz:6443"}}]
    users: [{name: admin@klusse, user: {client-certificate-data: Q0VSVA==, client-key-data: U0VDUkVUS0VZREFUQQ==}}]
    contexts: [{name: admin@klusse, context: {cluster: klusse, user: admin@klusse}}]
    current-context: admin@klusse
    EOF
    state kubeconfig.yaml kubeconfig > talos.tfstate
    location=terraform-state-1751317459/local-talos
    fetch local-talos talos.tfstate kubeconfig $location runtime > printed 2>&1 || { cat printed >&2; exit 1; }
    grep -q -e U0VDUkVUS0VZREFUQQ -e ya29 printed && { echo "the kubeconfig or token was printed" >&2; exit 1; }
    expect kubeconfig "$(mode runtime/kubeconfig)" 400
    cmp runtime/kubeconfig kubeconfig.yaml
    # Concurrent refreshes each publish a complete kubeconfig.
    for run in 1 2 3 4 5 6 7 8; do
      fetch local-talos talos.tfstate kubeconfig $location runtime > printed.$run 2>&1 &
    done
    for run in 1 2 3 4 5 6 7 8; do wait -n || { cat printed.* >&2; echo "a concurrent refresh failed" >&2; exit 1; }; done
    cmp runtime/kubeconfig kubeconfig.yaml
    expect "kubeconfig after concurrent refreshes" "$(mode runtime/kubeconfig)" 400
    # A missing, empty or unusable state or output keeps the previous kubeconfig and fails.
    printf 'not: [a kubeconfig' > broken.yaml
    cat > incomplete.yaml <<'EOF'
    apiVersion: v1
    kind: Config
    clusters: [{name: klusse, cluster: {server: "https://api.k8s.kalski.xyz:6443"}}]
    EOF
    state broken.yaml kubeconfig > broken.tfstate
    state incomplete.yaml kubeconfig > incomplete.tfstate
    state kubeconfig.yaml other > other.tfstate
    jq '.outputs.kubeconfig.value = 3' talos.tfstate > number.tfstate
    for output in missing.tfstate /dev/null broken.tfstate incomplete.tfstate other.tfstate number.tfstate; do
      if fetch local-talos $output kubeconfig $location runtime > printed 2>&1; then
        echo "kubeconfig from $output succeeded" >&2; exit 1
      fi
      cmp runtime/kubeconfig kubeconfig.yaml
    done
    # So does a key GCP doesn't hold: the token endpoint refuses its assertion.
    cp -p runtime/gcp.json gcp.json.good
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out other.key 2>/dev/null
    jq --rawfile key other.key '.private_key = $key' gcp.json.good > runtime/gcp.json.new
    mv -f runtime/gcp.json.new runtime/gcp.json
    if fetch local-talos talos.tfstate kubeconfig $location runtime > printed 2>&1; then
      echo "a refused key succeeded" >&2; exit 1
    fi
    cmp runtime/kubeconfig kubeconfig.yaml
    cp -p gcp.json.good runtime/gcp.json
    expect "runtime files with a kubeconfig" "$(ls -A runtime | sort | tr '\n' ' ')" "gcp.json kubeconfig "

    # The RouterOS netrc comes from local-networking's password output, also never printed.
    printf Abcdefghijklmnop0123456789XYZabc > password
    state password ops_routeros_password > networking.tfstate
    location=terraform-state-1751317459/local-networking
    fetch local-networking networking.tfstate routeros $location runtime kuberack.example > printed 2>&1 ||
      { cat printed >&2; exit 1; }
    grep -q -e Abcdefghijklmnop -e ya29 printed && { echo "the password or token was printed" >&2; exit 1; }
    expect routeros.netrc "$(mode runtime/routeros.netrc)" 400
    expect "routeros.netrc" "$(cat runtime/routeros.netrc)" \
      "machine kuberack.example login ops password Abcdefghijklmnop0123456789XYZabc"
    cp runtime/routeros.netrc netrc.before
    # A missing, empty, short or netrc-breaking output keeps the previous netrc and fails.
    printf short > short
    printf 'Abcdefghijklmnop0123 machine evil' > spaced
    state short ops_routeros_password > short.tfstate
    state spaced ops_routeros_password > spaced.tfstate
    for output in missing.tfstate /dev/null short.tfstate spaced.tfstate talos.tfstate; do
      if fetch local-networking $output routeros $location runtime kuberack.example > printed 2>&1; then
        echo "netrc from $output succeeded" >&2; exit 1
      fi
      cmp runtime/routeros.netrc netrc.before
    done
    expect "runtime files with both" "$(ls -A runtime | sort | tr '\n' ' ')" "gcp.json kubeconfig routeros.netrc "

    # Home Assistant's token becomes a curl header file, also never printed.
    printf eyJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJvcHMifQ.c2lnbmF0dXJlX3Rlc3Q > token
    state token ops_home_assistant_token > networking.tfstate
    fetch local-networking networking.tfstate home-assistant $location runtime > printed 2>&1 ||
      { cat printed >&2; exit 1; }
    grep -q -e c2lnbmF0dXJlX3Rlc3Q -e ya29 printed && { echo "the HA or GCS token was printed" >&2; exit 1; }
    expect home-assistant.headers "$(mode runtime/home-assistant.headers)" 400
    expect "home-assistant.headers" "$(cat runtime/home-assistant.headers)" \
      "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJvcHMifQ.c2lnbmF0dXJlX3Rlc3Q"
    cp runtime/home-assistant.headers headers.before
    # A missing, empty, non-JWT or header-injecting output keeps the previous file and fails.
    printf not-a-token > plain
    printf 'eyJh.eyJp.c2ln\nX-Injected: 1' > injected
    state plain ops_home_assistant_token > plain.tfstate
    state injected ops_home_assistant_token > injected.tfstate
    for output in missing.tfstate /dev/null plain.tfstate injected.tfstate talos.tfstate; do
      if fetch local-networking $output home-assistant $location runtime > printed 2>&1; then
        echo "headers from $output succeeded" >&2; exit 1
      fi
      cmp runtime/home-assistant.headers headers.before
    done
    expect "runtime files with all three" "$(ls -A runtime | sort | tr '\n' ' ')" \
      "gcp.json home-assistant.headers kubeconfig routeros.netrc "
    touch "$out"
  ''
