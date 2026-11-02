#!/usr/bin/env bash
# shellcheck disable=SC2329  # steps run by name: "step_${step//-/_}"
# op.sh STEP [ARGS...]: the operator (OP) steps of the Flannel → Cilium cutover runbook (#228), one approved
# command per runbook step: `bash local-talos/cutover/op.sh <step>` from infra/. `op.sh` alone lists the steps.
#
# - Window SHA: `op.sh init <sha>` runs once before T0. It requires a clean checkout at <sha>, a commit on origin/main
#   (it fetches), archives any earlier ~/cutover, saves the `.#cutover` dev environment as a GC-rooted profile and
#   records <sha>. Every later step requires a clean checkout at that SHA, without fetching, and runs with the saved
#   environment's pinned tools (terraform, talosctl, kubectl, flux, cni-pods, hubble, ...): no network or evaluation
#   is needed to run a step, and a later merge to main or a GitHub outage doesn't block one.
# - State: ~/cutover (CUTOVER_STATE overrides): the window SHA, T0, the applied-node log, the window log, ALLOW,
#   budgets and diagnostics, shared by separate invocations. `apply c1` sets T0; steps that need it refuse without it.
#   One step runs at a time (a lock); an overlapping invocation is refused.
# - Deadlines: every command runs under the least of its own limit, its runbook deadline and the step's cap: 29 min
#   from the invocation, as ops ends a command after 30. No command starts once a deadline has passed.
# - Exit codes: 0 done; 1 failed (follow the printed ROUTE); 2 usage; 3 refused; 124 a runbook deadline passed (take
#   the action the runbook names for it); 125 the step cap ended the step (run the same step again, unless the
#   printed hint says otherwise).
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
# The step's cap counts from the first entry, before the re-exec into the saved environment.
CUTOVER_START=${CUTOVER_START:-$(date +%s)}
export CUTOVER_START
STEP_END=$(( CUTOVER_START + STEP_CAP ))

die() { echo "REFUSED: $*" >&2; exit 3; }
usage() { echo "usage: op.sh $*" >&2; exit 2; }
now() { date -u +%Y-%m-%dT%H:%M:%S; }
log() { echo "$(now) $*" >> "$STATE/log"; }

# ---- lock, window SHA, the saved environment --------------------------------------------------------------------
lock() {
  mkdir -p "$STATE" && chmod 700 "$STATE"
  exec 9>>"$STATE/lock"
  flock -n 9 || die "another op.sh step is running; wait for it"
  export CUTOVER_LOCKED=1
}
clean() { [ -z "$(git -C "$INFRA" status --porcelain)" ] || die "the checkout has local changes; only the reviewed window SHA runs"; }
step_init() {  # init <sha> [--archive]: pin the window to a reviewed commit on main, before T0
  local sha=${1:-} archive=${2:-} dir
  if ! [[ $sha =~ ^[0-9a-f]{40}$ ]] || { [ -n "$archive" ] && [ "$archive" != --archive ]; }; then usage "init <full sha of a commit on main> [--archive]"; fi
  clean
  timeout 60 git -C "$INFRA" fetch -q "$REMOTE" main || die "git fetch $REMOTE main failed"
  [ "$(git -C "$INFRA" rev-parse HEAD)" = "$sha" ] || die "HEAD is $(git -C "$INFRA" rev-parse HEAD), not $sha; check out the approved SHA first"
  git -C "$INFRA" merge-base --is-ancestor "$sha" "$REMOTE/main" || die "$sha is not on $REMOTE/main"
  if [ -n "$(find "$STATE" -mindepth 1 -maxdepth 1 ! -name lock -print -quit)" ]; then
    if { [ -e "$STATE/t0" ] || ls "$STATE"/ra0 "$STATE"/er0 "$STATE"/s0 >/dev/null 2>&1; } && [ "$archive" != --archive ]; then
      die "$STATE holds an earlier window's T0 or budgets; run op.sh init $sha --archive to keep them aside"
    fi
    dir="$STATE.archive/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$dir"
    find "$STATE" -mindepth 1 -maxdepth 1 ! -name lock -exec mv -t "$dir" {} +
    echo "archived the earlier state in $dir"
  fi
  echo "saving the .#cutover environment (a GC root in $STATE/dev-profile)"
  timeout 1500 nix print-dev-env --profile "$STATE/dev-profile" "$INFRA#cutover" > "$STATE/dev-env.sh.new" || die "nix print-dev-env failed"
  mv "$STATE/dev-env.sh.new" "$STATE/dev-env.sh"
  echo "$sha" > "$STATE/window-sha"
  log "init $sha"
  echo "window SHA $sha; next: op.sh preflight"
}
if [ "${1:-}" = init ]; then
  [ "${CUTOVER_LOCKED:-}" = 1 ] || lock
  shift; step_init "$@"; exit $?
fi
[ "${CUTOVER_LOCKED:-}" = 1 ] || lock
[ -s "$STATE/window-sha" ] || die "no window SHA: run op.sh init <sha> first"
clean
[ "$(git -C "$INFRA" rev-parse HEAD)" = "$(cat "$STATE/window-sha")" ] || die "HEAD is not the window SHA $(cat "$STATE/window-sha"); check it out, or init again (post-M3 only)"
if [ "${CUTOVER_SHELL:-}" != 1 ]; then
  [ -s "$STATE/dev-env.sh" ] || die "no saved environment: run op.sh init again"
  # shellcheck disable=SC2016  # expanded by the inner bash
  exec bash --noprofile --norc -c '. "$1" && shift && exec bash "$@"' op "$STATE/dev-env.sh" "${BASH_SOURCE[0]}" "$@"
fi

