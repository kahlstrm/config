#!/usr/bin/env bash
# shellcheck disable=SC2329  # steps run by name: "step_${step//-/_}"
# op.sh STEP [ARGS...]: the operator (OP) steps of the Flannel → Cilium cutover runbook (#228), one approved
# command per runbook step: `bash local-talos/cutover/op.sh <step>` from infra/. `op.sh help` lists the steps.
#
# - Guard: refuses unless the checkout is clean and HEAD is origin/main after a fetch, so every step runs reviewed
#   code. It then re-runs itself in `nix develop .#cutover`, whose tools (terraform, talosctl, kubectl, flux,
#   cni-pods, hubble, ...) are pinned by that same commit.
# - State: ~/cutover (CUTOVER_STATE overrides): t0, the applied-node log, the window log, ALLOW, budgets and
#   diagnostics, shared by separate invocations. `apply c1` sets T0; steps that need T0 refuse without it.
# - Deadlines: every command runs under the lesser of its runbook deadline and the step's own cap (29 min; ops ends
#   a command after 30), and no command starts once that has passed.
# - Exit codes: 0 done; 124 a deadline passed (the printed hint says which); 1 failed (follow the printed ROUTE);
#   2 usage; 3 refused (guard or state).
set -uo pipefail
export LC_ALL=C

INFRA=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE=${CUTOVER_STATE:-$HOME/cutover}
REMOTE=${CUTOVER_REMOTE:-origin}
STEP_CAP=${CUTOVER_STEP_CAP:-1740}
TF="$INFRA/local-talos"
NODES_ALL="c1 c2 c3 w1 w2"
CPS=10.10.10.11,10.10.10.12,10.10.10.13
NODE_IPS=$CPS,10.10.10.21,10.10.10.22
LB=10.10.10.80

die() { echo "REFUSED: $*" >&2; exit 3; }
usage() { echo "usage: op.sh $*" >&2; exit 2; }
now() { date -u +%Y-%m-%dT%H:%M:%S; }
log() { mkdir -p "$STATE" && echo "$(now) $*" >> "$STATE/log"; }
route() {  # which rollback, from the applied-node log alone: A only if c1 alone was attempted
  local others
  [ -s "$STATE/applied" ] || { echo "Rollback B (no applied-node log)"; return; }
  others=$(awk '$2 != "c1" {print $2}' "$STATE/applied" | sort -u | tr '\n' ' ')
  if [ -n "$others" ]; then echo "Rollback B (attempted beyond c1: $others)"; else echo "Rollback A"; fi
}
hint() { echo "ROUTE: $*" >&2; }
rollback_hint() { hint "roll back by log: $(route) → op.sh rollback-apply $(route | awk '{print tolower($2)}')"; }

# ---- guard, then the pinned tools -------------------------------------------------------------------------------
guard() {
  local head
  [ -z "$(git -C "$INFRA" status --porcelain)" ] || die "the checkout has local changes; only reviewed main runs"
  timeout 60 git -C "$INFRA" fetch -q "$REMOTE" main || die "git fetch $REMOTE main failed"
  head=$(git -C "$INFRA" rev-parse HEAD)
  [ "$head" = "$(git -C "$INFRA" rev-parse "$REMOTE/main")" ] || die "HEAD $head is not $REMOTE/main; run git pull --ff-only first"
  echo "$head"
}
if [ "${CUTOVER_GUARDED:-}" != "$(git -C "$INFRA" rev-parse HEAD 2>/dev/null)" ] || [ -n "$(git -C "$INFRA" status --porcelain 2>/dev/null)" ]; then
  CUTOVER_GUARDED=$(guard) || exit 3
  export CUTOVER_GUARDED
fi
if [ "${CUTOVER_SHELL:-}" != 1 ]; then
  exec nix develop "$INFRA#cutover" --command bash "${BASH_SOURCE[0]}" "$@"
fi
mkdir -p "$STATE" && chmod 700 "$STATE"
STEP_START=$(date +%s)
STEP_END=$(( STEP_START + STEP_CAP ))

# ---- deadlines ---------------------------------------------------------------------------------------------------
t0_epoch() { date -d "$(cat "$STATE/t0")Z" +%s; }
need_t0() { [ -s "$STATE/t0" ] || die "T0 is not set; the window starts with op.sh apply c1"; T0=$(cat "$STATE/t0"); }
at() { echo $(( $(date -d "${1}Z" +%s) + $2 * 60 )); }     # at BASE MINUTES: epoch of BASE + MINUTES
cap() { local e=$1; [ "$e" -lt "$STEP_END" ] || e=$STEP_END; echo "$e"; }   # the lesser of a deadline and the step cap
rl_left() { local r=$(( $1 - $(date +%s) )); [ "$r" -gt 0 ] || r=0; [ "$r" -lt "$2" ] || r=$2; echo "$r"; }
rl_run() {  # rl_run END CAP CMD...: CMD under the lesser of CAP and the time left to END; 124 once END has passed
  local t rc; t=$(rl_left "$1" "$2"); shift 2
  [ "$t" -gt 0 ] || { echo "DEADLINE PASSED: not running: $*" >&2; return 124; }
  timeout "$t" "$@"; rc=$?
  [ "$rc" = 124 ] && echo "DEADLINE REACHED: interrupted: $*" >&2
  return "$rc"
}
deadline_exit() {  # deadline_exit WHAT: report which deadline ended the step, and exit 124
  if [ "$(date +%s)" -ge "$STEP_END" ] && [ "${RUNBOOK_END:-0}" -gt "$STEP_END" ]; then
    hint "the step's 29-minute cap ended $1, not the runbook deadline: run the same step again"
  else
    hint "the runbook deadline for $1 passed: take the action the runbook names for it"
  fi
  exit 124
}
budget() {  # budget NAME MINUTES: a recovery budget set on first use and shared by later steps; prints its end
  [ -s "$STATE/$1" ] || now > "$STATE/$1"
  at "$(cat "$STATE/$1")" "$2"
}

# ---- nodes, Terraform --------------------------------------------------------------------------------------------
ip_of() { case $1 in c1) echo 10.10.10.11;; c2) echo 10.10.10.12;; c3) echo 10.10.10.13;; w1) echo 10.10.10.21;; w2) echo 10.10.10.22;; *) return 1;; esac; }
node_ok() { ip_of "$1" >/dev/null || usage "${2:-STEP} <c1|c2|c3|w1|w2>"; }
tf_addr() { case $1 in c*) echo "module.cluster.talos_machine.controlplane[\"$1.k8s.kalski.xyz\"]";; w*) echo "module.cluster.talos_machine.worker[\"$1.k8s.kalski.xyz\"]";; esac; }
tf() { terraform -chdir="$TF" "$@"; }
tf_apply() {  # tf_apply NODE [ARGS...]: one targeted apply under 300 s, logged before and after
  local n=$1 rc; shift
  echo "attempt $n $(now)" >> "$STATE/applied"; log "attempt $n $*"
  rl_run "$STEP_END" 300 terraform -chdir="$TF" apply -auto-approve -input=false -no-color -lock-timeout=60s "$@" -target="$(tf_addr "$n")"; rc=$?
  if [ "$rc" = 0 ]; then echo "applied $n $(now)" >> "$STATE/applied"; log "applied $n"; fi
  return "$rc"
}

