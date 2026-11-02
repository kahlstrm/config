#!/usr/bin/env bash
# shellcheck disable=SC2015  # `check && pass ... || fail ...`: pass and fail always succeed
# Tests op.sh against stubbed cluster tools (tests/stub) in a throwaway git checkout with its own origin: init and the
# window SHA, the lock, state shared across invocations, the T0 requirement, argument checks, that every cluster
# command runs under a deadline, runbook deadlines against the step cap, every step's happy path, and failure
# injection for each read a step's verdict rests on.
# Usage: tests/run.sh (needs bash, git, coreutils, findutils, util-linux, jq, yq, gawk, gnused, gnutar).
set -uo pipefail
export LC_ALL=C
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)    # local-talos/cutover
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REAL_TIMEOUT=$(command -v timeout)
export REAL_TIMEOUT
FAILURES=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; FAILURES=$((FAILURES + 1)); }
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# ---- a checkout of local-talos with op.sh, and its origin ----------------------------------------------------
REPO=$WORK/repo
mkdir -p "$REPO/infra/local-talos/cutover" "$REPO/infra/local-kubernetes/apps/pocket-id-sync"
cp "$SRC/op.sh" "$REPO/infra/local-talos/cutover/"
cp "$SRC/../versions.json" "$SRC/../cni0-remove.yaml" "$SRC/../cni-repair.yaml" "$REPO/infra/local-talos/"
echo "resources: []" > "$REPO/infra/local-kubernetes/apps/pocket-id-sync/kustomization.yaml"
git -C "$REPO" init -q -b main && gitc "$REPO" add -A && gitc "$REPO" commit -qm init
git clone -q --bare "$REPO" "$WORK/origin.git" && git -C "$REPO" remote add origin "$WORK/origin.git" && git -C "$REPO" fetch -q origin
OP=$REPO/infra/local-talos/cutover/op.sh
SHA=$(git -C "$REPO" rev-parse HEAD)

# ---- stubs and fixtures ---------------------------------------------------------------------------------------
export STUB_DIR=$WORK/fixtures STUB_STATE=$WORK/stubstate STUB_LOG=$WORK/calls.log STUB_REV=$SHA
mkdir -p "$WORK/bin" "$STUB_DIR" "$STUB_STATE"
for t in timeout nix kubectl talosctl terraform cni-pods flux curl nc hubble kustomize; do ln -s "$SRC/tests/stub" "$WORK/bin/$t"; done
for o in ClusterRole/flannel ClusterRoleBinding/flannel ClusterRoleBinding/kube-proxy ConfigMap/kube-system/kube-flannel-cfg \
  DaemonSet/kube-system/kube-flannel DaemonSet/kube-system/kube-proxy ServiceAccount/kube-system/flannel ServiceAccount/kube-system/kube-proxy; do
  echo " < Pruned $o"; done > "$STUB_DIR/prune-forward.txt"
for o in ClusterRoleBinding/cilium ClusterRoleBinding/cilium-operator ClusterRole/cilium ClusterRole/cilium-operator ConfigMap/kube-system/cilium-config \
  ConfigMap/kube-system/cilium-envoy-config ConfigMap/kube-system/hubble-relay-config CronJob/kube-system/hubble-generate-certs \
  Job/kube-system/hubble-generate-certs-ef4be98870 DaemonSet/kube-system/cilium DaemonSet/kube-system/cilium-envoy Deployment/kube-system/cilium-operator \
  Deployment/kube-system/hubble-relay Namespace/cilium-secrets RoleBinding/cilium-secrets/cilium-operator-tlsinterception-secrets \
  RoleBinding/cilium-secrets/cilium-tlsinterception-secrets RoleBinding/kube-system/cilium-config-agent RoleBinding/kube-system/cilium-operator-ztunnel \
  RoleBinding/kube-system/hubble-generate-certs Role/cilium-secrets/cilium-operator-tlsinterception-secrets Role/cilium-secrets/cilium-tlsinterception-secrets \
  Role/kube-system/cilium-config-agent Role/kube-system/cilium-operator-ztunnel Role/kube-system/hubble-generate-certs ServiceAccount/kube-system/cilium \
  ServiceAccount/kube-system/cilium-envoy ServiceAccount/kube-system/cilium-operator ServiceAccount/kube-system/hubble-generate-certs \
  ServiceAccount/kube-system/hubble-relay Service/kube-system/cilium-envoy Service/kube-system/hubble-metrics Service/kube-system/hubble-peer \
  Service/kube-system/hubble-relay; do echo " < Pruned $o"; done > "$STUB_DIR/prune-rollback.txt"