# ---- deadlines ---------------------------------------------------------------------------------------------------
# Each bounded command records which limit stopped it: the step cap (RUN/capped) or a runbook deadline (RUN/deadline).
# The dispatcher turns those into exit 125 and 124 whatever the step returned, so a capped step always says "rerun".
RUN=$(mktemp -d)
# The saved environment makes a temporary NIX_BUILD_TOP each time it is sourced; remove it with the run's own.
cleanup() { rm -rf "$RUN"; case ${NIX_BUILD_TOP:-} in */nix-shell.*) rm -rf "$NIX_BUILD_TOP" ;; esac; }
trap cleanup EXIT
capped() { [ -e "$RUN/capped" ]; }
hint() { capped || echo "ROUTE: $*" >&2; }
route() {  # which rollback, from the applied-node log alone: A only if c1 alone was attempted
  local others
  [ -s "$STATE/applied" ] || { echo "Rollback B (no applied-node log)"; return; }
  others=$(awk '$2 != "c1" {print $2}' "$STATE/applied" | sort -u | tr '\n' ' ')
  if [ -n "$others" ]; then echo "Rollback B (attempted beyond c1: $others)"; else echo "Rollback A"; fi
}
rollback_hint() { hint "roll back by log: $(route) → op.sh rollback-apply $(route | awk '{print tolower($2)}')"; }
need_t0() { [ -s "$STATE/t0" ] || die "T0 is not set; the window starts with op.sh apply c1"; T0=$(cat "$STATE/t0"); }
at() { echo $(( $(date -d "${1}Z" +%s) + $2 * 60 )); }     # at BASE MINUTES: epoch of BASE + MINUTES
rl_left() {  # rl_left END CAP: seconds left before END (0 = none) and the step cap, at most CAP
  local n r; n=$(date +%s); r=$(( STEP_END - n ))
  [ "$1" -gt 0 ] && [ $(( $1 - n )) -lt "$r" ] && r=$(( $1 - n ))
  [ "$r" -gt 0 ] || r=0; [ "$r" -lt "$2" ] || r=$2; echo "$r"
}
rl_run() {  # rl_run END CAP CMD...: CMD under the least of CAP, END (epoch; 0 = no runbook deadline) and the step cap
  local end=$1 lim=$2 n dl cp t which rc; shift 2
  n=$(date +%s); cp=$(( STEP_END - n )); dl=$(( end > 0 ? end - n : 1 << 30 ))
  t=$lim which=command
  [ "$cp" -lt "$t" ] && { t=$cp; which=cap; }
  [ "$dl" -le "$t" ] && { t=$dl; which=deadline; }
  if [ "$t" -le 0 ]; then
    if [ "$which" = cap ]; then touch "$RUN/capped"; echo "STEP CAP: not running: $*" >&2
    else echo "$*" >> "$RUN/deadline"; echo "DEADLINE PASSED: not running: $*" >&2; fi
    return 124
  fi
  timeout "$t" "$@"; rc=$?
  if [ "$rc" = 124 ]; then
    case $which in
      cap) touch "$RUN/capped"; echo "STEP CAP: interrupted: $*" >&2 ;;
      deadline) echo "$*" >> "$RUN/deadline"; echo "DEADLINE REACHED: interrupted: $*" >&2 ;;
    esac
  fi
  return "$rc"
}
budget() {  # budget NAME MINUTES: a recovery budget set on first use and shared by later steps; prints its end
  [ -s "$STATE/$1" ] || now > "$STATE/$1"
  at "$(cat "$STATE/$1")" "$2"
}
DEADLINE_HINT="the runbook deadline passed: take the action the runbook names for it"
CAP_HINT="run the same step again"