# ---- cluster helpers (from the runbook) --------------------------------------------------------------------------
agent_ready() { [ "$(rl_run "$1" 30 kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="$2" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" = True ]; }
agent_status() {  # agent_status END: every agent prints OK
  local p pods n=0 ok=0 out
  pods=$(rl_run "$1" 30 kubectl -n kube-system get pods -l k8s-app=cilium -o name) || return 1
  for p in $pods; do
    n=$((n + 1))
    out=$(rl_run "$1" 30 kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status --brief 2>&1); echo "$p: $out"
    [ "$out" = OK ] && ok=$((ok + 1))
  done
  echo "agent status: $ok of $n OK"; [ "$n" = 5 ] && [ "$ok" = 5 ]
}
operator_ready() { [ "$(rl_run "$1" 30 kubectl -n kube-system get deploy cilium-operator -o jsonpath='{.status.readyReplicas}')" = 2 ]; }
node_probes() {  # node_probes END: from each node, kube-dns's Service, Traefik's pod and a CoreDNS pod elsewhere
  local traefik dns n out bad=0 try
  traefik=$(rl_run "$1" 30 kubectl -n traefik get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}') || return 1
  for n in $NODES_ALL; do
    dns=$(rl_run "$1" 30 kubectl -n kube-system get pods -l k8s-app=kube-dns -o json | jq -r --arg n "$n" '[.items[]|select(.spec.nodeName!=$n and .status.phase=="Running")][0].status.podIP') || return 1
    for try in 1 2 3; do
      out=$(rl_run "$1" 90 kubectl -n kube-system run "probe-$n-$(date +%s)" --rm -i --restart=Never --image=busybox:1.37 \
        --overrides="{\"spec\":{\"nodeName\":\"$n\",\"tolerations\":[{\"operator\":\"Exists\"}]}}" --command -- sh -c \
        "echo \"ip=\$(hostname -i)\"; timeout 5 nslookup kubernetes.default.svc.cluster.local 10.96.0.10 >/dev/null && echo ok; nc -w 3 -z $traefik 80 && echo ok; nc -w 3 -z $dns 53 && echo ok" 2>&1)
      echo "$n: $(tr '\n' ' ' <<<"$out")"
      [ "$(grep -cx ok <<<"$out")" = 3 ] && break
      # A pod on its node's cni0 address (10.244.<n>.1, while the bridge is up) is the known collision: try again.
      grep -qE 'ip=10\.244\.[0-9]+\.1$' <<<"$out" && [ "$try" -lt 3 ] && { echo "$n: probe pod got its node's cni0 address; again"; continue; }
      bad=$((bad + 1)); break
    done
  done
  [ "$bad" = 0 ]
}
cnipods() { rl_run "$1" "$2" cni-pods "${@:3}"; }   # cnipods END CAP ARGS...

# remove_link NODE cni0|flannel1 END: local-talos/cni0-remove.yaml on NODE once its agent is Ready, bounded by END;
# the pod refuses unless Cilium's CNI config is active and verifies the link, its addresses and routes are gone.
# Cleanup on every path: one delete under its own 30 s; diagnostics first on abnormal paths; a failed delete is
# logged UNRESOLVED (deleted after the window, not retried now) and exits 1. Worst case past END: 70 s.
rl_diag() { { timeout 20 kubectl -n kube-system describe pod "$2"; timeout 20 kubectl -n kube-system logs "$2"; } > "$STATE/remove-diag-$1.txt" 2>&1; }
rl_cleanup() {
  local n=$1 pod=$2 why=$3
  [ "${4:-}" = diag ] && rl_diag "$n" "$pod"
  timeout 30 kubectl -n kube-system delete pod "$pod" --ignore-not-found --wait=false >/dev/null && return 0
  [ "${4:-}" = diag ] || rl_diag "$n" "$pod"
  log "UNRESOLVED: pod kube-system/$pod not deleted ($why); delete it after the window"
  echo "UNRESOLVED: kube-system/$pod not deleted ($why); logged, diagnostics in $STATE/remove-diag-$n.txt; don't retry now" >&2
  return 1
}
remove_link() {
  local n=$1 action=$2 end=$3 pod=cni0-remove-$1 phase="" out rc
  agent_ready "$end" "$n" || { echo "NOT REMOVED: $n's Cilium agent isn't Ready (or the deadline passed)" >&2; return 1; }
  rl_run "$end" 40 kubectl -n kube-system delete pod "$pod" --ignore-not-found --wait --timeout=30s >/dev/null ||
    { echo "NOT REMOVED: $action on $n: an earlier $pod could not be deleted in time" >&2; rl_cleanup "$n" "$pod" "earlier pod"; return 1; }
  sed -e "s/NODE_NAME/$n/" -e "s/ACTION_VALUE/$action/" "$TF/cni0-remove.yaml" | rl_run "$end" 30 kubectl create -f - >/dev/null; rc=$?
  [ "$rc" = 0 ] || { echo "NOT REMOVED: $action on $n: creating $pod failed (exit $rc)" >&2; rl_cleanup "$n" "$pod" "create failed" diag; return 1; }
  until case $phase in Succeeded|Failed) true ;; *) false ;; esac; do
    [ "$(rl_left "$end" 5)" -gt 0 ] || { echo "NOT REMOVED: $action on $n: deadline passed (phase ${phase:-unknown})" >&2; rl_cleanup "$n" "$pod" "deadline, phase ${phase:-unknown}" diag; return 1; }
    phase=$(rl_run "$end" 15 kubectl -n kube-system get pod "$pod" -o jsonpath='{.status.phase}')
    case $phase in Succeeded|Failed) ;; *) sleep "$(rl_left "$end" 5)" ;; esac
  done
  out=$(rl_run "$end" 30 kubectl -n kube-system logs "$pod"); rc=$?
  [ "$rc" = 0 ] || { echo "NOT REMOVED: $action on $n: reading $pod's log failed (exit $rc)" >&2; rl_cleanup "$n" "$pod" "log unread" diag; return 1; }
  echo "$out"
  rl_cleanup "$n" "$pod" "after $phase" || return 1
  if [ "$phase" != Succeeded ] || ! grep -q "^verified:" <<<"$out"; then echo "NOT REMOVED: $action on $n ($phase)" >&2; return 1; fi
}
remove_all() {  # remove_all cni0|flannel1 END
  local n bad=0
  for n in $NODES_ALL; do
    [ "$(date +%s)" -lt "$2" ] || { echo "removal budget spent; not started on $n"; bad=1; break; }
    remove_link "$n" "$1" "$2" || bad=1
  done
  return "$bad"
}