plan_json() {  # plan_json EXTRA: the five node updates; EXTRA is added to every node's new config
  local before after
  before=$'version: v1alpha1\nmachine:\n  install: {disk: /dev/nvme0n1}\ncluster:\n  network:\n    cni: {name: flannel}\n  proxy: {}\n  inlineManifests: [{name: flux, contents: x}]\n---\napiVersion: v1alpha1\nkind: UserVolumeConfig\nname: local-storage\n'
  after=$'version: v1alpha1\nmachine:\n  install: {disk: /dev/nvme0n1}\ncluster:\n  network:\n    cni: {name: none}\n  proxy: {disabled: true}\n  inlineManifests: [{name: flux, contents: x}, {name: cilium, contents: y}]\n---\napiVersion: v1alpha1\nkind: UserVolumeConfig\nname: local-storage\n'"$1"
  jq -n --arg b "$before" --arg a "$after" '{resource_changes: (
    [("c1","c2","c3") | {address: "module.cluster.talos_machine.controlplane[\"\(.).k8s.kalski.xyz\"]"}] +
    [("w1","w2") | {address: "module.cluster.talos_machine.worker[\"\(.).k8s.kalski.xyz\"]"}] |
    map(. + {change: {actions: ["update"], before: {machine_configuration: $b}, after: {machine_configuration: $a}}})
  ) + [{address: "talos_image_factory_schematic.worker", change: {actions: ["no-op"]}}]}'
}
plan_json "" > "$STUB_DIR/cilium.tfplan.json"