# ---- nodes, Terraform --------------------------------------------------------------------------------------------
ip_of() { case $1 in c1) echo 10.10.10.11;; c2) echo 10.10.10.12;; c3) echo 10.10.10.13;; w1) echo 10.10.10.21;; w2) echo 10.10.10.22;; *) return 1;; esac; }
node_ok() { ip_of "$1" >/dev/null || usage "${2:-STEP} <c1|c2|c3|w1|w2>"; }
tf_addr() { case $1 in c*) echo "module.cluster.talos_machine.controlplane[\"$1.k8s.kalski.xyz\"]";; w*) echo "module.cluster.talos_machine.worker[\"$1.k8s.kalski.xyz\"]";; esac; }
tf_plan() {  # tf_plan NODE ARGS...: a targeted plan in ~/cutover/NODE.tfplan that must update exactly NODE's machine.
            # Exit 0 with a plan to apply, 10 if the node already has this config, 1 for anything else.
  local n=$1 rc out addr; shift; addr=$(tf_addr "$n")
  rl_run 0 300 terraform -chdir="$TF" plan -input=false -no-color -lock-timeout=60s -detailed-exitcode "$@" -target="$addr" -out="$STATE/$n.tfplan" >/dev/null; rc=$?
  [ "$rc" = 0 ] && { echo "$n: no changes (already applied)"; return 10; }
  [ "$rc" = 2 ] || { echo "FAIL: plan for $n exited $rc"; return 1; }
  out=$(rl_run 0 120 terraform -chdir="$TF" show -json "$STATE/$n.tfplan" | jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | "\(.address) \(.change.actions | join(","))"') || { echo "FAIL: reading $n's plan"; return 1; }
  echo "$out"
  [ "$out" = "$addr update" ] || { echo "FAIL: the plan for $n must update exactly $addr"; return 1; }
}
tf_apply() {  # tf_apply NODE: apply ~/cutover/NODE.tfplan under 300 s, logged before (attempt) and after (applied)
  local n=$1 rc
  echo "attempt $n $(now)" >> "$STATE/applied"; log "attempt $n"
  rl_run 0 300 terraform -chdir="$TF" apply -input=false -no-color -lock-timeout=60s "$STATE/$n.tfplan"; rc=$?
  if [ "$rc" = 0 ]; then echo "applied $n $(now)" >> "$STATE/applied"; log "applied $n"; fi
  return "$rc"
}
tf_change() {  # tf_change NODE ARGS...: plan, check, apply; 0 also when the node already had this config
  local rc; tf_plan "$@"; rc=$?
  [ "$rc" = 10 ] && { echo "applied $1 $(now) (no change)" >> "$STATE/applied"; return 0; }
  [ "$rc" = 0 ] || return 1
  tf_apply "$1"
}

# ---- cluster helpers (from the runbook) --------------------------------------------------------------------------
agent_ready() { [ "$(rl_run "$1" 30 kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="$2" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" = True ]; }
agent_status() {  # agent_status END: five agents, each printing OK
  local p pods n=0 ok=0 out
  pods=$(rl_run "$1" 30 kubectl -n kube-system get pods -l k8s-app=cilium -o name) || { echo "FAIL: reading the agents"; return 1; }
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
  traefik=$(rl_run "$1" 30 kubectl -n traefik get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}') && [ -n "$traefik" ] || { echo "FAIL: no Traefik pod address"; return 1; }
  for n in $NODES_ALL; do
    dns=$(rl_run "$1" 30 kubectl -n kube-system get pods -l k8s-app=kube-dns -o json | jq -er --arg n "$n" '[.items[]|select(.spec.nodeName!=$n and .status.phase=="Running")][0].status.podIP') || { echo "FAIL: no CoreDNS pod off $n"; return 1; }
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
    [ "$(rl_left "$2" 1)" -gt 0 ] || { echo "removal budget spent; not started on $n"; bad=1; break; }
    remove_link "$n" "$1" "$2" || bad=1
  done
  return "$bad"
}

# talos_reboot IP: read the boot ID, reboot through Talos and wait for a different boot ID, all within one 15-minute
# deadline from before the reboot (and the step cap). Prints the new boot ID; exit 1 if it never changed.
talos_reboot() {
  local ip=$1 boot0 boot="" deadline
  boot0=$(rl_run 0 30 talosctl -n "$ip" read /proc/sys/kernel/random/boot_id) && [ -n "$boot0" ] ||
    { echo "STOP: cannot read $ip's boot ID" >&2; return 1; }
  deadline=$(( $(date +%s) + 900 )); echo "$deadline" > "$RUN/reboot-deadline"
  rl_run "$deadline" 600 talosctl -n "$ip" reboot --wait --timeout 9m >&2 || echo "WARN: talosctl reboot $ip exited $?; checking the boot ID" >&2
  while :; do
    [ "$(rl_left "$deadline" 15)" -gt 0 ] || { echo "STOP: $ip's boot ID is unchanged 15 min after the reboot started; it didn't reboot" >&2; return 1; }
    boot=$(rl_run "$deadline" 15 talosctl -n "$ip" read /proc/sys/kernel/random/boot_id 2>/dev/null)
    [ "$(date +%s)" -lt "$deadline" ] || { echo "STOP: $ip's boot ID is unchanged 15 min after the reboot started; it didn't reboot" >&2; return 1; }
    [ -n "$boot" ] && [ "$boot" != "$boot0" ] && { echo "$boot"; return 0; }
    sleep "$(rl_left "$deadline" 10)"
  done
}
# reboot_node NODE [uncordoned]: cordon, talos_reboot, require the kubelet to report the new boot ID with Ready within
# that same deadline, uncordon, then delete the operator's Failed pods. A failed cordon stops, except with
# `uncordoned` (rollback only, logged). Pods placed on the node while it shut down (not DaemonSets') are PILE-UP.
reboot_node() {
  local n=$1 mode=${2:-} ip pods boot seen deadline rejected p kind
  ip=$(ip_of "$n") || return 1
  if ! rl_run 0 60 kubectl cordon "$n"; then
    [ "$mode" = uncordoned ] || { echo "STOP: cordon $n failed" >&2; return 1; }
    log "UNCORDONED REBOOT: $n (rollback exception)"; echo "UNCORDONED REBOOT: $n (rollback exception, logged)" >&2
  fi
  pods=$(rl_run 0 60 kubectl get pods -A --field-selector spec.nodeName="$n" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}') ||
    { echo "STOP: cannot read the pods on $n" >&2; return 1; }
  CAP_HINT="the reboot of $n may have started: check its boot ID, then op.sh reboot-check $n (forward) or finish by hand (rollback); don't reboot it again blindly"
  boot=$(talos_reboot "$ip") || return 1
  deadline=$(cat "$RUN/reboot-deadline")
  while :; do
    [ "$(rl_left "$deadline" 15)" -gt 0 ] || { echo "STOP: $n not Ready on its new boot within 15 min of the reboot" >&2; return 1; }
    seen=$(rl_run "$deadline" 15 kubectl get node "$n" -o jsonpath='{.status.nodeInfo.bootID} {.status.conditions[?(@.type=="Ready")].status}')
    [ "$(date +%s)" -lt "$deadline" ] || { echo "STOP: $n not Ready on its new boot within 15 min of the reboot" >&2; return 1; }
    [ "$seen" = "$boot True" ] && break
    sleep "$(rl_left "$deadline" 10)"
  done
  rl_run 0 60 kubectl uncordon "$n" || { echo "STOP: $n still cordoned" >&2; return 1; }
  rejected=$(rl_run 0 60 kubectl get pods -A --field-selector spec.nodeName="$n",status.phase=Failed -o jsonpath='{range .items[?(@.status.reason=="NodeShutdown")]}{.metadata.namespace}/{.metadata.name} {.metadata.ownerReferences[0].kind}{"\n"}{end}')
  while read -r p kind; do
    [ -n "$p" ] && [ "$kind" != DaemonSet ] && ! grep -qxF "$p" <<<"$pods" && echo "PILE-UP: $p placed on $n while it shut down" >&2
  done <<<"$rejected"
  rl_run 0 90 kubectl -n kube-system delete pods -l io.cilium/app=operator --field-selector status.phase=Failed --timeout=60s
}
repair() {  # repair NODE inspect|repair END: local-talos/cni-repair.yaml on NODE; prints its log
  local n=$1 pod=cni-repair-$1 rc
  rl_run "$3" 40 kubectl -n kube-system delete pod "$pod" --ignore-not-found --wait --timeout=30s >/dev/null || return 1
  sed -e "s/NODE_NAME/$n/" -e "s/ACTION_VALUE/$2/" "$TF/cni-repair.yaml" | rl_run "$3" 30 kubectl create -f - >/dev/null || return 1
  rl_run "$3" 180 kubectl -n kube-system wait "pod/$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m &&
    rl_run "$3" 30 kubectl -n kube-system logs "$pod"; rc=$?
  rl_run 0 60 kubectl -n kube-system delete pod "$pod" --wait >/dev/null
  return "$rc"
}
node_clean() {  # node_clean NODE END: 5.4 on NODE; every read must succeed and look like its output before its content counts
  local n=$1 out bad=0
  out=$(repair "$n" inspect "$2") || { echo "FAIL: $n's CNI config could not be inspected"; return 1; }
  echo "$out"
  if ! grep -q '^before:' <<<"$out" || ! grep -q '^after:' <<<"$out"; then echo "FAIL: $n's inspection printed no before:/after: lines"; return 1; fi
  grep -q '10-flannel.conflist' <<<"$out" && { echo "FAIL: $n still has Flannel's CNI config"; bad=1; }
  out=$(rl_run "$2" 30 talosctl -n "$(ip_of "$n")" get links) || { echo "FAIL: $n's links could not be read"; return 1; }
  grep -q 'LinkStatus' <<<"$out" || { echo "FAIL: $n's link listing is empty or not a listing"; return 1; }
  grep -E 'cni0|flannel' <<<"$out" && { echo "FAIL: $n still has Flannel links"; bad=1; }
  return "$bad"
}
hubble_observe() {  # hubble_observe END ARGS...: hubble observe through a port-forward to hubble-relay
  local end=$1 pf rc=0; shift
  # Run straight under timeout, so $! is timeout itself (it passes the kill on to kubectl), and without the lock's
  # descriptor, so nothing left behind can hold the lock.
  timeout "$(rl_left "$end" 180)" kubectl -n kube-system port-forward svc/hubble-relay 4245:80 > "$STATE/hubble-pf.log" 2>&1 9>&- & pf=$!
  for _ in $(seq 1 30); do timeout 3 nc -z 127.0.0.1 4245 2>/dev/null && break; sleep 1; done
  if timeout 3 nc -z 127.0.0.1 4245 2>/dev/null; then rl_run "$end" 120 hubble observe --server 127.0.0.1:4245 "$@" || rc=$?
  else echo "hubble-relay port-forward not ready: $(cat "$STATE/hubble-pf.log")" >&2; rc=1; fi
  kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
  return "$rc"
}
upgrade_k8s() {  # upgrade_k8s [--dry-run]: talosctl upgrade-k8s to the pinned version; prints its output
  local tv; tv=$(jq -r .kubernetes "$TF/versions.json")
  rl_run 0 "$([ "${1:-}" = --dry-run ] && echo 300 || echo 600)" talosctl -n 10.10.10.11 upgrade-k8s --to "$tv" ${1:+"$1"} 2>&1
}
changes() { awk -v a="$1" '$1 == "<" && $2 == a {print $3}' | sort -u | tr '\n' ' ' | sed 's/ $//'; }  # changes Pruned|deleted < upgrade-k8s output
etcd_two_ok() {  # etcd_two_ok IP1 IP2: both answer without errors and agree on one leader that is one of them; 3 tries
  local out try ids leaders
  for try in 1 2 3; do
    if out=$(rl_run 0 30 talosctl -n "$1,$2" etcd status 2>&1); then
      ids=$(awk 'NR>1 && NF {print $2}' <<<"$out" | sort -u)
      leaders=$(awk 'NR>1 && NF {print $(NF-6)}' <<<"$out" | sort -u)
      if [ "$(awk 'NR>1 && NF' <<<"$out" | wc -l)" = 2 ] && awk 'NR>1 && NF {if ($NF !~ /^[0-9.]+$/) bad++} END {exit bad}' <<<"$out" &&
         [ "$(wc -l <<<"$leaders")" = 1 ] && [ "$leaders" != 0000000000000000 ] && grep -qx "$leaders" <<<"$ids"; then
        echo "etcd two survivors OK, leader $leaders"; return 0
      fi
    fi
    [ "$try" -lt 3 ] && sleep "$(rl_left 0 30)"
  done
  echo "etcd two survivors NOT OK:"; echo "$out"; return 1
}

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
  rl_run "$1" 30 kubectl -n netpol-canary logs "job/$j"; rl_run 0 30 kubectl -n netpol-canary delete job "$j" --wait=false >/dev/null; return "$rc"
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
  rl_run "$1" 30 kubectl -n agent-sandbox logs "$p" > "$STATE/t7.out" || rc=1; cat "$STATE/t7.out"
  rl_run 0 30 kubectl -n agent-sandbox delete pod "$p" --wait=false >/dev/null
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
  local json unavailable
  json=$(rl_run "$1" 30 kubectl get apiservices -o json --request-timeout=20s) || { echo "FAIL: reading APIServices"; return 1; }
  unavailable=$(jq -r '.items[]|select(any(.status.conditions[]?; .type=="Available" and .status!="True"))|.metadata.name' <<<"$json") || { echo "FAIL: APIServices unparsable"; return 1; }
  [ -z "$unavailable" ] || { echo "unavailable: $unavailable"; return 1; }
  rl_run "$1" 30 kubectl top nodes
}
vmis() {  # vmis END: each VMI as "namespace/name phase ready"; fails unless the read succeeds and parses
  local json
  json=$(rl_run "$1" 30 kubectl get vmi -A -o json) || return 1
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase // "None") \([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown")"' <<<"$json"
}
t10() {  # the VMs of 0.14, by identity, phase and Ready
  local now
  [ -e "$STATE/vmi.txt" ] || { echo "FAIL: no VM list from op.sh suspend-flux"; return 1; }
  now=$(vmis "$1") || { echo "FAIL: reading the VMs"; return 1; }
  echo "${now:-no VMs}"
  diff <(sort "$STATE/vmi.txt") <(sort <<<"$now" | sed '/^$/d') || { echo "FAIL: the VMs differ from 0.14's"; return 1; }
}
t11() {  # errors in the last 15 minutes of both external-dns instances; an unreadable log fails
  local d out c bad=0
  for d in external-dns-mikrotik external-dns-stationary; do
    out=$(rl_run "$1" 30 kubectl -n external-dns logs "deploy/$d" --since=15m --request-timeout=30s) || { echo "$d: FAIL: log unreadable"; bad=1; continue; }
    c=$(grep -ciE 'error|fail' <<<"$out"); echo "$d: $c"; [ "$c" = 0 ] || bad=1
  done
  return "$bad"
}
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
flux_all() {  # flux_all FIELD WANT: every Kustomization's FIELD (4 SUSPENDED, 5 READY) is WANT; fails on an unreadable listing
  local out
  out=$(rl_run 0 60 flux get kustomizations -A --no-header) || { echo "FAIL: reading the Kustomizations"; return 1; }
  [ -n "$out" ] || { echo "FAIL: no Kustomizations listed"; return 1; }
  echo "$out"
  awk -v f="$1" -v w="$2" 'NF && $f != w {bad=1} END {exit bad}' <<<"$out"   # NAMESPACE NAME REVISION SUSPENDED READY MESSAGE
}