# reboot_node NODE [uncordoned]: cordon, reboot, require a new boot ID and the kubelet reporting it with Ready, uncordon,
# then delete the operator's Failed pods. One 15-minute deadline from before the reboot; every probe and sleep is
# capped to the time left and counts only before it. A failed cordon stops, except with `uncordoned` (rollback only,
# logged). Pods placed on the node while it shut down (not DaemonSets') are reported as PILE-UP.
reboot_node() {
  local n=$1 mode=${2:-} ip pods boot0 boot="" seen deadline t rejected p kind
  ip=$(ip_of "$n") || return 1
  if ! timeout 60 kubectl cordon "$n"; then
    [ "$mode" = uncordoned ] || { echo "STOP: cordon $n failed" >&2; return 1; }
    log "UNCORDONED REBOOT: $n (rollback exception)"; echo "UNCORDONED REBOOT: $n (rollback exception, logged)" >&2
  fi
  pods=$(timeout 60 kubectl get pods -A --field-selector spec.nodeName="$n" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}') ||
    { echo "STOP: cannot read the pods on $n" >&2; return 1; }
  boot0=$(timeout 30 talosctl -n "$ip" read /proc/sys/kernel/random/boot_id) && [ -n "$boot0" ] ||
    { echo "STOP: cannot read $n's boot ID" >&2; return 1; }
  deadline=$(( $(date +%s) + 900 ))
  timeout "$(rl_left "$deadline" 600)" talosctl -n "$ip" reboot --wait --timeout 9m ||
    echo "WARN: talosctl reboot $n exited $?; checking the boot ID" >&2
  while :; do
    t=$(rl_left "$deadline" 15); [ "$t" -gt 0 ] || { echo "STOP: $n's boot ID is unchanged 15 min after the reboot started; it didn't reboot" >&2; return 1; }
    boot=$(timeout "$t" talosctl -n "$ip" read /proc/sys/kernel/random/boot_id 2>/dev/null)
    [ "$(date +%s)" -lt "$deadline" ] || { echo "STOP: $n's boot ID is unchanged 15 min after the reboot started; it didn't reboot" >&2; return 1; }
    [ -n "$boot" ] && [ "$boot" != "$boot0" ] && break
    sleep "$(rl_left "$deadline" 10)"
  done
  while :; do
    t=$(rl_left "$deadline" 15); [ "$t" -gt 0 ] || { echo "STOP: $n not Ready on its new boot within 15 min of the reboot" >&2; return 1; }
    seen=$(timeout "$t" kubectl get node "$n" -o jsonpath='{.status.nodeInfo.bootID} {.status.conditions[?(@.type=="Ready")].status}')
    [ "$(date +%s)" -lt "$deadline" ] || { echo "STOP: $n not Ready on its new boot within 15 min of the reboot" >&2; return 1; }
    [ "$seen" = "$boot True" ] && break
    sleep "$(rl_left "$deadline" 10)"
  done
  timeout 60 kubectl uncordon "$n" || { echo "STOP: $n still cordoned" >&2; return 1; }
  rejected=$(timeout 60 kubectl get pods -A --field-selector spec.nodeName="$n",status.phase=Failed -o jsonpath='{range .items[?(@.status.reason=="NodeShutdown")]}{.metadata.namespace}/{.metadata.name} {.metadata.ownerReferences[0].kind}{"\n"}{end}')
  while read -r p kind; do
    [ -n "$p" ] && [ "$kind" != DaemonSet ] && ! grep -qxF "$p" <<<"$pods" && echo "PILE-UP: $p placed on $n while it shut down" >&2
  done <<<"$rejected"
  timeout 90 kubectl -n kube-system delete pods -l io.cilium/app=operator --field-selector status.phase=Failed --timeout=60s
}
repair() {  # repair NODE inspect|repair END: local-talos/cni-repair.yaml on NODE; prints its log
  local n=$1 pod=cni-repair-$1 rc
  rl_run "$3" 40 kubectl -n kube-system delete pod "$pod" --ignore-not-found --wait --timeout=30s >/dev/null || return 1
  sed -e "s/NODE_NAME/$n/" -e "s/ACTION_VALUE/$2/" "$TF/cni-repair.yaml" | rl_run "$3" 30 kubectl create -f - >/dev/null || return 1
  rl_run "$3" 180 kubectl -n kube-system wait "pod/$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m &&
    rl_run "$3" 30 kubectl -n kube-system logs "$pod"; rc=$?
  timeout 60 kubectl -n kube-system delete pod "$pod" --wait >/dev/null
  return "$rc"
}
hubble_observe() {  # hubble_observe END ARGS...: hubble observe through a port-forward to hubble-relay
  local end=$1 pf rc=0; shift
  rl_run "$end" 180 kubectl -n kube-system port-forward svc/hubble-relay 4245:80 > "$STATE/hubble-pf.log" 2>&1 & pf=$!
  for _ in $(seq 1 30); do timeout 3 nc -z 127.0.0.1 4245 2>/dev/null && break; sleep 1; done
  if timeout 3 nc -z 127.0.0.1 4245 2>/dev/null; then rl_run "$end" 120 hubble observe --server 127.0.0.1:4245 "$@" || rc=$?
  else echo "hubble-relay port-forward not ready: $(cat "$STATE/hubble-pf.log")" >&2; rc=1; fi
  kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
  return "$rc"
}
upgrade_k8s() {  # upgrade_k8s END [--dry-run]: talosctl upgrade-k8s to the pinned version; prints its output
  local tv; tv=$(jq -r .kubernetes "$TF/versions.json")
  rl_run "$1" "$([ "${2:-}" = --dry-run ] && echo 300 || echo 600)" talosctl -n 10.10.10.11 upgrade-k8s --to "$tv" ${2:+"$2"} 2>&1
}
changes() { awk -v a="$1" '$1 == "<" && $2 == a {print $3}' | sort -u | tr '\n' ' ' | sed 's/ $//'; }  # changes Pruned|deleted < upgrade-k8s output

# ---- section 6 checks --------------------------------------------------------------------------------------------
FAILED=0
check() {  # check NAME CMD...: run one check, print PASS/FAIL
  local name=$1 out rc; shift
  out=$("$@" 2>&1); rc=$?
  printf '%s\n' "$out" | sed "s/^/  [$name] /"
  if [ "$rc" = 0 ]; then echo "PASS $name"; else echo "FAIL $name (exit $rc)"; FAILED=1; fi
  log "check $name rc=$rc"
}
t1() { local h bad=0; for h in grafana harbor id auth; do
  rl_run "$1" 10 curl -sS --max-time 10 -o /dev/null -w "$h %{http_code} %{ssl_verify_result}\n" --resolve "$h.kube.kalski.xyz:443:$LB" "https://$h.kube.kalski.xyz/" | tee /dev/stderr | grep -qE ' (200|302) 0$' || bad=1; done; return "$bad"; }