ST=$WORK/state
# op ARGS...: op.sh with the stubs, inside the cutover shell's environment; output in $OUT, exit code in $RC
op() {
  OUT=$(cd "$REPO/infra" && PATH="$WORK/bin:$PATH" CUTOVER_SHELL=1 CUTOVER_STATE="$ST" CUTOVER_STEP_CAP="${CAP:-1740}" \
    bash "$OP" "$@" 2>&1); RC=$?
}
expect() {  # expect CODE PATTERN NAME
  if [ "$RC" = "$1" ] && { [ -z "$2" ] || grep -qE -- "$2" <<<"$OUT"; }; then pass "$3"; else fail "$3 (exit $RC, want $1 and /$2/):"; tail -n 8 <<<"$OUT" | sed "s/^/     /"; fi
}
# The routes and terminal claims op.sh prints; matched as lines, so paths in diagnostics can't match them.
TERMINAL='^(ROUTE: .*\b(E1|STOP|rollback)\b|STOP: |.*didn.t reboot|DEADLINE: )'
refute() {  # refute PATTERN NAME: the last output must not match
  if grep -qE -- "$1" <<<"$OUT"; then fail "$2 (matched /$1/)"; else pass "$2"; fi
}
fresh() { rm -rf "$ST" "$ST.archive" "${STUB_STATE:?}"/*; : > "$STUB_LOG"; mkdir -p "$ST"; echo "$SHA" > "$ST/window-sha"; }
set_t0() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S > "$ST/t0"; }   # set_t0 '-17 min'
longest() { awk -v t="$1" '$1 == "bounded" && $3 == t {print $2}' "$STUB_LOG" | sort -n | tail -1; }

# ---- init, the window SHA, the lock -----------------------------------------------------------------------------
rm -rf "$ST"
op status; expect 3 'no window SHA: run op.sh init' "steps refuse before init"
op init abc; expect 2 'usage: op.sh init' "init needs a full SHA"
touch "$REPO/infra/untracked"; op init "$SHA"; expect 3 'local changes' "init refuses a dirty checkout"; rm "$REPO/infra/untracked"
gitc "$REPO" commit -qm local --allow-empty; op init "$(git -C "$REPO" rev-parse HEAD)"; expect 3 'is not on origin/main' "init refuses a commit that isn't on main"
op init "$SHA"; expect 3 "HEAD is .*, not $SHA" "init refuses a SHA the checkout isn't at"
git -C "$REPO" reset -q --hard "$SHA"
op init "$SHA"; expect 0 "window SHA $SHA" "init pins the window SHA"
[ "$(cat "$ST/window-sha")" = "$SHA" ] && grep -q CUTOVER_SHELL "$ST/dev-env.sh" && pass "init records the SHA and saves the environment" || fail "init's state"
grep -q 'bounded .* nix print-dev-env --profile' "$STUB_LOG" && pass "init saves the environment as a GC-rooted profile" || fail "init's nix call"
git clone -q "$WORK/origin.git" "$WORK/other" && gitc "$WORK/other" commit -qm upstream --allow-empty && git -C "$WORK/other" push -q origin main
: > "$STUB_LOG"; op status; expect 0 "window SHA: $SHA" "a merge to main after init doesn't block a step"
grep -q 'fetch' "$STUB_LOG" && fail "a step fetched" || pass "steps don't fetch"
echo "# edit" >> "$REPO/infra/local-talos/versions.json"; op status; expect 3 'local changes' "steps refuse a modified checkout"
git -C "$REPO" checkout -q -- infra/local-talos/versions.json
git -C "$REPO" pull -q --ff-only origin main; op status; expect 3 'HEAD is not the window SHA' "steps refuse a checkout moved off the window SHA"
git -C "$REPO" reset -q --hard "$SHA"
set_t0 '-1 min'; op init "$SHA"; expect 3 "earlier window's T0" "init refuses a stale T0"
op init "$SHA" --archive; expect 0 'archived the earlier state' "init --archive keeps the earlier window aside"
ls "$ST".archive/*/t0 >/dev/null 2>&1 && [ ! -e "$ST/t0" ] && pass "the archive holds the earlier T0" || fail "archive contents"
flock "$ST/lock" sleep 3 & sleep 0.5
op status; expect 3 'another op.sh step is running' "an overlapping step is refused"; wait
op status; expect 0 'T0: unset' "the lock is released afterwards"

# ---- arguments ------------------------------------------------------------------------------------------------
fresh
op; expect 2 'usage' "no step is a usage error"
op frobnicate; expect 2 "unknown step 'frobnicate'" "an unknown step is a usage error"
op apply x9; expect 2 'apply <c1' "apply needs a node name"
op reboot; expect 2 'reboot <c1' "reboot needs a node name"
op api-down-reboot w1; expect 2 'api-down-reboot <c1' "api-down-reboot takes a control plane"
op clear-cep foo; expect 2 'clear-cep <ns/name>' "clear-cep needs ns/name"
op recreate-include; expect 2 'recreate-include <ns/pod>' "recreate-include needs ns/pod"
op rollback-apply c; expect 2 'rollback-apply a\|b' "rollback-apply takes a or b"
op accept sideways; expect 2 'accept forward\|rollback' "accept takes forward or rollback"
op forfeit w1; expect 2 'forfeit <c1' "forfeit takes a control plane"
op endpoint-capture start; expect 2 'endpoint-capture \[start m2\|fresh\]' "endpoint-capture start takes m2 or fresh"
op plan-check sideways; expect 2 'plan-check \[post-m3\]' "plan-check takes post-m3 only"
op recreate -include; expect 2 'recreate \[post-m1\]' "recreate -include needs pods"

# ---- T0 and shared state --------------------------------------------------------------------------------------
fresh
for s in remove-cni0 recreate m1 m1-confirm m2; do op $s; expect 3 'T0 is not set' "$s refuses without T0"; done
op apply c2; expect 3 'T0 is not set' "apply c2 refuses before c1"
op apply c1; expect 0 'applied c1' "apply c1 sets T0 and applies"
grep -qE 'terraform .* plan .*-var cni=cilium -target=module.cluster.talos_machine.controlplane\["c1.k8s.kalski.xyz"\] -out=' "$STUB_LOG" &&
  grep -qE 'terraform .* apply .*/c1.tfplan$' "$STUB_LOG" && pass "apply plans c1 alone with -var cni=cilium, then applies that plan file" || fail "apply c1's terraform arguments"
t0=$(cat "$ST/t0"); op status; expect 0 "T0: $t0" "a later invocation reads the same T0"
op route; expect 0 '^Rollback A$' "only c1 attempted routes to A"
op apply w1; expect 3 "c3 isn't applied" "workers wait for the control planes"
op apply c1; [ "$(cat "$ST/t0")" = "$t0" ] && pass "re-applying c1 keeps T0" || fail "re-applying c1 moved T0"
op apply c2; expect 0 'applied c2' "apply c2 after c1"
op route; expect 0 'Rollback B \(attempted beyond c1: c2' "an attempt beyond c1 routes to B"
op rollback-apply a; expect 3 'calls for Rollback B' "rollback-apply a refuses when the log calls for B"
STUB_NOCHANGE=c2 op apply c2; expect 0 'already had this config' "a node that already has the config isn't applied again"
STUB_APPLY_FAIL=c3 op apply c3; expect 1 'ROUTE: roll back by log: Rollback B' "a failed apply prints the rollback route"
grep -q '^attempt c3 ' "$ST/applied" && ! grep -q '^applied c3 ' "$ST/applied" && pass "a failed apply is logged as an attempt only" || fail "applied-node log after a failed apply"

# ---- runbook deadlines, the step cap ----------------------------------------------------------------------------
fresh; set_t0 '-19 min'
op recreate; expect 124 'DEADLINE: recreation \(T0 \+ 18\) ended: not a failure by itself' "recreate after T0 + 18 exits 124 and says to go to M1"
grep -q 'cni-pods recreate' "$STUB_LOG" && fail "recreate ran past T0 + 18" || pass "no recreation once T0 + 18 has passed"
fresh; set_t0 '-46 min'
op m2; expect 124 'DEADLINE: T0 \+ 45 passed' "m2 after T0 + 45 exits 124"
fresh; set_t0 '-17 min -50 sec'
op recreate; max=$(longest cni-pods)
[ -n "$max" ] && [ "$max" -le 70 ] && pass "recreate's commands are bounded by T0 + 18 (longest $max s)" || fail "recreate's bound (longest ${max:-none} s)"
fresh; set_t0 '-1 min'
CAP=5 op recreate; max=$(awk '$1 == "bounded" {print $2}' "$STUB_LOG" | sort -n | tail -1)
[ -n "$max" ] && [ "$max" -le 5 ] && pass "the step cap bounds every command (longest $max s with a 5 s cap)" || fail "step cap (longest ${max:-none} s)"
fresh; set_t0 '-1 min'
OUT=$(cd "$REPO/infra" && PATH="$WORK/bin:$PATH" CUTOVER_SHELL=1 CUTOVER_STATE="$ST" CUTOVER_START=$(( $(date +%s) - 1741 )) bash "$OP" recreate 2>&1); RC=$?
expect 125 'STEP CAP: .*run the same step again' "the cap counts from the outer start carried through the re-exec"
fresh; set_t0 '-30 sec'
op remove-cni0; max=$(longest kubectl)
[ -n "$max" ] && [ "$max" -le 240 ] && pass "remove-cni0 is bounded by its 4-minute budget (longest $max s)" || fail "remove-cni0 bound (longest ${max:-none} s)"

# ---- M1 and recreation after it ---------------------------------------------------------------------------------
fresh; set_t0 '-10 min'
op m1-confirm; expect 3 "op.sh m1 hasn't passed" "m1-confirm needs op.sh m1 first"
op m1; expect 0 'op.sh m1-confirm' "m1 passes OP's checks and asks for the user's"
op recreate post-m1; expect 3 'needs M1 confirmed first' "recreate post-m1 refuses before M1 is confirmed"
op m1-confirm; expect 0 'M1 passed' "m1-confirm records M1"
set_t0 '-25 min'; op recreate post-m1; expect 0 'recreated' "recreate post-m1 continues after minute 18"
max=$(longest cni-pods); [ -n "$max" ] && [ "$max" -le 1200 ] && pass "recreate post-m1 is bounded by T0 + 45 (longest $max s)" || fail "recreate post-m1 bound"
set_t0 '-46 min'; op recreate post-m1; expect 124 'DEADLINE: T0 \+ 45 passed' "recreate post-m1 refuses after minute 45"
fresh; set_t0 '-21 min'; touch "$ST/m1-op"
op m1-confirm; expect 124 'M1 \(T0 \+ 20\) passed' "a confirmation after T0 + 20 is a missed M1"

# ---- the preflight's plan check -------------------------------------------------------------------------------
fresh
op plan-check; expect 0 'five updates, CNI, proxy and the Cilium manifest only' "plan-check accepts the five CNI updates"
plan_json $'---\napiVersion: v1alpha1\nkind: EthernetConfig\nname: end0\n' > "$STUB_DIR/cilium.tfplan.json"
op plan-check; expect 1 "more than CNI, proxy and the Cilium manifest" "plan-check refuses any other change"
plan_json "" > "$STUB_DIR/cilium.tfplan.json"
op plan-check post-m3; expect 0 '^no changes' "plan-check post-m3 needs only a plain plan without changes"

# ---- failure injection: no failed read may pass ---------------------------------------------------------------
fresh
STUB_FAIL='logs cni-repair-' op reboot-check w1; expect 1 'could not be inspected' "reboot-check fails when the CNI inspection fails"
STUB_EMPTY='logs cni-repair-' op reboot-check w1; expect 1 'no before:/after: lines' "reboot-check fails on an empty inspection"
STUB_FAIL='get links' op reboot-check w1; expect 1 'links could not be read' "reboot-check fails when the links can't be read"
STUB_EMPTY='get links' op reboot-check w1; expect 1 'not a listing' "reboot-check fails on an empty link listing"
STUB_FAIL='logs deploy/external-dns-stationary' op accept forward; expect 1 'FAIL T11' "T11 fails when a log can't be read"
STUB_FAIL='get vmi' op accept forward; expect 1 'FAIL T10' "T10 fails without its VM read"
op suspend-flux >/dev/null; STUB_VMI_PHASE=Paused op accept forward; expect 1 'FAIL T10' "T10 fails when a VM's phase changed"
STUB_FAIL='get kustomizations' op suspend-flux; expect 1 'reading the Kustomizations' "suspend-flux fails without the Kustomization listing"
STUB_FAIL='get apiservices' op accept forward; expect 1 'FAIL T9' "T9 fails without the APIService read"
CAP=8 STUB_FLUX_NOT_READY=1 op resume-flux; expect 125 'STEP CAP' "resume-flux never passes while a Kustomization isn't Ready"
CAP=8 STUB_FAIL='get kustomizations' op resume-flux; expect 125 'STEP CAP' "resume-flux never passes without the listing"
refute '^every Kustomization Ready' "resume-flux claims nothing without the listing"
CAP=20 STUB_FLANNEL_NOT_READY=1 op rollback-reboot w2; expect 125 'STEP CAP' "rollback-reboot never passes until the node's kube-flannel pod is Ready"
refute "kube-flannel pod is Ready" "rollback-reboot claims nothing while kube-flannel isn't Ready"

# ---- E5: rebooting a control plane with the API down -------------------------------------------------------------
fresh; : > "$STUB_LOG"
STUB_FAIL=kubectl op api-down-reboot c2; expect 0 'c2 rebooted \(boot ID boot-1\)' "api-down-reboot works with the Kubernetes API down"
grep -q ' kubectl ' "$STUB_LOG" && fail "api-down-reboot called kubectl" || pass "api-down-reboot needs no Kubernetes call"
: > "$STUB_LOG"; STUB_FAIL='etcd status' op api-down-reboot c2; expect 1 "other two etcd members aren't healthy: STOP" "api-down-reboot refuses without two healthy etcd members"
grep -q ' reboot ' "$STUB_LOG" && fail "api-down-reboot rebooted without healthy etcd survivors" || pass "no reboot without healthy etcd survivors"
grep -q 'etcd status' "$STUB_LOG" && grep 'etcd status' "$STUB_LOG" | grep -qv 10.10.10.12 && pass "api-down-reboot asks the other two members" || fail "api-down-reboot's etcd check"

# ---- a cap hit midway routes to "rerun", never to E1 or STOP -----------------------------------------------------
fresh; echo "attempt c2 x" > "$ST/applied"
CAP=6 STUB_SLEEP='controlplane["c2:10' op rollback-apply b; expect 125 'STEP CAP: .*rollback-apply b again' "a cap hit midway through rollback B says to rerun it"
refute "$TERMINAL" "a capped rollback B routes to neither E1 nor STOP"
grep -q '^applied c1 ' "$ST/applied" && pass "rollback B's nodes before the cap stay logged" || fail "rollback B's log before the cap"
CAP=4 STUB_SLEEP='verify -cni flannel:10' op rollback-verify; expect 125 'STEP CAP' "a cap hit in rollback-verify says to rerun it"
refute "$TERMINAL" "a capped rollback-verify doesn't say STOP"

# ---- endpoint ownership: an episode's budget isn't reset by another capture ---------------------------------------
fresh
op endpoint-capture; expect 3 'no endpoint-ownership episode' "a capture needs an episode"
op endpoint-capture start fresh; expect 0 'captured in' "endpoint-capture start fresh begins an episode"
er0=$(cat "$ST/er0"); sleep 1
op endpoint-capture; expect 0 'captured in' "endpoint-capture captures again"
[ "$(cat "$ST/er0")" = "$er0" ] && pass "a further capture keeps the episode's start" || fail "a capture moved the episode's start"
date -u -d '-20 min' +%Y-%m-%dT%H:%M:%S > "$ST/er0"; er0=$(cat "$ST/er0")
op endpoint-capture; expect 0 'for the record only' "after the budget ends, a capture still records evidence"
[ "$(cat "$ST/er0")" = "$er0" ] && pass "the ended budget stays ended" || fail "a capture after expiry reset the budget"
op clear-cep app/web-0; expect 124 'endpoint-ownership budget ended' "recovery steps refuse once the episode's budget ended"

# ---- time classification: the cap, a runbook deadline and a step's own wait never pass for one another -----------
fresh; op endpoint-capture start fresh >/dev/null
CAP=2 STUB_FAIL='get pods -l k8s-app=cilium -o name' op endpoint-converge; expect 125 'STEP CAP' "converge waiting into the cap exits 125"
refute "$TERMINAL" "a capped converge routes to neither rollback nor STOP"
date -u -d '-20 min' +%Y-%m-%dT%H:%M:%S > "$ST/er0"
op endpoint-converge; expect 124 'DEADLINE: the endpoint-ownership budget ended' "converge after the episode's budget exits 124"
fresh; date -u -d '+5 min' +%Y-%m-%dT%H:%M:%S > "$ST/er0"; echo fresh > "$ST/eb"
STUB_FAIL='get pods -l k8s-app=cilium -o name' op endpoint-converge; expect 1 'ROUTE: terminal' "converge's own two minutes ending is a terminal verdict (exit 1)"
fresh; set_t0 '-10 min'; touch "$ST/m1-op"
OUT=$(cd "$REPO/infra" && PATH="$WORK/bin:$PATH" CUTOVER_SHELL=1 CUTOVER_STATE="$ST" CUTOVER_START=$(( $(date +%s) - 1741 )) bash "$OP" m1-confirm 2>&1); RC=$?
expect 125 'STEP CAP' "an expired cap makes m1-confirm 125, not a missed M1"
refute 'T0 \+ 20' "an expired cap doesn't claim T0 + 20 passed"
fresh
CAP=3 STUB_SLEEP='reboot --wait:10' op api-down-reboot c2; expect 125 'STEP CAP' "a cap during api-down-reboot exits 125"
refute "$TERMINAL" "a capped api-down-reboot claims neither STOP nor 'didn't reboot'"
fresh
CAP=3 STUB_SLEEP='reboot --wait:10' op reboot w1; expect 125 'STEP CAP: .*reboot-check w1' "a cap during a reboot says reboot-check, not reboot again"
refute "$TERMINAL" "a capped reboot claims nothing terminal"

# ---- resume-flux judges one successful snapshot -----------------------------------------------------------------
fresh
CAP=8 STUB_FLUX_NOT_READY=1 STUB_FAIL_AFTER='get kustomizations:2' op resume-flux; expect 125 'STEP CAP' "resume-flux never passes when later listings fail"
refute '^every Kustomization Ready' "resume-flux claims nothing after failed listings"
max=$(longest flux); [ -n "$max" ] && [ "$max" -le 600 ] && pass "resume-flux's reads are bounded by its 10 minutes (longest $max s)" || fail "resume-flux read bound"

# ---- only a NIX_BUILD_TOP this invocation made is removed --------------------------------------------------------
fresh; op init "$SHA" --archive >/dev/null
mkdir -p "$WORK/tmp/nix-shell.inherited"
(cd "$REPO/infra" && PATH="$WORK/bin:$PATH" CUTOVER_SHELL=1 CUTOVER_STATE="$ST" NIX_BUILD_TOP="$WORK/tmp/nix-shell.inherited" bash "$OP" status >/dev/null 2>&1)
[ -d "$WORK/tmp/nix-shell.inherited" ] && pass "an inherited NIX_BUILD_TOP survives a step" || fail "a step deleted an inherited NIX_BUILD_TOP"
before=$(find "$WORK/tmp" -maxdepth 1 -name 'nix-shell.*' | wc -l)
(cd "$REPO/infra" && PATH="$WORK/bin:$PATH" CUTOVER_STATE="$ST" TMPDIR="$WORK/tmp" bash "$OP" status >/dev/null 2>&1)
after=$(find "$WORK/tmp" -maxdepth 1 -name 'nix-shell.*' | wc -l)
[ "$after" = "$before" ] && [ -d "$WORK/tmp/nix-shell.inherited" ] && pass "the re-exec removes only the NIX_BUILD_TOP it made" || fail "re-exec cleanup ($before → $after)"

# ---- init refuses any one stale budget --------------------------------------------------------------------------
for f in er0 ra0 s0; do
  fresh; now_=$(date -u +%Y-%m-%dT%H:%M:%S); echo "$now_" > "$ST/$f"
  op init "$SHA"; expect 3 "T0 or budgets \( $f \)" "init refuses a stale $f alone"
done
op init "$SHA" --archive; expect 0 'archived the earlier state' "init --archive keeps a lone budget aside"

# ---- every step's happy path, all commands bounded ------------------------------------------------------------
fresh
run() { local want=$1; shift; op "$@"; expect "$want" "${PATTERN-.}" "happy path: $*"; }
PATTERN='preflight passed' run 0 preflight
PATTERN='' run 0 suspend-flux
PATTERN='PASS T11' run 0 baseline
PATTERN='applied c1' run 0 apply c1
PATTERN='verified: no cni0' run 0 remove-cni0
PATTERN='ALLOW=pocket-id/pocket-id-sync-x' run 0 recreate
grep -qx 'pocket-id/pocket-id-sync-x' "$ST/allow" && pass "recreate keeps the left-alone pods as ALLOW" || fail "ALLOW"
PATTERN='USER: T2' run 0 m1
PATTERN='M1 passed' run 0 m1-confirm
PATTERN='M2 passed' run 0 m2
PATTERN='captured in' run 0 endpoint-capture start m2
PATTERN='cleared' run 0 clear-cep app/web-0
PATTERN='verified' run 0 recreate-include app/web-0
PATTERN='recovered' run 0 endpoint-converge
for n in c2 c3 w1 w2; do op apply $n; done
PATTERN='exactly the 8' run 0 prune-dry-run
PATTERN='m2 prune' run 0 prune
PATTERN='M2 passed' run 0 m2 prune
PATTERN='rebooted and clean' run 0 reboot w1
PATTERN='PASS T13-hubble' run 0 accept forward
PATTERN='^every Kustomization Ready' run 0 resume-flux
STUB_PRUNE=rollback PATTERN='rollback-reboot' run 0 rollback-prune
PATTERN='kube-flannel pod is Ready' run 0 rollback-reboot w2
PATTERN='after:' run 0 repair w2
PATTERN='accept rollback' run 0 rollback-verify
PATTERN='PASS T10' run 0 accept rollback
cp "$STUB_LOG" "$WORK/earlier.log"; : > "$STUB_LOG"
PATTERN='rollback-prune' run 0 rollback-apply b
plans=$(grep -cE 'terraform .* plan .*-var cni=flannel -target=' "$STUB_LOG"); applies=$(grep -cE 'terraform .* apply .*\.tfplan$' "$STUB_LOG")
[ "$plans" = 5 ] && [ "$applies" = 5 ] && ! grep -q 'cni=cilium' "$STUB_LOG" && pass "rollback-apply b plans each node with -var cni=flannel and applies those plans" || fail "rollback-apply's terraform calls ($plans plans, $applies applies)"
cat "$WORK/earlier.log" >> "$STUB_LOG"
grep UNBOUNDED "$STUB_LOG" > "$WORK/unbounded"
[ -s "$WORK/unbounded" ] && { fail "cluster commands ran without a deadline:"; sed 's/^/     /' "$WORK/unbounded" | head; } || pass "every cluster command in every step ran under a deadline"
grep -q 'end rollback-apply rc=0' "$ST/log" && pass "the window log records each step and its exit code" || fail "window log"

echo; [ $FAILURES = 0 ] && echo "all tests passed" || { echo "$FAILURES failed"; exit 1; }