# ---- steps -------------------------------------------------------------------------------------------------------
step_preflight() {  # 0.1-0.6, and warms the tools
  local bad=0 out
  echo "== 0.1 talosctl config"; rl_run 0 30 talosctl config info || bad=1
  echo "== 0.2 Talos on five nodes"; out=$(rl_run 0 60 talosctl -n "$NODE_IPS" version --short 2>&1); echo "$out"
  [ "$(grep -c 'Tag:' <<<"$out")" -ge 5 ] || { echo "FAIL: not five nodes answering"; bad=1; }
  echo "== kubeconfig"; if command -v ops-kubeconfig >/dev/null; then rl_run 0 120 ops-kubeconfig || bad=1; fi
  echo "== 0.3 context"; rl_run 0 30 kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo; rl_run 0 30 kubectl auth whoami || bad=1
  echo "== 0.4 cluster admin"; [ "$(rl_run 0 30 kubectl auth can-i '*' '*' -A)" = yes ] || { echo "FAIL: not cluster-admin"; bad=1; }
  echo "== 0.5 LB and Talos API"; rl_run 0 15 curl -sk --max-time 10 -o /dev/null -w '%{http_code}\n' "https://$LB/" || bad=1
  rl_run 0 10 nc -z -w 5 10.10.10.11 50000 || bad=1
  echo "== 0.6 Terraform"; rl_run 0 300 terraform -chdir="$TF" init -input=false -no-color >/dev/null || bad=1
  plan_check || bad=1
  echo "== tools"; rl_run 0 30 cni-pods 2>&1 | head -1; rl_run 0 30 hubble version || bad=1
  [ "$bad" = 0 ] || { hint "preflight failed: stop the preflight (0.B)"; return 1; }
  echo "preflight passed"
}
plan_check() {  # plan_check [post-m3]: a plain plan has no changes; before M3 also: -var cni=cilium updates exactly the five
                # nodes, each only in its CNI, proxy and Cilium manifest
  local rc out a want
  echo "-- plain plan (default cni)"
  rl_run 0 600 terraform -chdir="$TF" plan -input=false -no-color -lock-timeout=60s -detailed-exitcode >/dev/null; rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: a plain plan is not 'No changes' (exit $rc)"; return 1; }
  echo "no changes"
  [ "${1:-}" = post-m3 ] && return 0
  echo "-- plan -var cni=cilium"
  rl_run 0 600 terraform -chdir="$TF" plan -input=false -no-color -lock-timeout=60s -detailed-exitcode -var cni=cilium -out="$STATE/cilium.tfplan" >/dev/null; rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: plan -var cni=cilium exited $rc, want 2 (changes)"; return 1; }
  rl_run 0 120 terraform -chdir="$TF" show -json "$STATE/cilium.tfplan" > "$STATE/cilium.tfplan.json" || return 1
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
step_plan_check() {  # plan-check [post-m3]
  case ${1:-} in ""|post-m3) ;; *) usage "plan-check [post-m3]";; esac
  plan_check "${1:-}" || { hint "the plan isn't what the runbook expects: STOP"; return 1; }
}
step_suspend_flux() {  # 0.14: record the VMs and Jobs, suspend every Kustomization
  local out
  out=$(vmis 0) || { echo "FAIL: reading the VMs"; return 1; }
  sed '/^$/d' <<<"$out" > "$STATE/vmi.txt"; echo "VMs:"; cat "$STATE/vmi.txt"
  echo "Jobs:"; rl_run 0 30 kubectl get jobs -A > "$STATE/jobs.txt" || { echo "FAIL: reading the Jobs"; return 1; }; cat "$STATE/jobs.txt"
  rl_run 0 120 flux suspend kustomization --all || return 1
  flux_all 4 True || { echo "FAIL: not every Kustomization is suspended"; return 1; }
  log "flux suspended"
}
step_baseline() { checks baseline 0; [ "$FAILED" = 0 ]; }
step_apply() {  # 1.1 (c1, sets T0) and 3.1 (the others), with -var cni=cilium
  local n=${1:-} rc
  node_ok "$n" apply
  if [ "$n" != c1 ]; then
    need_t0
    grep -q '^applied c1 ' "$STATE/applied" || die "c1 isn't applied yet"
    case $n in w*) grep -q '^applied c3 ' "$STATE/applied" || die "control planes first: c3 isn't applied yet";; esac
  fi
  # The plan comes first and changes nothing; T0 starts with c1's apply.
  tf_plan "$n" -var cni=cilium; rc=$?
  if [ "$rc" = 10 ]; then
    [ -s "$STATE/t0" ] || die "$n already has the Cilium config but T0 isn't set: check the cluster before anything else"
    echo "applied $n $(now) (no change)" >> "$STATE/applied"; echo "applied $n (it already had this config)"; return 0
  fi
  if [ "$rc" != 0 ]; then
    if [ -s "$STATE/t0" ]; then rollback_hint; else hint "the plan isn't the expected one-node change: STOP before T0"; fi
    return 1
  fi
  if [ "$n" = c1 ] && [ ! -s "$STATE/t0" ]; then : > "$STATE/applied"; now > "$STATE/t0"; log "T0 $(cat "$STATE/t0")"; fi
  echo "T0=$(cat "$STATE/t0")  (post it to the VM thread)"
  CAP_HINT="the apply of $n may have reached Talos: it counts as attempted; run op.sh apply $n again (an applied node plans no change)"
  tf_apply "$n"; rc=$?
  [ "$rc" = 0 ] && { echo "applied $n"; [ "$n" = c1 ] && hint "VM: api_watch and gate 1; then op.sh remove-cni0"; return 0; }
  [ "$rc" = 124 ] && echo "terraform apply timed out after 300 s"
  rollback_hint; return 1
}
step_remove_cni0() {  # 2.0: ends 4 min from now, no later than T0 + 14 (cleanup up to 70 s more)
  need_t0
  local end; end=$(( $(date +%s) + 240 )); [ "$end" -lt "$(at "$T0" 14)" ] || end=$(at "$T0" 14)
  remove_all cni0 "$end" || hint "log it and go on: those nodes keep cni0 until their reboot; recreate and the probes handle a collision"
  rm -f "$RUN/deadline"   # the removal's own budget ending is not a runbook failure
  cnipods "$(at "$T0" 18)" 120 plan | grep 'cni0 still up' || echo "no cni0 left"
  return 0
}
step_m1_confirm() {  # 2.3: OP confirms the user's T2 and T3 passed, after op.sh m1 passed, by T0 + 20
  need_t0
  [ -e "$STATE/m1-op" ] || die "op.sh m1 hasn't passed yet"
  [ "$(rl_left "$(at "$T0" 20)" 1)" -gt 0 ] || { DEADLINE_HINT="M1 (T0 + 20) passed before the user's checks were confirmed: roll back by log ($(route))"; echo M1 >> "$RUN/deadline"; return 1; }
  now > "$STATE/m1"; log "M1 confirmed"
  echo "M1 passed; next: op.sh m2, or op.sh recreate post-m1 if recreate didn't finish"
}
step_recreate() {  # 2.1-2.2 until T0 + 18; after M1 (op.sh m1-confirm), `recreate post-m1` until T0 + 45
  local end include="" plan rc mode=pre
  [ "${1:-}" = post-m1 ] && { mode=post; shift; }
  if [ $# != 0 ]; then
    if [ "$1" != -include ] || [ -z "${2:-}" ] || [ $# != 2 ]; then usage "recreate [post-m1] [-include ns/pod,...]"; fi
    include=$2
  fi
  need_t0
  if [ "$mode" = post ]; then
    [ -e "$STATE/m1" ] || die "recreate post-m1 needs M1 confirmed first: op.sh m1-confirm"
    end=$(at "$T0" 45); DEADLINE_HINT="T0 + 45 passed: no further forward step; choose rollback (by log: $(route)) or STOP, and log it"
  else
    end=$(at "$T0" 18); DEADLINE_HINT="recreation (T0 + 18) ended: not a failure by itself, go straight to op.sh m1"
  fi
  plan=$(cnipods "$end" 120 plan); rc=$?; echo "$plan"
  [ "$rc" = 0 ] || return 1
  awk '$1 == "report" {print $2}' <<<"$plan" | grep -vxF -f <(tr ',' '\n' <<<"$include") | paste -sd, - > "$STATE/allow"
  echo "ALLOW=$(cat "$STATE/allow")  (left alone; log a disposition for each: Jobs and CronJob pods stay, VMs stop/start, standalone pods by hand)"
  cnipods "$end" 1800 recreate ${include:+-include "$include"}; rc=$?
  if [ "$rc" = 0 ]; then
    echo "recreated"; if [ "$mode" = pre ]; then hint "op.sh m1"; else hint "op.sh m2"; fi; return 0
  fi
  hint "an endpoint-ownership wait → op.sh endpoint-capture start m2; otherwise read the owner it names, fix or accept it, and run op.sh recreate $([ "$mode" = post ] && echo "post-m1 ")again"
  return 1
}
step_m1() {  # 2.3: T1 and Harbor over HTTPS by T0 + 20; then the user's T2 and T3, confirmed with op.sh m1-confirm
  need_t0
  local end; end=$(at "$T0" 20)
  DEADLINE_HINT="M1 (T0 + 20) passed: roll back by log ($(route))"
  check T1 t1 "$end"; check T3-https t3_https "$end"
  [ "$FAILED" = 0 ] || { rollback_hint; return 1; }
  now > "$STATE/m1-op"
  echo "USER: T2 login chain and T3 Harbor push/pull now; once both pass, op.sh m1-confirm (by T0 + 20)."
}
step_m2() {  # 2.4-2.5 until T0 + 45, or after the prune (4.3) under a fresh 15 minutes: op.sh m2 [prune]
  local end bad=0
  case ${1:-} in
    prune) end=$(budget s0 15); DEADLINE_HINT="4.3's 15 minutes ended: choose rollback (by log: $(route)) or STOP, and log it" ;;
    "") need_t0; end=$(at "$T0" 45); DEADLINE_HINT="T0 + 45 passed: no further forward step; choose rollback (by log: $(route)) or STOP, and log it" ;;
    *) usage "m2 [prune]" ;;
  esac
  echo "== verify"; cnipods "$end" 900 verify || bad=1
  echo "== endpoints"; cnipods "$end" 120 endpoints -allow "$(cat "$STATE/allow" 2>/dev/null)" || bad=1
  echo "== agent status"; agent_status "$end" || bad=1
  echo "== operator"; operator_ready "$end" || { echo "cilium-operator not 2/2"; bad=1; }
  echo "== node probes"; node_probes "$end" || bad=1
  [ "$bad" = 0 ] && { echo "M2 passed"; return 0; }
  hint "a failure naming an endpoint, or cannot take ownership → op.sh endpoint-capture start $([ "${1:-}" = prune ] && echo fresh || echo m2); stale endpoints of just-deleted pods: op.sh m2 again after 60 s; otherwise choose rollback (by log: $(route)) or STOP, and log it"
  return 1
}
eb_end() {  # sets EB_END: M2's deadline, or the episode's 15 minutes kept in ~/cutover/er0 (in the main shell, so die stops the step)
  case $(cat "$STATE/eb" 2>/dev/null) in
    m2) need_t0; EB_END=$(at "$T0" 45) ;;
    fresh) EB_END=$(at "$(cat "$STATE/er0")" 15) ;;
    *) die "no endpoint-ownership episode: start one with op.sh endpoint-capture start m2|fresh" ;;
  esac
}
step_endpoint_capture() {  # endpoint ownership 1-2. `start m2|fresh` begins an episode; a bare call captures again
  local end diag a ids id pod
  case "${1:-}${2:+ $2}" in
    "start m2") echo m2 > "$STATE/eb"; log "endpoint episode m2" ;;
    "start fresh") echo fresh > "$STATE/eb"; now > "$STATE/er0"; log "endpoint episode fresh $(cat "$STATE/er0")" ;;
    "") ;;
    *) usage "endpoint-capture [start m2|fresh]" ;;
  esac
  eb_end; end=$EB_END
  if [ "$(rl_left "$end" 1)" = 0 ]; then
    echo "the episode's budget ended at $(date -u -d "@$end" +%H:%M:%SZ); capturing for the record only (5 min), the budget stays ended"
    end=$(( $(date +%s) + 300 ))
  fi
  DEADLINE_HINT="the endpoint-ownership budget ended: terminal (step 5 of Endpoint ownership)"
  diag="$STATE/diag-$(date +%s)"; mkdir -p "$diag"
  rl_run "$end" 60 kubectl get ciliumendpoints.cilium.io -A -o json > "$diag/ceps.json" || echo "WARN: CiliumEndpoints unreadable"
  rl_run "$end" 60 kubectl get pods -A -o json > "$diag/pods.json" || echo "WARN: pods unreadable"
  rl_run "$end" 60 kubectl get events -A -o json > "$diag/events.json" || echo "WARN: events unreadable"
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
step_clear_cep() { [ $# = 1 ] && [[ $1 == */* ]] || usage "clear-cep <ns/name>"
  local end; eb_end; end=$EB_END; DEADLINE_HINT="the endpoint-ownership budget ended: terminal (step 5 of Endpoint ownership)"
  cnipods "$end" 120 clear-stale-ceps -cep "$1"; }
step_recreate_include() { [ $# = 1 ] && [[ $1 == */* ]] || usage "recreate-include <ns/pod>"
  local end; eb_end; end=$EB_END; DEADLINE_HINT="the endpoint-ownership budget ended: terminal (step 5 of Endpoint ownership)"
  cnipods "$end" 660 recreate -include "$1" -timeout 10m; }
step_endpoint_converge() {  # endpoint ownership 4: within 2 minutes (and the budget), every agent OK and endpoints pass
  local end until_; eb_end; end=$EB_END; until_=$(( $(date +%s) + 120 )); [ "$until_" -lt "$end" ] || until_=$end
  DEADLINE_HINT="the endpoint-ownership budget ended: terminal (step 5 of Endpoint ownership)"
  while [ "$(rl_left "$until_" 1)" -gt 0 ]; do
    agent_status "$until_" && cnipods "$until_" 60 endpoints -allow "$(cat "$STATE/allow" 2>/dev/null)" && { echo "recovered: resume where you came from"; rm -f "$RUN/deadline"; return 0; }
    sleep "$(rl_left "$until_" 15)"
  done
  rm -f "$RUN/deadline"   # the two minutes ending is this step's verdict, printed below
  hint "terminal: op.sh endpoint-capture for the record; from M2 roll back by log ($(route)); from 4.3 choose rollback or STOP and log it; from 5.3 STOP (no rollback without the user)"
  return 1
}
step_prune_dry_run() {  # 4.2: exactly Flannel's and kube-proxy's 8 objects
  local out want got
  out=$(upgrade_k8s --dry-run) || { echo "$out"; echo "FAIL: the dry run failed"; return 1; }
  echo "$out"
  want=$(tr ' ' '\n' <<<'ClusterRole/flannel ClusterRoleBinding/flannel ClusterRoleBinding/kube-proxy ConfigMap/kube-system/kube-flannel-cfg DaemonSet/kube-system/kube-flannel DaemonSet/kube-system/kube-proxy ServiceAccount/kube-system/flannel ServiceAccount/kube-system/kube-proxy' | sort -u | tr '\n' ' ' | sed 's/ $//')
  got=$(changes Pruned <<<"$out")
  [ "$got" = "$want" ] || { echo "FAIL: pruned: $got"; hint "anything but these 8 stops the window: STOP"; return 1; }
  echo "dry run prunes exactly the 8"
}
step_prune() {  # 4.3: upgrade-k8s (at most 3 tries), then flannel.1 within 5 min; then op.sh m2 prune
  local try out rc=1
  for try in 1 2 3; do
    out=$(upgrade_k8s); rc=$?; echo "$out"; [ "$rc" = 0 ] && break
    capped && return 1
    echo "upgrade-k8s try $try failed; re-checking etcd"; rl_run 0 30 talosctl -n "$CPS" etcd status || break
  done
  [ "$rc" = 0 ] || { hint "the prune failed 3 times: choose rollback (by log: $(route)) or STOP, and log it"; return 1; }
  remove_all flannel1 $(( $(date +%s) + 300 )) || echo "flannel.1 left on some nodes: logged only; their reboot removes it"
  rm -f "$RUN/deadline"
  hint "VM: gate 1 again (10 min); then op.sh m2 prune"
}
post_reboot_checks() {  # post_reboot_checks NODE END: 5.3 and 5.4 for NODE
  local bad=0
  echo "== verify"; cnipods "$2" 900 verify || bad=1
  echo "== agent status"; agent_status "$2" || bad=1
  echo "== CNI config and links"; node_clean "$1" "$2" || bad=1
  return "$bad"
}
step_reboot() {  # 5.3-5.4: reboot_node, then verify, agent status, the CNI config and links
  node_ok "${1:-}" reboot
  local n=$1
  reboot_node "$n" || { hint "no further reboots: a CP whose Talos API doesn't answer → E1 (user); otherwise STOP"; return 1; }
  CAP_HINT="$n rebooted; its checks were cut short: op.sh reboot-check $n"
  post_reboot_checks "$n" $(( $(date +%s) + 900 )) && { echo "$n rebooted and clean"; return 0; }
  rm -f "$RUN/deadline"
  hint "no further reboots: an endpoint failure → op.sh endpoint-capture start fresh; otherwise STOP (no rollback without the user)"
  return 1
}
step_reboot_check() {  # 5.3-5.4 without the reboot
  node_ok "${1:-}" reboot-check
  post_reboot_checks "$1" $(( $(date +%s) + 900 )) && { echo "$1 clean"; return 0; }
  rm -f "$RUN/deadline"
  hint "no further reboots: an endpoint failure → op.sh endpoint-capture start fresh; otherwise STOP (no rollback without the user)"
  return 1
}
step_api_down_reboot() {  # E5: the Kubernetes API is down, Talos and etcd healthy: reboot one CP through Talos alone.
  # With the API down there is nothing to cordon or list, and nothing can be scheduled anyway, so nothing that needs
  # Kubernetes runs here. It refuses unless the other two members are healthy and agree on a leader among them.
  local n=${1:-} ip others boot
  case $n in c1|c2|c3) ;; *) usage "api-down-reboot <c1|c2|c3>";; esac
  ip=$(ip_of "$n"); others=$(tr ',' '\n' <<<"$CPS" | grep -vx "$ip" | paste -sd' ' -)
  # shellcheck disable=SC2086  # the two other control planes' addresses
  etcd_two_ok $others || { hint "the other two etcd members aren't healthy: STOP, no reboot"; return 1; }
  rl_run 0 30 talosctl -n "$ip" version >/dev/null || { hint "$n's Talos API doesn't answer: E1 (user), not E5"; return 1; }
  CAP_HINT="the reboot of $n may have started: check its boot ID before anything else; don't reboot it again blindly"
  boot=$(talos_reboot "$ip") || { hint "$n didn't reboot: STOP"; return 1; }
  echo "$n rebooted (boot ID $boot)"
  hint "VM: etcd_ok, then api_watch 10: STABLE → resume; otherwise STOP"
}
step_forfeit() { node_ok "${1:-}" forfeit; case $1 in c*) ;; *) usage "forfeit <c1|c2|c3>";; esac; rl_run 0 60 talosctl -n "$(ip_of "$1")" etcd forfeit-leadership; }
step_accept() {  # section 6: forward (M3) or rollback (under the rollback budget RA0 + 60)
  local end=0
  case ${1:-} in
    forward) ;;
    rollback) end=$(budget ra0 60); DEADLINE_HINT="rollback acceptance's 60 minutes ended: STOP, the cluster is on Flannel" ;;
    *) usage "accept forward|rollback" ;;
  esac
  checks "$1" "$end"
  [ "$FAILED" = 0 ] || { hint "report the failed checks; rollback acceptance failing: STOP, the cluster is on Flannel"; return 1; }
  hint "then op.sh resume-flux"
}
step_rollback_verify() {  # Rollback A.7 first part: cni-pods verify -cni flannel and the probes, under RA0 + 60
  local end bad=0; end=$(budget ra0 60)
  DEADLINE_HINT="rollback acceptance's 60 minutes ended: STOP, the cluster is on Flannel"
  cnipods "$end" 900 verify -cni flannel -cni0 none || bad=1
  node_probes "$end" || bad=1
  [ "$bad" = 0 ] && { hint "op.sh accept rollback"; return 0; }
  hint "rollback acceptance failed: STOP, the cluster is on Flannel"; return 1
}
step_resume_flux() {  # T12, last: resume, reconcile, and every Kustomization Ready within 10 minutes
  local end
  rl_run 0 120 flux resume kustomization --all || { echo "FAIL: flux resume"; return 1; }
  rl_run 0 300 flux reconcile source git flux-system || { echo "FAIL: reconciling the source"; return 1; }
  end=$(( $(date +%s) + 600 )); DEADLINE_HINT="not every Kustomization Ready within 10 minutes: report it"
  until flux_all 4 False >/dev/null && flux_all 5 True >/dev/null; do
    [ "$(rl_left "$end" 15)" -gt 0 ] || { flux_all 5 True; echo "FAIL: not every Kustomization Ready within 10 minutes"; return 1; }
    sleep "$(rl_left "$end" 15)"
  done
  flux_all 5 True; log "flux resumed, all Ready"
}
step_rollback_apply() {  # Rollback A: c1 only; B: every node, workers retried once; -var cni=flannel whatever the default is
  local r rc n ip
  case ${1:-} in a|b) ;; *) usage "rollback-apply a|b";; esac
  r=$(route); echo "$r"
  [ "$1" = a ] && [ "$r" != "Rollback A" ] && die "the applied-node log calls for $r, not A"
  log "rollback $1 start"
  CAP_HINT="run op.sh rollback-apply $1 again: nodes already on Flannel plan no change and are skipped"
  for n in $([ "$1" = a ] && echo c1 || echo "$NODES_ALL"); do
    tf_change "$n" -var cni=flannel; rc=$?
    capped && return 1
    if [ "$rc" != 0 ]; then
      case $n in
        c*) hint "$n's apply failed: E1 for $n (user: UART)"; return 1 ;;
        w*) ip=$(ip_of "$n"); rl_run 0 30 talosctl -n "$ip" version; sleep "$(rl_left 0 60)"
            tf_change "$n" -var cni=flannel || { hint "STOP: $n still fails; the control planes are on Flannel"; return 1; } ;;
      esac
    fi
  done
  hint "VM: api_watch 10 and etcd_ok, cni_gate flannel; then op.sh rollback-prune"
}
step_rollback_prune() {  # Rollback A.4-A.5: record the agents, prune Cilium's exactly 33 objects, remove Cilium's taint
  local out got want try rc=1 n nodes
  rl_run 0 60 kubectl -n kube-system get pods -l k8s-app=cilium -o json > "$STATE/agents-before-prune.json" || echo "WARN: the agents' state couldn't be saved"
  out=$(upgrade_k8s --dry-run) || { echo "$out"; echo "FAIL: the dry run failed"; return 1; }
  echo "$out"
  got=$(changes Pruned <<<"$out")
  want=$(tr ' ' '\n' <<<'ClusterRoleBinding/cilium ClusterRoleBinding/cilium-operator ClusterRole/cilium ClusterRole/cilium-operator ConfigMap/kube-system/cilium-config ConfigMap/kube-system/cilium-envoy-config ConfigMap/kube-system/hubble-relay-config CronJob/kube-system/hubble-generate-certs Job/kube-system/hubble-generate-certs-ef4be98870 DaemonSet/kube-system/cilium DaemonSet/kube-system/cilium-envoy Deployment/kube-system/cilium-operator Deployment/kube-system/hubble-relay Namespace/cilium-secrets RoleBinding/cilium-secrets/cilium-operator-tlsinterception-secrets RoleBinding/cilium-secrets/cilium-tlsinterception-secrets RoleBinding/kube-system/cilium-config-agent RoleBinding/kube-system/cilium-operator-ztunnel RoleBinding/kube-system/hubble-generate-certs Role/cilium-secrets/cilium-operator-tlsinterception-secrets Role/cilium-secrets/cilium-tlsinterception-secrets Role/kube-system/cilium-config-agent Role/kube-system/cilium-operator-ztunnel Role/kube-system/hubble-generate-certs ServiceAccount/kube-system/cilium ServiceAccount/kube-system/cilium-envoy ServiceAccount/kube-system/cilium-operator ServiceAccount/kube-system/hubble-generate-certs ServiceAccount/kube-system/hubble-relay Service/kube-system/cilium-envoy Service/kube-system/hubble-metrics Service/kube-system/hubble-peer Service/kube-system/hubble-relay' | sort -u | tr '\n' ' ' | sed 's/ $//')
  [ "$got" = "$want" ] || { echo "FAIL: pruned: $got"; hint "anything but Cilium's 33 objects stops the window: STOP"; return 1; }
  for try in 1 2 3; do out=$(upgrade_k8s); rc=$?; echo "$out"; [ "$rc" = 0 ] && break; capped && return 1; done
  [ "$rc" = 0 ] || { hint "STOP: the rollback prune failed 3 times"; return 1; }
  out=$(rl_run 0 30 kubectl get pods -A -l app.kubernetes.io/part-of=cilium -o name) || { echo "FAIL: reading Cilium's pods"; return 1; }
  [ -z "$out" ] || { echo "FAIL: Cilium pods remain"; return 1; }
  out=$(rl_run 0 30 kubectl get nodes -o json) || { echo "FAIL: reading the nodes"; return 1; }
  nodes=$(jq -r '.items[]|select(any(.spec.taints[]?; .key=="node.cilium.io/agent-not-ready"))|.metadata.name' <<<"$out") || { echo "FAIL: nodes unparsable"; return 1; }
  for n in $nodes; do rl_run 0 30 kubectl taint nodes "$n" node.cilium.io/agent-not-ready- || return 1; done
  hint "op.sh rollback-reboot <node> for every node, one at a time (VM: etcd_ok around each CP)"
}
flannel_ready() {  # flannel_ready NODE: a kube-flannel pod on NODE is Running and Ready
  rl_run "$2" 30 kubectl -n kube-system get pods --field-selector spec.nodeName="$1" -o json |
    jq -e '[.items[] | select(any(.metadata.ownerReferences[]?; .name == "kube-flannel") and .status.phase == "Running" and any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length == 1' >/dev/null
}
step_rollback_reboot() {  # Rollback A.6: reboot_node, then this node's kube-flannel pod Running and Ready within 10 min
  node_ok "${1:-}" rollback-reboot
  case ${2:-} in ""|uncordoned) ;; *) usage "rollback-reboot <node> [uncordoned]";; esac
  local end
  reboot_node "$1" "${2:-}" || { hint "the node didn't come back: a CP whose Talos API doesn't answer → E1, a CP with etcd unhealthy → E4, otherwise STOP"; return 1; }
  CAP_HINT="$1 rebooted; check its kube-flannel pod by hand, then go on"
  end=$(( $(date +%s) + 600 ))
  until flannel_ready "$1" "$end"; do
    [ "$(rl_left "$end" 10)" -gt 0 ] || { rm -f "$RUN/deadline"; hint "no Running, Ready kube-flannel pod on $1 within 10 min: STOP"; return 1; }
    sleep "$(rl_left "$end" 10)"
  done
  echo "$1 rebooted; its kube-flannel pod is Ready"
}
step_repair() {  # Rollback A.6: inspect, or repair, one node's CNI config
  node_ok "${1:-}" repair
  case ${2:-inspect} in inspect|repair) ;; *) usage "repair <node> [inspect|repair]";; esac
  repair "$1" "${2:-inspect}" 0
}
step_status() { echo "state: $STATE"; echo "window SHA: $(cat "$STATE/window-sha")"; echo "T0: $(cat "$STATE/t0" 2>/dev/null || echo unset)"; echo "applied-node log:"; cat "$STATE/applied" 2>/dev/null; route; echo "ALLOW: $(cat "$STATE/allow" 2>/dev/null)"; tail -n 20 "$STATE/log" 2>/dev/null; }

STEPS="init preflight plan-check suspend-flux baseline apply remove-cni0 recreate m1 m1-confirm m2 endpoint-capture clear-cep recreate-include endpoint-converge prune-dry-run prune reboot reboot-check api-down-reboot forfeit accept rollback-verify resume-flux rollback-apply rollback-prune rollback-reboot repair route status"
[ $# -ge 1 ] || usage "<step> [args]; steps: $STEPS"
step=$1; shift
case " $STEPS " in *" $step "*) ;; *) usage "<step> [args]; unknown step '$step'; steps: $STEPS";; esac
[ "$step" = route ] && { route; exit 0; }
log "start $step $*"
"step_${step//-/_}" "$@"; rc=$?
if capped; then
  echo "STEP CAP: the step's 29 minutes ran out: $CAP_HINT" >&2; rc=125
elif [ -s "$RUN/deadline" ] && [ "$rc" != 0 ]; then
  echo "DEADLINE: $DEADLINE_HINT" >&2; rc=124
fi
log "end $step rc=$rc"
exit $rc