t3_https() { rl_run "$1" 15 curl -sS --max-time 15 --resolve "harbor.kube.kalski.xyz:443:$LB" https://harbor.kube.kalski.xyz/api/v2.0/health | jq -e '.status == "healthy"'; }
t4() {  # Pocket ID sync re-run from the revision Flux last applied (Flux suspended)
  local rev d cm rc
  rev=$(rl_run "$1" 30 kubectl -n flux-system get kustomization apps -o jsonpath='{.status.lastAppliedRevision}') && [ -n "$rev" ] || return 1
  d=$(mktemp -d)
  git -C "$INFRA/.." archive "${rev##*:}" infra/local-kubernetes/apps/pocket-id-sync | tar -x -C "$d" &&
    timeout 60 kustomize build "$d/infra/local-kubernetes/apps/pocket-id-sync" > "$d/all.yaml" &&
    cm=$(yq -e 'select(.kind=="ConfigMap") | .metadata.name' "$d/all.yaml") &&
    rl_run "$1" 30 kubectl -n pocket-id get configmap "$cm" -o name &&
    yq -e 'select(.kind=="Job" and .metadata.name=="pocket-id-sync")' "$d/all.yaml" > "$d/job.yaml" &&
    grep -q "$cm" "$d/job.yaml" &&
    rl_run "$1" 130 kubectl -n pocket-id delete job pocket-id-sync --ignore-not-found --wait --timeout=2m &&
    rl_run "$1" 30 kubectl -n pocket-id create -f "$d/job.yaml" &&
    rl_run "$1" 310 kubectl -n pocket-id wait job/pocket-id-sync --for=condition=complete --timeout=5m; rc=$?
  rl_run "$1" 30 kubectl -n pocket-id logs job/pocket-id-sync; rm -rf "$d"; return "$rc"
}
t6() {  # the netpol canary, as a Job from its CronJob
  local j rc=0; j=canary-$(date +%s)
  rl_run "$1" 30 kubectl -n netpol-canary create job "$j" --from=cronjob/netpol-canary >/dev/null || return 1
  rl_run "$1" 190 kubectl -n netpol-canary wait "job/$j" --for=condition=complete --timeout=3m || rc=1
  rl_run "$1" 30 kubectl -n netpol-canary logs "job/$j"; timeout 30 kubectl -n netpol-canary delete job "$j" --wait=false >/dev/null; return "$rc"
}
t7() {  # sandbox first packet: the modem (denied) and kube-dns (allowed) at +0 and +5 s; prints the lines
  local p rc; p=sandbox-probe-$(date +%s)
  rl_run "$1" 30 kubectl -n agent-sandbox create -f - <<EOF >/dev/null || return 1
apiVersion: v1
kind: Pod
metadata: {name: $p}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  activeDeadlineSeconds: 60
  securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
      command: [sh, -c, 'for t in 0 5; do [ \$t = 0 ] || sleep 5; nc -w 2 -z 192.168.100.1 80 && echo "+\${t}s modem CONNECTED" || echo "+\${t}s modem blocked"; nc -w 2 -z 10.96.0.10 53 && echo "+\${t}s dns connected" || echo "+\${t}s dns BLOCKED"; done']
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
  rl_run "$1" 130 kubectl -n agent-sandbox wait "pod/$p" --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m; rc=$?
  rl_run "$1" 30 kubectl -n agent-sandbox logs "$p" > "$STATE/t7.out"; cat "$STATE/t7.out"
  timeout 30 kubectl -n agent-sandbox delete pod "$p" --wait=false >/dev/null
  [ "$rc" = 0 ] || return 1
  case $2 in  # forward: blocked from +0; baseline and rollback: blocked at +5 (+0 may pass, ADR 4)
    forward) grep -q '+0s modem blocked' "$STATE/t7.out" && grep -q '+5s modem blocked' "$STATE/t7.out" && grep -q '+0s dns connected' "$STATE/t7.out" ;;
    *) grep -q '+5s modem blocked' "$STATE/t7.out" && grep -q 'dns connected' "$STATE/t7.out" ;;
  esac
}
t8() {  # webhook dry-runs, server side; nothing persists
  rl_run "$1" 30 kubectl -n default apply --dry-run=server --request-timeout=30s -f - <<'EOF' | tee /dev/stderr | grep -c 'created (server dry run)' | grep -qx 3
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: cutover-dry-run}
spec: {secretName: cutover-dry-run, dnsNames: [cutover-dry-run.kube.kalski.xyz], issuerRef: {kind: ClusterIssuer, name: letsencrypt}}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: cutover-dry-run}
spec:
  secretStoreRef: {kind: ClusterSecretStore, name: gcp-secret-manager}
  target: {name: cutover-dry-run}
  data: [{secretKey: x, remoteRef: {key: local-kubernetes}}]
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata: {name: cutover-dry-run}
spec:
  runStrategy: Halted
  template:
    spec:
      domain: {devices: {}, resources: {requests: {memory: 64Mi}}}
EOF
}
t9() {
  local unavailable
  unavailable=$(rl_run "$1" 30 kubectl get apiservices -o json --request-timeout=20s | jq -r '.items[]|select(any(.status.conditions[]?; .type=="Available" and .status!="True"))|.metadata.name') || return 1
  [ -z "$unavailable" ] || { echo "unavailable: $unavailable"; return 1; }
  rl_run "$1" 30 kubectl top nodes
}
t10() { rl_run "$1" 30 kubectl get vmi -A --no-headers > "$STATE/vmi-now.txt" 2>&1; cat "$STATE/vmi-now.txt"; diff <(awk '{print $1, $2}' "$STATE/vmi.txt" 2>/dev/null) <(awk '{print $1, $2}' "$STATE/vmi-now.txt"); }
t11() { local d c bad=0; for d in external-dns-mikrotik external-dns-stationary; do
  c=$(rl_run "$1" 30 kubectl -n external-dns logs "deploy/$d" --since=15m --request-timeout=30s | grep -ciE 'error|fail'); echo "$d: $c"; [ "$c" = 0 ] || bad=1; done; return "$bad"; }
t5_hubble() {  # Docsight's allowed /32: forwarded, never dropped
  local out; out=$(hubble_observe "$1" --namespace docsight --to-ip 192.168.100.1 --since 10m -o compact) || return 1
  echo "$out"; grep -q FORWARDED <<<"$out" && ! grep -q DROPPED <<<"$out"
}
t13_hubble() {  # drops in the last 10 minutes, for the operator to judge; fails only if hubble can't be read
  hubble_observe "$1" --verdict DROPPED --since 10m -o compact --last 100 && echo "REVIEW: only expected drops?"
}
user_checks() {
  echo "USER (not ops): T2 browser login (docsight → auth → Pocket ID → back) within 5 min; T3 docker login, push, pull and a Harbor scan;"
  echo "USER: T5 Docsight shows modem data newer than this check; T13 Prometheus targets page shows targets up."
}
checks() {  # checks COLUMN END: the OP checks of section 6
  local col=$1 end=$2
  check T1 t1 "$end"
  check T3-https t3_https "$end"
  check T4 t4 "$end"
  [ "$col" = forward ] && check T5-hubble t5_hubble "$end"
  check T6 t6 "$end"
  check T7 t7 "$end" "$col"
  check T8 t8 "$end"
  check T9 t9 "$end"
  check T10 t10 "$end"
  check T11 t11 "$end"
  [ "$col" = forward ] && check T13-hubble t13_hubble "$end"
  user_checks
}

