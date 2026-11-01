#!/usr/bin/env bash
# shellcheck disable=SC2015  # `check && pass ... || fail ...`: pass and fail always succeed
# Tests op.sh against stubbed cluster tools (tests/stub) in a throwaway git checkout with its own origin:
# the guard, state shared across invocations, the T0 requirement, argument checks, that every cluster command
# runs under a deadline, the runbook deadlines and the step cap, and each step's happy path.
# Usage: tests/run.sh (needs bash, git, coreutils, jq, yq, gawk, gnused, gnutar).
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

# ---- a checkout of local-talos with op.sh, and its origin ----------------------------------------------------
REPO=$WORK/repo
mkdir -p "$REPO/infra/local-talos/cutover" "$REPO/infra/local-kubernetes/apps/pocket-id-sync"
cp "$SRC/op.sh" "$REPO/infra/local-talos/cutover/"
cp "$SRC/../versions.json" "$SRC/../cni0-remove.yaml" "$SRC/../cni-repair.yaml" "$REPO/infra/local-talos/"
echo "resources: []" > "$REPO/infra/local-kubernetes/apps/pocket-id-sync/kustomization.yaml"
git -C "$REPO" init -q -b main && git -C "$REPO" -c user.email=t@t -c user.name=t add -A &&
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
git clone -q --bare "$REPO" "$WORK/origin.git" && git -C "$REPO" remote add origin "$WORK/origin.git" && git -C "$REPO" fetch -q origin
OP=$REPO/infra/local-talos/cutover/op.sh

# ---- stubs and fixtures ---------------------------------------------------------------------------------------
export STUB_DIR=$WORK/fixtures STUB_STATE=$WORK/stubstate STUB_LOG=$WORK/calls.log
mkdir -p "$WORK/bin" "$STUB_DIR" "$STUB_STATE"
for t in timeout nix kubectl talosctl terraform cni-pods flux curl nc hubble kustomize; do ln -s "$SRC/tests/stub" "$WORK/bin/$t"; done
STUB_REV=$(git -C "$REPO" rev-parse HEAD); export STUB_REV
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

# op ARGS...: op.sh with the stubs; output in $OUT, exit code in $RC
op() {
  OUT=$(cd "$REPO/infra" && PATH="$WORK/bin:$PATH" CUTOVER_SHELL=1 CUTOVER_STATE="$WORK/state" CUTOVER_STEP_CAP="${CAP:-1740}" \
    bash "$OP" "$@" 2>&1); RC=$?
}
expect() {  # expect CODE PATTERN NAME
  if [ "$RC" = "$1" ] && { [ -z "$2" ] || grep -qE -- "$2" <<<"$OUT"; }; then pass "$3"; else fail "$3 (exit $RC, want $1 and /$2/):"; tail -n 8 <<<"$OUT" | sed "s/^/     /"; fi
}
fresh() { rm -rf "$WORK/state" "${STUB_STATE:?}"/*; : > "$STUB_LOG"; }
set_t0() { mkdir -p "$WORK/state"; date -u -d "$1" +%Y-%m-%dT%H:%M:%S > "$WORK/state/t0"; }   # set_t0 '-17 min'

# ---- guard ----------------------------------------------------------------------------------------------------
fresh
op status; expect 0 'T0: unset' "guard passes on a clean checkout at origin/main"
touch "$REPO/infra/untracked"; op status; expect 3 'local changes' "guard refuses an untracked file"; rm "$REPO/infra/untracked"
echo "# edit" >> "$REPO/infra/local-talos/versions.json"; op status; expect 3 'local changes' "guard refuses a modified file"
git -C "$REPO" checkout -q -- infra/local-talos/versions.json
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm local --allow-empty; op status; expect 3 'is not origin/main' "guard refuses a local commit"
git -C "$REPO" reset -q --hard origin/main
git clone -q "$WORK/origin.git" "$WORK/other" && git -C "$WORK/other" -c user.email=t@t -c user.name=t commit -qm upstream --allow-empty && git -C "$WORK/other" push -q origin main
op status; expect 3 'is not origin/main' "guard refuses a checkout behind origin/main (after its fetch)"
git -C "$REPO" pull -q --ff-only origin main; op status; expect 0 'T0: unset' "guard passes again after a fast-forward"
grep -q 'UNBOUNDED nix' "$STUB_LOG" && fail "re-ran under nix develop although CUTOVER_SHELL=1" || pass "no nix develop inside the cutover shell"

# ---- arguments ------------------------------------------------------------------------------------------------
fresh
op; expect 2 'usage' "no step is a usage error"
op frobnicate; expect 2 "unknown step 'frobnicate'" "an unknown step is a usage error"
op apply x9; expect 2 'apply <c1' "apply needs a node name"
op reboot; expect 2 'reboot <c1' "reboot needs a node name"
op clear-cep foo; expect 2 'clear-cep <ns/name>' "clear-cep needs ns/name"
op recreate-include; expect 2 'recreate-include <ns/pod>' "recreate-include needs ns/pod"
op rollback-apply c; expect 2 'rollback-apply a\|b' "rollback-apply takes a or b"
op accept sideways; expect 2 'accept forward\|rollback' "accept takes forward or rollback"
op forfeit w1; expect 2 'forfeit <c1' "forfeit takes a control plane"
op endpoint-capture; expect 2 'endpoint-capture m2\|fresh' "endpoint-capture takes m2 or fresh"

# ---- T0 and shared state --------------------------------------------------------------------------------------
fresh
for s in remove-cni0 recreate m1 m2; do op $s; expect 3 'T0 is not set' "$s refuses without T0"; done
op apply c2; expect 3 'T0 is not set' "apply c2 refuses before c1"
op apply c1; expect 0 'applied c1' "apply c1 sets T0 and applies"
grep -q 'cni=cilium' "$STUB_LOG" && grep -q 'controlplane\["c1.k8s.kalski.xyz"\]' "$STUB_LOG" && pass "apply passes -var cni=cilium and the c1 target" || fail "apply c1's terraform arguments"
t0=$(cat "$WORK/state/t0"); op status; expect 0 "T0: $t0" "a later invocation reads the same T0"
op route; expect 0 '^Rollback A$' "only c1 attempted routes to A"
op apply w1; expect 3 "c3 isn't applied" "workers wait for the control planes"
op apply c1; [ "$(cat "$WORK/state/t0")" = "$t0" ] && pass "re-applying c1 keeps T0" || fail "re-applying c1 moved T0"
op apply c2; expect 0 'applied c2' "apply c2 after c1"
op route; expect 0 'Rollback B \(attempted beyond c1: c2' "an attempt beyond c1 routes to B"
op rollback-apply a; expect 3 'calls for Rollback B' "rollback-apply a refuses when the log calls for B"
STUB_APPLY_FAIL=c3 op apply c3; expect 1 'ROUTE: roll back by log: Rollback B' "a failed apply prints the rollback route"
grep -q '^attempt c3 ' "$WORK/state/applied" && ! grep -q '^applied c3 ' "$WORK/state/applied" && pass "a failed apply is logged as an attempt only" || fail "applied-node log after a failed apply"

# ---- deadlines ------------------------------------------------------------------------------------------------
fresh; set_t0 '-19 min'
op recreate; expect 124 'DEADLINE PASSED' "recreate after T0 + 18 exits 124 without running"
grep -q 'cni-pods recreate' "$STUB_LOG" && fail "recreate ran past T0 + 18" || pass "no recreation once T0 + 18 has passed"
fresh; set_t0 '-46 min'
op m2; expect 124 'runbook deadline for M2' "m2 after T0 + 45 exits 124"
fresh; set_t0 '-17 min -50 sec'
op recreate
max=$(awk '$3 == "cni-pods" {print $2}' "$STUB_LOG" | sort -n | tail -1)
[ -n "$max" ] && [ "$max" -le 70 ] && pass "recreate's commands are bounded by T0 + 18 (longest $max s)" || fail "recreate's bound (longest ${max:-none} s)"
fresh; set_t0 '-1 min'
CAP=5 op recreate
max=$(awk '$1 == "bounded" {print $2}' "$STUB_LOG" | sort -n | tail -1)
[ -n "$max" ] && [ "$max" -le 5 ] && pass "the step cap bounds every command (longest $max s with a 5 s cap)" || fail "step cap (longest ${max:-none} s)"
fresh; set_t0 '-30 sec'
op remove-cni0
max=$(awk '$1 == "bounded" && $3 == "kubectl" {print $2}' "$STUB_LOG" | sort -n | tail -1)
[ -n "$max" ] && [ "$max" -le 240 ] && pass "remove-cni0 is bounded by its 4-minute budget (longest $max s)" || fail "remove-cni0 bound (longest ${max:-none} s)"

# ---- the preflight's plan check -------------------------------------------------------------------------------
fresh
op plan-check; expect 0 'five updates, CNI, proxy and the Cilium manifest only' "plan-check accepts the five CNI updates"
plan_json $'---\napiVersion: v1alpha1\nkind: EthernetConfig\nname: end0\n' > "$STUB_DIR/cilium.tfplan.json"
op plan-check; expect 1 "more than CNI, proxy and the Cilium manifest" "plan-check refuses any other change"
plan_json "" > "$STUB_DIR/cilium.tfplan.json"

# ---- every step's happy path, all commands bounded ------------------------------------------------------------
fresh
run() { local want=$1; shift; op "$@"; expect "$want" "${PATTERN-.}" "happy path: $*"; }
PATTERN='preflight passed' run 0 preflight
PATTERN='' run 0 suspend-flux
PATTERN='PASS T11' run 0 baseline
PATTERN='applied c1' run 0 apply c1
PATTERN='verified: no cni0' run 0 remove-cni0
PATTERN='ALLOW=pocket-id/pocket-id-sync-x' run 0 recreate
grep -qx 'pocket-id/pocket-id-sync-x' "$WORK/state/allow" && pass "recreate keeps the left-alone pods as ALLOW" || fail "ALLOW"
PATTERN='USER: T2' run 0 m1
PATTERN='M2 passed' run 0 m2
PATTERN='captured in' run 0 endpoint-capture m2
PATTERN='cleared' run 0 clear-cep app/web-0
PATTERN='verified' run 0 recreate-include app/web-0
PATTERN='recovered' run 0 endpoint-converge
for n in c2 c3 w1 w2; do op apply $n; done
PATTERN='exactly the 8' run 0 prune-dry-run
PATTERN='m2 prune' run 0 prune
PATTERN='M2 passed' run 0 m2 prune
PATTERN='rebooted and clean' run 0 reboot w1
PATTERN='PASS T13-hubble' run 0 accept forward
PATTERN='' run 0 resume-flux
STUB_PRUNE=rollback PATTERN='rollback-reboot' run 0 rollback-prune
PATTERN='' run 0 rollback-reboot w2
PATTERN='after:' run 0 repair w2
PATTERN='accept rollback' run 0 rollback-verify
PATTERN='PASS T10' run 0 accept rollback
cp "$STUB_LOG" "$WORK/earlier.log"; : > "$STUB_LOG"
PATTERN='rollback-prune' run 0 rollback-apply b
applies=$(grep -c 'terraform .* apply .*-var cni=flannel' "$STUB_LOG")
[ "$applies" = 5 ] && ! grep -q 'apply .*cni=cilium' "$STUB_LOG" && pass "rollback-apply b applies -var cni=flannel to all five nodes" || fail "rollback-apply's terraform arguments ($applies flannel applies)"
cat "$WORK/earlier.log" >> "$STUB_LOG"
grep UNBOUNDED "$STUB_LOG" | grep -v ' nix ' > "$WORK/unbounded"
[ -s "$WORK/unbounded" ] && { fail "cluster commands ran without a deadline:"; sed 's/^/     /' "$WORK/unbounded" | head; } || pass "every cluster command in every step ran under a deadline"
grep -q 'end rollback-apply rc=0' "$WORK/state/log" && pass "the window log records each step and its exit code" || fail "window log"

echo; [ "$FAILURES" = 0 ] && echo "all tests passed" || { echo "$FAILURES failed"; exit 1; }