# ---- steps -------------------------------------------------------------------------------------------------------
step_preflight() {  # 0.1-0.6, and warms the tools
  local bad=0 out
  echo "== 0.1 talosctl config"; rl_run "$STEP_END" 30 talosctl config info || bad=1
  echo "== 0.2 Talos on five nodes"; out=$(rl_run "$STEP_END" 60 talosctl -n "$NODE_IPS" version --short 2>&1); echo "$out"
  [ "$(grep -c 'Tag:' <<<"$out")" -ge 5 ] || { echo "FAIL: not five nodes answering"; bad=1; }
  echo "== kubeconfig"; if command -v ops-kubeconfig >/dev/null; then rl_run "$STEP_END" 120 ops-kubeconfig || bad=1; fi
  echo "== 0.3 context"; rl_run "$STEP_END" 30 kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo; rl_run "$STEP_END" 30 kubectl auth whoami || bad=1
  echo "== 0.4 cluster admin"; [ "$(rl_run "$STEP_END" 30 kubectl auth can-i '*' '*' -A)" = yes ] || { echo "FAIL: not cluster-admin"; bad=1; }
  echo "== 0.5 LB and Talos API"; rl_run "$STEP_END" 15 curl -sk --max-time 10 -o /dev/null -w '%{http_code}\n' "https://$LB/" || bad=1
  rl_run "$STEP_END" 10 nc -z -w 5 10.10.10.11 50000 || bad=1
  echo "== 0.6 Terraform"; rl_run "$STEP_END" 300 terraform -chdir="$TF" init -input=false -no-color >/dev/null || bad=1
  plan_check || bad=1
  echo "== tools"; rl_run "$STEP_END" 30 cni-pods 2>&1 | head -1; rl_run "$STEP_END" 30 hubble version || bad=1
  [ "$bad" = 0 ] || { hint "preflight failed: stop the preflight (0.B)"; return 1; }
  echo "preflight passed"
}
plan_check() {  # a plain plan has no changes; -var cni=cilium updates exactly the five nodes, each only CNI, proxy and the Cilium manifest
  local rc out a want
  echo "-- plain plan (default cni)"
  rl_run "$STEP_END" 600 terraform -chdir="$TF" plan -input=false -no-color -lock-timeout=60s -detailed-exitcode >/dev/null; rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: a plain plan is not 'No changes' (exit $rc)"; return 1; }
  echo "no changes"
  echo "-- plan -var cni=cilium"
  rl_run "$STEP_END" 600 terraform -chdir="$TF" plan -input=false -no-color -lock-timeout=60s -detailed-exitcode -var cni=cilium -out="$STATE/cilium.tfplan" >/dev/null; rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: plan -var cni=cilium exited $rc, want 2 (changes)"; return 1; }
  rl_run "$STEP_END" 120 terraform -chdir="$TF" show -json "$STATE/cilium.tfplan" > "$STATE/cilium.tfplan.json" || return 1
  out=$(jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | "\(.address) \(.change.actions | join(","))"' "$STATE/cilium.tfplan.json" | sort)
  want=$(for a in $NODES_ALL; do echo "$(tf_addr "$a") update"; done | sort)
  echo "$out"
  [ "$out" = "$want" ] || { echo "FAIL: the plan must update exactly the five nodes"; return 1; }
  for a in $NODES_ALL; do
    # Compare each node's machine configuration with the CNI, proxy and Cilium manifest removed: nothing else may differ.
    if ! diff <(jq -r --arg a "$(tf_addr "$a")" '.resource_changes[] | select(.address == $a) | .change.before.machine_configuration' "$STATE/cilium.tfplan.json" | yq 'select(.cluster) |= (del(.cluster.network.cni) | del(.cluster.proxy) | del(.cluster.inlineManifests[] | select(.name == "cilium")))') \
              <(jq -r --arg a "$(tf_addr "$a")" '.resource_changes[] | select(.address == $a) | .change.after.machine_configuration' "$STATE/cilium.tfplan.json" | yq 'select(.cluster) |= (del(.cluster.network.cni) | del(.cluster.proxy) | del(.cluster.inlineManifests[] | select(.name == "cilium")))') >/dev/null; then
      echo "FAIL: $a's change is more than CNI, proxy and the Cilium manifest"; return 1
    fi
  done
  echo "five updates, CNI, proxy and the Cilium manifest only"
}
step_plan_check() { plan_check || { hint "the plan isn't what the runbook expects: STOP"; return 1; }; }
step_suspend_flux() {  # 0.14
  rl_run "$STEP_END" 30 kubectl get vmi -A --no-headers > "$STATE/vmi.txt" 2>&1; echo "VMs:"; cat "$STATE/vmi.txt"
  echo "Jobs:"; rl_run "$STEP_END" 30 kubectl get jobs -A | tee "$STATE/jobs.txt"
  rl_run "$STEP_END" 120 flux suspend kustomization --all || return 1
  rl_run "$STEP_END" 60 flux get kustomizations -A --no-header | tee "$STATE/flux.txt"
  # Columns: NAMESPACE NAME REVISION SUSPENDED READY MESSAGE
  awk 'NF && $4 != "True" {bad=1} END {exit bad}' "$STATE/flux.txt" || { echo "FAIL: not every Kustomization is suspended"; return 1; }
  log "flux suspended"
}
step_baseline() { checks baseline "$STEP_END"; [ "$FAILED" = 0 ]; }
step_apply() {  # 1.1 (c1, sets T0) and 3.1 (the others), with -var cni=cilium
  local n=${1:-} rc
  node_ok "$n" apply
  if [ "$n" = c1 ]; then
    if [ ! -s "$STATE/t0" ]; then : > "$STATE/applied"; now > "$STATE/t0"; log "T0 $(cat "$STATE/t0")"; fi
  else
    need_t0
    grep -q '^applied c1 ' "$STATE/applied" || die "c1 isn't applied yet"
    case $n in w*) grep -q '^applied c3 ' "$STATE/applied" || die "control planes first: c3 isn't applied yet";; esac
  fi
  echo "T0=$(cat "$STATE/t0")  (post it to the VM thread)"
  tf_apply "$n" -var cni=cilium; rc=$?
  [ "$rc" = 0 ] && { echo "applied $n"; [ "$n" = c1 ] && hint "VM: api_watch and gate 1; then op.sh remove-cni0"; return 0; }
  [ "$rc" = 124 ] && echo "terraform apply timed out after 300 s"
  rollback_hint; return 1
}
step_remove_cni0() {  # 2.0: ends 4 min from now, no later than T0 + 14 (cleanup up to 70 s more)
  need_t0
  local end; end=$(( $(date +%s) + 240 )); [ "$end" -lt "$(at "$T0" 14)" ] || end=$(at "$T0" 14); end=$(cap "$end")
  remove_all cni0 "$end" || hint "log it and go on: those nodes keep cni0 until their reboot; recreate and the probes handle a collision"
  cnipods "$(cap "$(at "$T0" 18)")" 120 plan | grep 'cni0 still up' || echo "no cni0 left"
  return 0
}
step_recreate() {  # 2.1-2.2 under T0 + 18; [-include ns/pod,...]
  need_t0
  local end include="" plan rc; RUNBOOK_END=$(at "$T0" 18); end=$(cap "$RUNBOOK_END")
  [ $# = 0 ] || { [ "$1" = -include ] && [ -n "${2:-}" ] || usage "recreate [-include ns/pod,...]"; include=$2; }
  plan=$(cnipods "$end" 120 plan); rc=$?; echo "$plan"
  [ "$rc" = 124 ] && deadline_exit "recreation (T0 + 18): go to op.sh m1"
  [ "$rc" = 0 ] || return 1
  awk '$1 == "report" {print $2}' <<<"$plan" | grep -vxF -f <(tr ',' '\n' <<<"$include") | paste -sd, - > "$STATE/allow"
  echo "ALLOW=$(cat "$STATE/allow")  (left alone; log a disposition for each: Jobs and CronJob pods stay, VMs stop/start, standalone pods by hand)"
  cnipods "$end" 1800 recreate ${include:+-include "$include"}; rc=$?
  case $rc in
    0) echo "recreated"; hint "op.sh m1";;
    124) deadline_exit "recreation (T0 + 18): not a failure by itself, go straight to op.sh m1";;
    *) hint "an endpoint-ownership wait → op.sh endpoint-capture m2; otherwise read the owner it names, fix or accept it, and run op.sh recreate again"; return 1;;
  esac
}
step_m1() {  # 2.3: T1 and Harbor over HTTPS by T0 + 20; the user checks T2 and T3
  need_t0
  local end; RUNBOOK_END=$(at "$T0" 20); end=$(cap "$RUNBOOK_END")
  [ "$(rl_left "$end" 1)" -gt 0 ] || { rollback_hint; deadline_exit "M1 (T0 + 20)"; }
  check T1 t1 "$end"; check T3-https t3_https "$end"
  echo "USER: T2 login chain and T3 Harbor push/pull now; M1 passes only with both."
  [ "$FAILED" = 0 ] && { hint "M1 passes once the user confirms T2 and T3; if recreate didn't finish, op.sh recreate again (now under T0 + 45); then op.sh m2"; return 0; }
  rollback_hint; return 1
}
step_m2() {  # 2.4-2.5 under T0 + 45, or after the prune (4.3) under a fresh 15 minutes: op.sh m2 [prune]
  local end bad=0
  if [ "${1:-}" = prune ]; then RUNBOOK_END=$(budget s0 15); else need_t0; RUNBOOK_END=$(at "$T0" 45); fi
  end=$(cap "$RUNBOOK_END")
  [ "$(rl_left "$end" 1)" -gt 0 ] || deadline_exit "M2"
  echo "== verify"; cnipods "$end" 900 verify || bad=1
  echo "== endpoints"; cnipods "$end" 120 endpoints -allow "$(cat "$STATE/allow" 2>/dev/null)" || bad=1
  echo "== agent status"; agent_status "$end" || bad=1
  echo "== operator"; operator_ready "$end" || { echo "cilium-operator not 2/2"; bad=1; }
  echo "== node probes"; node_probes "$end" || bad=1
  [ "$bad" = 0 ] && { echo "M2 passed"; return 0; }
  [ "$(date +%s)" -ge "$end" ] && deadline_exit "M2"
  hint "a failure naming an endpoint, or cannot take ownership → op.sh endpoint-capture $([ "${1:-}" = prune ] && echo fresh || echo m2); stale endpoints of just-deleted pods: op.sh m2 again after 60 s; otherwise choose rollback (by log: $(route)) or STOP, and log it"
  return 1
}
eb_end() {  # the endpoint-ownership budget: M2's deadline, or a fresh 15 minutes kept in ~/cutover/er0
  case $(cat "$STATE/eb" 2>/dev/null) in
    m2) need_t0; at "$T0" 45 ;;
    fresh) budget er0 15 ;;
    *) die "no endpoint-ownership budget: start with op.sh endpoint-capture m2|fresh" ;;
  esac
}
step_endpoint_capture() {  # endpoint ownership 1-2: capture, then identify each endpoint that can't sync
  case ${1:-} in m2) echo m2 > "$STATE/eb";; fresh) echo fresh > "$STATE/eb"; rm -f "$STATE/er0";; *) usage "endpoint-capture m2|fresh";; esac
  local end diag a ids id pod; RUNBOOK_END=$(eb_end); end=$(cap "$RUNBOOK_END"); diag="$STATE/diag-$(date +%s)"; mkdir -p "$diag"
  rl_run "$end" 60 kubectl get ciliumendpoints.cilium.io -A -o json > "$diag/ceps.json"
  rl_run "$end" 60 kubectl get pods -A -o json > "$diag/pods.json"
  rl_run "$end" 60 kubectl get events -A -o json > "$diag/events.json"
  for a in $(rl_run "$end" 30 kubectl -n kube-system get pods -l k8s-app=cilium -o name); do a=${a#pod/}
    rl_run "$end" 30 kubectl -n kube-system exec "$a" -c cilium-agent -- cilium-dbg endpoint list -o json > "$diag/$a-endpoints.json"
    rl_run "$end" 30 kubectl -n kube-system exec "$a" -c cilium-agent -- cilium-dbg status --verbose > "$diag/$a-status.log"
    rl_run "$end" 30 kubectl -n kube-system logs "$a" -c cilium-agent --tail=1000 > "$diag/$a-agent.log"
    ids=$(grep -oE 'sync-to-k8s-ciliumendpoint \([0-9]+\)' "$diag/$a-status.log" | grep -oE '[0-9]+' | sort -u)
    for id in $ids; do
      pod=$(jq -r --argjson id "$id" '.[] | select(.id==$id) | .status.controllers[].name | select(startswith("resolve-labels-")) | ltrimstr("resolve-labels-")' "$diag/$a-endpoints.json")
      identify "$diag" "$a" "$id" "$pod"
    done
  done
  cnipods "$end" 120 endpoints -allow "$(cat "$STATE/allow" 2>/dev/null)" | tee "$diag/endpoints.txt"
  echo "captured in $diag"
  hint "stale CEP → op.sh clear-cep <ns/name>; lost create → op.sh recreate-include <ns/pod>; then op.sh endpoint-converge"
}
identify() {  # identify DIAG AGENT ID NS/POD: stale (StatefulSet name reuse) or a lost create
  local ns=${4%%/*} name=${4#*/} puid cuid owner
  [ -n "$4" ] || { echo "endpoint $3 on $2: no pod named by its controllers"; return; }
  puid=$(jq -r --arg ns "$ns" --arg n "$name" '.items[] | select(.metadata.namespace==$ns and .metadata.name==$n) | .metadata.uid' "$1/pods.json")
  read -r cuid owner < <(jq -r --arg ns "$ns" --arg n "$name" '.items[] | select(.metadata.namespace==$ns and .metadata.name==$n) | "\(.metadata.uid) \(.metadata.ownerReferences[0].uid)"' "$1/ceps.json")
  if [ -z "${cuid:-}" ]; then echo "endpoint $3 on $2: $4 has no CEP"
  elif [ "$owner" = "$puid" ]; then echo "endpoint $3 on $2: $4: LOST CREATE (CEP $cuid owned by the live pod) → op.sh recreate-include $4"
  else echo "endpoint $3 on $2: $4: STALE CEP $cuid (owner $owner, live pod ${puid:-none}) → op.sh clear-cep $4"; fi
}
step_clear_cep() { [ $# = 1 ] && [[ $1 == */* ]] || usage "clear-cep <ns/name>"; local end; RUNBOOK_END=$(eb_end); end=$(cap "$RUNBOOK_END")
  cnipods "$end" 120 clear-stale-ceps -cep "$1"; local rc=$?; [ "$rc" = 124 ] && deadline_exit "endpoint ownership"; return "$rc"; }
step_recreate_include() { [ $# = 1 ] && [[ $1 == */* ]] || usage "recreate-include <ns/pod>"; local end; RUNBOOK_END=$(eb_end); end=$(cap "$RUNBOOK_END")
  cnipods "$end" 660 recreate -include "$1" -timeout 10m; local rc=$?; [ "$rc" = 124 ] && deadline_exit "endpoint ownership"; return "$rc"; }
step_endpoint_converge() {  # endpoint ownership 4: within 2 minutes (and the budget), every agent OK and endpoints pass
  local end until_; RUNBOOK_END=$(eb_end); end=$(cap "$RUNBOOK_END"); until_=$(( $(date +%s) + 120 )); [ "$until_" -lt "$end" ] || until_=$end
  while [ "$(date +%s)" -lt "$until_" ]; do
    agent_status "$until_" && cnipods "$until_" 60 endpoints -allow "$(cat "$STATE/allow" 2>/dev/null)" && { echo "recovered: resume where you came from"; return 0; }
    sleep "$(rl_left "$until_" 15)"
  done
  hint "terminal: from M2 roll back by log ($(route)); from 4.3 choose rollback or STOP and log it; from 5.3 STOP (no rollback without the user)"
  return 1
}
step_prune_dry_run() {  # 4.2: exactly Flannel's and kube-proxy's 8 objects
  local out want got
  out=$(upgrade_k8s "$STEP_END" --dry-run); echo "$out"
  want=$(tr ' ' '\n' <<<'ClusterRole/flannel ClusterRoleBinding/flannel ClusterRoleBinding/kube-proxy ConfigMap/kube-system/kube-flannel-cfg DaemonSet/kube-system/kube-flannel DaemonSet/kube-system/kube-proxy ServiceAccount/kube-system/flannel ServiceAccount/kube-system/kube-proxy' | sort -u | tr '\n' ' ' | sed 's/ $//')
  got=$(changes Pruned <<<"$out")
  [ "$got" = "$want" ] || { echo "FAIL: pruned: $got"; hint "anything but these 8 stops the window: STOP"; return 1; }
  echo "dry run prunes exactly the 8"
}
step_prune() {  # 4.3: upgrade-k8s (at most 3 tries), then flannel.1 within 5 min; then op.sh m2 prune
  local try out rc=1 end
  for try in 1 2 3; do
    out=$(upgrade_k8s "$STEP_END"); rc=$?; echo "$out"; [ "$rc" = 0 ] && break
    [ "$rc" = 124 ] && deadline_exit "the prune"
    echo "upgrade-k8s try $try failed; re-checking etcd"; rl_run "$STEP_END" 30 talosctl -n "$CPS" etcd status || break
  done
  [ "$rc" = 0 ] || { hint "the prune failed 3 times: choose rollback (by log: $(route)) or STOP, and log it"; return 1; }
  end=$(cap $(( $(date +%s) + 300 ))); remove_all flannel1 "$end" || echo "flannel.1 left on some nodes: logged only; their reboot removes it"
  hint "VM: gate 1 again (10 min); then op.sh m2 prune"
}
step_reboot() {  # 5.3-5.4: reboot_node, then verify and agent status, the CNI config and links
  node_ok "${1:-}" reboot
  local n=$1 ip end bad=0; ip=$(ip_of "$n")
  reboot_node "$n" || { hint "no further reboots: a CP whose Talos API doesn't answer → E1 (user); otherwise STOP"; return 1; }
  end=$(cap $(( $(date +%s) + 900 )))
  echo "== verify"; cnipods "$end" 900 verify || bad=1
  echo "== agent status"; agent_status "$end" || bad=1
  echo "== CNI config"; repair "$n" inspect "$end" | tee "$STATE/repair-$n.txt"; grep -q '10-flannel.conflist' "$STATE/repair-$n.txt" && { echo "FAIL: Flannel's CNI config is still there"; bad=1; }
  echo "== links"; rl_run "$end" 30 talosctl -n "$ip" get links | grep -E 'cni0|flannel' && { echo "FAIL: Flannel links left"; bad=1; }
  [ "$bad" = 0 ] && { echo "$n rebooted and clean"; return 0; }
  [ "$(date +%s)" -ge "$end" ] && hint "the 29-minute cap may have cut the checks: run op.sh reboot-check $n"
  hint "no further reboots: an endpoint failure → op.sh endpoint-capture fresh; otherwise STOP (no rollback without the user)"
  return 1
}
step_reboot_check() {  # 5.3-5.4 without the reboot
  node_ok "${1:-}" reboot-check
  local n=$1 end bad=0; end=$(cap $(( $(date +%s) + 900 )))
  cnipods "$end" 900 verify || bad=1; agent_status "$end" || bad=1
  repair "$n" inspect "$end" | tee "$STATE/repair-$n.txt"; grep -q '10-flannel.conflist' "$STATE/repair-$n.txt" && bad=1
  rl_run "$end" 30 talosctl -n "$(ip_of "$n")" get links | grep -E 'cni0|flannel' && bad=1
  return "$bad"
}
step_forfeit() { node_ok "${1:-}" forfeit; case $1 in c*) ;; *) usage "forfeit <c1|c2|c3>";; esac; rl_run "$STEP_END" 60 talosctl -n "$(ip_of "$1")" etcd forfeit-leadership; }
step_accept() {  # section 6: forward (M3) or rollback (under the rollback budget RA0 + 60)
  case ${1:-} in
    forward) checks forward "$STEP_END" ;;
    rollback) RUNBOOK_END=$(budget ra0 60); local end; end=$(cap "$RUNBOOK_END"); [ "$(rl_left "$end" 1)" -gt 0 ] || deadline_exit "rollback acceptance"
      checks rollback "$end" ;;
    *) usage "accept forward|rollback" ;;
  esac
  [ "$FAILED" = 0 ] || { hint "report the failed checks; rollback acceptance failing: STOP, the cluster is on Flannel"; return 1; }
  hint "then op.sh resume-flux"
}
step_rollback_verify() {  # Rollback A.7 first part: cni-pods verify -cni flannel and the probes, under RA0 + 60
  RUNBOOK_END=$(budget ra0 60); local end bad=0; end=$(cap "$RUNBOOK_END")
  [ "$(rl_left "$end" 1)" -gt 0 ] || deadline_exit "rollback acceptance"
  cnipods "$end" 900 verify -cni flannel -cni0 none || bad=1
  node_probes "$end" || bad=1
  [ "$bad" = 0 ] && { hint "op.sh accept rollback"; return 0; }
  hint "rollback acceptance failed: STOP, the cluster is on Flannel"; return 1
}
step_resume_flux() {  # T12, last
  rl_run "$STEP_END" 120 flux resume kustomization --all || return 1
  rl_run "$STEP_END" 300 flux reconcile source git flux-system || return 1
  rl_run "$STEP_END" 60 flux get kustomizations -A
  log "flux resumed"
}
step_rollback_apply() {  # Rollback A: c1 only; B: every node, workers retried once; -var cni=flannel whatever the default is
  local r rc n ip
  case ${1:-} in a|b) ;; *) usage "rollback-apply a|b";; esac
  r=$(route); echo "$r"
  [ "$1" = a ] && [ "$r" != "Rollback A" ] && die "the applied-node log calls for $r, not A"
  log "rollback $1 start"
  for n in $([ "$1" = a ] && echo c1 || echo "$NODES_ALL"); do
    tf_apply "$n" -var cni=flannel; rc=$?
    if [ "$rc" != 0 ]; then
      case $n in
        c*) hint "$n's apply failed: E1 for $n (user: UART)"; return 1 ;;
        w*) ip=$(ip_of "$n"); rl_run "$STEP_END" 30 talosctl -n "$ip" version; sleep 60; tf_apply "$n" -var cni=flannel || { hint "STOP: $n still fails; the control planes are on Flannel"; return 1; } ;;
      esac
    fi
  done
  hint "VM: api_watch 10 and etcd_ok, cni_gate flannel; then op.sh rollback-prune"
}
step_rollback_prune() {  # Rollback A.4-A.5: record the agents, prune Cilium's exactly 33 objects, remove Cilium's taint
  local out got want try rc=1 n
  rl_run "$STEP_END" 60 kubectl -n kube-system get pods -l k8s-app=cilium -o json > "$STATE/agents-before-prune.json"
  out=$(upgrade_k8s "$STEP_END" --dry-run); echo "$out"
  got=$(changes Pruned <<<"$out")
  want=$(tr ' ' '\n' <<<'ClusterRoleBinding/cilium ClusterRoleBinding/cilium-operator ClusterRole/cilium ClusterRole/cilium-operator ConfigMap/kube-system/cilium-config ConfigMap/kube-system/cilium-envoy-config ConfigMap/kube-system/hubble-relay-config CronJob/kube-system/hubble-generate-certs Job/kube-system/hubble-generate-certs-ef4be98870 DaemonSet/kube-system/cilium DaemonSet/kube-system/cilium-envoy Deployment/kube-system/cilium-operator Deployment/kube-system/hubble-relay Namespace/cilium-secrets RoleBinding/cilium-secrets/cilium-operator-tlsinterception-secrets RoleBinding/cilium-secrets/cilium-tlsinterception-secrets RoleBinding/kube-system/cilium-config-agent RoleBinding/kube-system/cilium-operator-ztunnel RoleBinding/kube-system/hubble-generate-certs Role/cilium-secrets/cilium-operator-tlsinterception-secrets Role/cilium-secrets/cilium-tlsinterception-secrets Role/kube-system/cilium-config-agent Role/kube-system/cilium-operator-ztunnel Role/kube-system/hubble-generate-certs ServiceAccount/kube-system/cilium ServiceAccount/kube-system/cilium-envoy ServiceAccount/kube-system/cilium-operator ServiceAccount/kube-system/hubble-generate-certs ServiceAccount/kube-system/hubble-relay Service/kube-system/cilium-envoy Service/kube-system/hubble-metrics Service/kube-system/hubble-peer Service/kube-system/hubble-relay' | sort -u | tr '\n' ' ' | sed 's/ $//')
  [ "$got" = "$want" ] || { echo "FAIL: pruned: $got"; hint "anything but Cilium's 33 objects stops the window: STOP"; return 1; }
  for try in 1 2 3; do out=$(upgrade_k8s "$STEP_END"); rc=$?; echo "$out"; [ "$rc" = 0 ] && break; [ "$rc" = 124 ] && deadline_exit "the rollback prune"; done
  [ "$rc" = 0 ] || { hint "STOP: the rollback prune failed 3 times"; return 1; }
  [ -z "$(rl_run "$STEP_END" 30 kubectl get pods -A -l app.kubernetes.io/part-of=cilium -o name)" ] || { echo "FAIL: Cilium pods remain"; return 1; }
  for n in $(rl_run "$STEP_END" 30 kubectl get nodes -o json | jq -r '.items[]|select(any(.spec.taints[]?; .key=="node.cilium.io/agent-not-ready"))|.metadata.name'); do
    rl_run "$STEP_END" 30 kubectl taint nodes "$n" node.cilium.io/agent-not-ready- || return 1
  done
  hint "op.sh rollback-reboot <node> for every node, one at a time (VM: etcd_ok around each CP)"
}
step_rollback_reboot() {  # Rollback A.6: reboot_node, then kube-flannel running on the node
  node_ok "${1:-}" rollback-reboot
  case ${2:-} in ""|uncordoned) ;; *) usage "rollback-reboot <node> [uncordoned]";; esac
  reboot_node "$1" "${2:-}" || { hint "the node didn't come back: a CP whose Talos API doesn't answer → E1, a CP with etcd unhealthy → E4, otherwise STOP"; return 1; }
  rl_run "$STEP_END" 600 kubectl -n kube-system rollout status ds/kube-flannel --timeout=10m || { hint "kube-flannel isn't running: STOP"; return 1; }
}
step_repair() {  # Rollback A.6: inspect, or repair, one node's CNI config
  node_ok "${1:-}" repair
  case ${2:-inspect} in inspect|repair) ;; *) usage "repair <node> [inspect|repair]";; esac
  repair "$1" "${2:-inspect}" "$STEP_END"
}
step_status() { echo "state: $STATE"; echo "T0: $(cat "$STATE/t0" 2>/dev/null || echo unset)"; echo "applied-node log:"; cat "$STATE/applied" 2>/dev/null; route; echo "ALLOW: $(cat "$STATE/allow" 2>/dev/null)"; tail -n 20 "$STATE/log" 2>/dev/null; }

STEPS="preflight plan-check suspend-flux baseline apply remove-cni0 recreate m1 m2 endpoint-capture clear-cep recreate-include endpoint-converge prune-dry-run prune reboot reboot-check forfeit accept rollback-verify resume-flux rollback-apply rollback-prune rollback-reboot repair route status"
[ $# -ge 1 ] || usage "<step> [args]; steps: $STEPS"
step=$1; shift
case " $STEPS " in *" $step "*) ;; *) usage "<step> [args]; unknown step '$step'; steps: $STEPS";; esac
[ "$step" = route ] && { route; exit 0; }
log "start $step $*"
"step_${step//-/_}" "$@"; rc=$?
log "end $step rc=$rc"
exit $rc
