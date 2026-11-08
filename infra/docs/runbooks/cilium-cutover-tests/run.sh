#!/usr/bin/env bash
# shellcheck disable=SC2015  # `check && pass ... || fail ...`: pass and fail always succeed
# Tests the Cilium cutover runbook's OP blocks as ops sends them. It extracts every block from the runbook,
# lints it with shellcheck, and runs its whole Bash call, wrapper included, against stubbed cluster tools in a
# ~/config checkout with its own origin. Covered: the window SHA, saved profile and lock; shared state and T0;
# runbook deadlines against the 29-minute cap, whose clock starts before Nix; verdict waits; failed, plausible
# but failed, and unparsable reads; stdin; cancellation; and every block's happy path with every cluster command
# bounded. A few mutations of the blocks check that the tests notice what they guard against.
#
# Usage: run.sh [RUNBOOK]   (needs bash, python3, shellcheck, git, jq, yq and util-linux on PATH)
set -uo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNBOOK=${1:-$HERE/../cilium-cutover.md}
INFRA=$HERE/../../..
WORK=$(mktemp -d)
pids() { cat "$WORK"/stubstate/sleepers "$WORK"/stubstate/daemons 2>/dev/null | tr ' ' '\n'; }  # stubs' sleeps
cleanup() { local p; while read -r p; do kill "$p" 2>/dev/null; done < <(pids); rm -rf "$WORK"; }
trap cleanup EXIT
REAL_TIMEOUT=$(command -v timeout); export REAL_TIMEOUT
FAILURES=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; FAILURES=$((FAILURES + 1)); }
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# ---- extraction and shellcheck --------------------------------------------------------------------------------
BLK=$WORK/blocks
python3 "$HERE/extract.py" "$RUNBOOK" "$BLK" > "$WORK/extract.txt" && pass "every block is one call within the size limits" ||
  { cat "$WORK/extract.txt"; fail "extraction"; exit 1; }
tail -n 1 "$WORK/extract.txt"
# SC2329: each block carries the same opening helpers, and not every block calls every one.
shellcheck -s bash -e SC2329 "$BLK"/*.sh "$BLK"/*.cmd && pass "shellcheck, every block and its call" || fail "shellcheck"
python3 - "$RUNBOOK" "$BLK" <<'PY' && pass "every tested call is byte-identical to a fence in the runbook" || fail "copy identity"
import pathlib, sys
book = pathlib.Path(sys.argv[1]).read_bytes()
calls = sorted(pathlib.Path(sys.argv[2]).glob('*.cmd'))
fences = book.count(b"<<'OP'\n")
bad = [c.name for c in calls if b'```sh\n' + c.read_bytes() + b'```\n' not in book]
print(f'{len(calls)} calls, {fences} OP fences, mismatched: {bad}')
sys.exit(1 if bad or len(calls) != fences else 0)
PY

# ---- a checkout, an origin, stubs ---------------------------------------------------------------------------
H=$WORK/home; REPO=$H/config; ST=$H/cutover
mkdir -p "$REPO/infra/local-talos" "$REPO/infra/local-kubernetes/apps/pocket-id-sync"
cp "$INFRA"/local-talos/{versions.json,cni0-remove.yaml,cni-repair.yaml} "$REPO/infra/local-talos/"
echo "resources: []" > "$REPO/infra/local-kubernetes/apps/pocket-id-sync/kustomization.yaml"
git -C "$REPO" init -q -b main && gitc "$REPO" add -A && gitc "$REPO" commit -qm init
git clone -q --bare "$REPO" "$WORK/origin.git" && git -C "$REPO" remote add origin "$WORK/origin.git" &&
  git -C "$REPO" fetch -q origin
SHA=$(git -C "$REPO" rev-parse HEAD)

export STUB_DIR=$WORK/fixtures STUB_STATE=$WORK/stubstate STUB_LOG=$WORK/calls.log STUB_REV=$SHA
export STUB_STORE_PATH=/nix/store/00000000000000000000000000000000-cutover-test-env
export STUB_OPS_RUN=$H/run-ops   # stands in for /run/ops-credentials, which tests can't write
mkdir -p "$WORK/bin" "$STUB_DIR" "$STUB_STATE"; : > "$WORK/all.log"
for t in timeout nix kubectl talosctl terraform cni-pods flux curl nc hubble kustomize ops-kubeconfig ops-routeros; do
  ln -s "$HERE/stub" "$WORK/bin/$t"; done
printf ' < Pruned %s\n' ClusterRole/flannel ClusterRoleBinding/{flannel,kube-proxy} ConfigMap/kube-system/kube-flannel-cfg \
  DaemonSet/kube-system/{kube-flannel,kube-proxy} ServiceAccount/kube-system/{flannel,kube-proxy} > "$STUB_DIR/prune-forward.txt"
printf ' < Pruned %s\n' ClusterRoleBinding/{cilium,cilium-operator} ClusterRole/{cilium,cilium-operator} \
  ConfigMap/kube-system/{cilium-config,cilium-envoy-config,hubble-relay-config} CronJob/kube-system/hubble-generate-certs \
  Job/kube-system/hubble-generate-certs-ef4be98870 DaemonSet/kube-system/{cilium,cilium-envoy} \
  Deployment/kube-system/{cilium-operator,hubble-relay} Namespace/cilium-secrets \
  {Role,RoleBinding}/cilium-secrets/{cilium-operator-tlsinterception-secrets,cilium-tlsinterception-secrets} \
  {Role,RoleBinding}/kube-system/{cilium-config-agent,cilium-operator-ztunnel,hubble-generate-certs} \
  ServiceAccount/kube-system/{cilium,cilium-envoy,cilium-operator,hubble-generate-certs,hubble-relay} \
  Service/kube-system/{cilium-envoy,hubble-metrics,hubble-peer,hubble-relay} > "$STUB_DIR/prune-rollback.txt"
plan_json() {  # the preflight's whole -var cni=cilium plan; $1 is added to every node's new config
  local before after
  before=$'version: v1alpha1\nmachine:\n  install: {disk: /dev/nvme0n1}\ncluster:\n  network:\n    cni: {name: flannel}\n'
  before+=$'  proxy: {}\n  inlineManifests: [{name: flux, contents: x}]\n---\napiVersion: v1alpha1\nkind: UserVolumeConfig\n'
  before+=$'name: local-storage\n'
  after=$'version: v1alpha1\nmachine:\n  install: {disk: /dev/nvme0n1}\ncluster:\n  network:\n    cni: {name: none}\n'
  after+=$'  proxy: {disabled: true}\n  inlineManifests: [{name: flux, contents: x}, {name: cilium, contents: y}]\n---\n'
  after+=$'apiVersion: v1alpha1\nkind: UserVolumeConfig\nname: local-storage\n'"$1"
  jq -n --arg b "$before" --arg a "$after" '{resource_changes: (
    [("c1","c2","c3") | {address: "module.cluster.talos_machine.controlplane[\"\(.).k8s.kalski.xyz\"]"}] +
    [("w1","w2") | {address: "module.cluster.talos_machine.worker[\"\(.).k8s.kalski.xyz\"]"}] |
    map(. + {change: {actions: ["update"], before: {machine_configuration: $b}, after: {machine_configuration: $a}}})
  ) + [{address: "talos_image_factory_schematic.worker", change: {actions: ["no-op"]}}]}'
}
plan_json "" > "$STUB_DIR/cilium.tfplan.json"

# mk ID [ASSIGNMENTS]: block ID's call into $WORK/b.cmd, with ASSIGNMENTS after its `# parameters` line, the test's
# credentials directory for /run/ops-credentials, CAP=<s> in place of the 29-minute cap and CONVERGE=<s> in place
# of EO.4's two minutes and POE_WAIT=<s> in place of E2's ten, so waits run short.
mk() {
  local id=$1; shift
  [ -s "$BLK/$id.cmd" ] || { echo "no block $id"; exit 1; }
  echo "$id" >> "$WORK/ran"
  awk -v ov="$*" '{print} /# parameters/ && ov != "" {print ov}' "$BLK/$id.cmd" > "$WORK/b.cmd"
  sed -i "s|^O=/run/ops-credentials$|O=$STUB_OPS_RUN|" "$WORK/b.cmd"
  ! grep -q /run/ops-credentials "$WORK/b.cmd" || { echo "$id names /run/ops-credentials outside its O= line"; exit 1; }
  [ -z "${CAP:-}" ] || sed -i "s/+ 1740 ))/+ $CAP ))/" "$WORK/b.cmd"
  [ -z "${CONVERGE:-}" ] || sed -i "s/^U=\$(( \$(date +%s) + 120 ))/U=\$(( \$(date +%s) + $CONVERGE ))/" "$WORK/b.cmd"
  [ -z "${POE_WAIT:-}" ] || sed -i "s/^W=\$(( \$(date +%s) + 600 ))/W=\$(( \$(date +%s) + $POE_WAIT ))/" "$WORK/b.cmd"
  local v; for v in CAP CONVERGE POE_WAIT; do   # an override that matched nothing would test the real, slow block
    [ -z "${!v:-}" ] || grep -qF "+ ${!v} ))" "$WORK/b.cmd" || { echo "$v=${!v} matched nothing in $id"; exit 1; }
  done
}
# go: runs $WORK/b.cmd as ops' Bash tool does, as one `bash -c`, in its own session, its output in a file so that
# collecting it can't block. Output in $OUT, exit code in $RC. A run past GO_LIMIT seconds (5 minutes) is killed,
# session and all: exit 137. A process the run leaves holding its output is killed and reported: exit 70. Either
# way a failure, never a hang.
call() { CALL=$(cat "$WORK/b.cmd"; printf x); CALL=${CALL%x}; }  # the call's exact bytes, trailing newline too
holders() { find /proc/[0-9]*/fd -lname "$1" 2>/dev/null | cut -d/ -f3 | sort -u; }  # processes with FILE open
# caller CMD…: execs CMD (in a subshell) as ops' tool shell might start a call: without KUBECONFIG, TALOSCONFIG or
# GOOGLE_APPLICATION_CREDENTIALS (CALLER_CREDS=1: set to paths that don't exist), with the stubs first on PATH
# (GO_PATH replaces it), and with default signal handling: a background job of a script starts with INT ignored,
# which a shell can't trap again.
caller() {
  local creds=()
  [ -z "${CALLER_CREDS:-}" ] || creds=(KUBECONFIG=/nonexistent TALOSCONFIG=/nonexistent GOOGLE_APPLICATION_CREDENTIALS=/nonexistent)
  exec env --default-signal -u KUBECONFIG -u TALOSCONFIG -u GOOGLE_APPLICATION_CREDENTIALS "${creds[@]}" \
    HOME="$H" PATH="${GO_PATH:-$WORK/bin:$PATH}" "$@"
}
go() {
  local pid end p held
  call; end=$(( $(date +%s) + ${GO_LIMIT:-300} ))
  (cd "$WORK" && caller setsid bash -c "$CALL" </dev/null >"$WORK/out" 2>&1) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 0.05; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null; wait "$pid"; RC=137; echo "KILLED after ${GO_LIMIT:-300} s: $(sed -n 3p "$WORK/b.cmd")"
  else wait "$pid"; RC=$?; fi
  held=$(holders "$WORK/out")
  if [ -n "$held" ]; then
    for p in $held; do kill -KILL "$p" 2>/dev/null; done
    RC=70; echo "LEFT HOLDING ITS OUTPUT: $(tr '\n' ' ' <<<"$held")$(sed -n 3p "$WORK/b.cmd")"
  fi
  OUT=$(cat "$WORK/out")
}
blk() { mk "$@"; go; }
expect() {  # expect CODE PATTERN NAME
  if [ "$RC" = "$1" ] && { [ -z "$2" ] || grep -qE -- "$2" <<<"$OUT"; }; then pass "$3"
  else fail "$3 (exit $RC, want $1 and /$2/):"; tail -n 8 <<<"$OUT" | sed "s/^/     /"; fi
}
TERMINAL='^(ROUTE: |STOP: |FAIL: .*STOP|.*didn.t reboot|DEADLINE: )'
refute() { if grep -qE -- "$1" <<<"$OUT"; then fail "$2 (matched /$1/)"; else pass "$2"; fi; }
called() { grep -qE -- "$1" "$STUB_LOG"; }
saved() {  # what 0.0 leaves: the window SHA and the saved profile
  mkdir -p "$ST"; echo "$SHA" > "$ST/window-sha"; echo "$STUB_STORE_PATH" > "$ST/profile-path"
  ln -sfn "$STUB_STORE_PATH" "$ST/dev-profile"
}
ops_files() {
  local f; mkdir -p "$STUB_OPS_RUN"; for f in kubeconfig talosconfig gcp.json routeros.netrc; do echo "$f" > "$STUB_OPS_RUN/$f"; done
}
fresh() {
  cat "$STUB_LOG" >> "$WORK/all.log" 2>/dev/null
  rm -rf "$ST" "$ST.archive" "${STUB_STATE:?}"/*; : > "$STUB_LOG"; saved; ops_files
}
set_t0() { date -d "$1" +%s > "$ST/t0"; }
longest() { awk -v t="$1" '$1 == "bounded" && $3 == t {print $2}' "$STUB_LOG" | sort -n | tail -1; }
lock_free() { flock -n "$ST/lock" true; }
alive() { local p; while read -r p; do kill -0 "$p" 2>/dev/null && echo "$p"; done < <(pids); }

# ---- the harness's watchdog ----------------------------------------------------------------------------------
watched() {  # watched NAME SCRIPT RC: SCRIPT as a block's call ends in RC within 5 s, and leaves nothing behind
  local t
  printf '%s\n' "$2" > "$WORK/b.cmd"; t=$(date +%s); GO_LIMIT=1 go
  [ "$RC" = "$3" ] && [ $(( $(date +%s) - t )) -lt 5 ] && [ -z "$(holders "$WORK/out")" ] &&
    pass "watchdog: $1" || fail "watchdog: $1 (exit $RC after $(( $(date +%s) - t )) s)"
}
watched "a run past its limit is killed, session and all" 'sleep 30' 137
watched "a process left holding the output fails the run at once" 'sleep 30 &' 70
watched "a quick run passes through" 'echo fine' 0

# ---- 0.0: the window SHA and the saved profile --------------------------------------------------------------
rm -rf "$ST"
blk status; expect 3 'REFUSED: the saved profile changed or is missing \(0.0\)' "steps refuse before 0.0"
mkdir -p "$ST"
touch "$REPO/infra/untracked"; blk 0.0 "SHA=$SHA"; expect 3 'local changes' "0.0 refuses a dirty checkout"
rm "$REPO/infra/untracked"
gitc "$REPO" commit -qm local --allow-empty; blk 0.0 "SHA=$(git -C "$REPO" rev-parse HEAD)"
expect 3 'is not .* on origin/main' "0.0 refuses a commit that isn't on main"
blk 0.0 "SHA=$SHA"; expect 3 "HEAD is not $SHA" "0.0 refuses a SHA the checkout isn't at"
git -C "$REPO" reset -q --hard "$SHA"
blk 0.0 "SHA=$SHA"; expect 0 "window SHA $SHA" "0.0 pins the window SHA"
[ "$(cat "$ST/window-sha")" = "$SHA" ] && [ "$(cat "$ST/profile-path")" = "$STUB_STORE_PATH" ] &&
  pass "0.0 records the SHA and the saved profile's store path" || fail "0.0's state"
blk status; expect 0 "window SHA $SHA" "a step runs in the recorded store path, offline"
ln -sfn /nix/store/11111111111111111111111111111111-other-env "$ST/dev-profile"; : > "$STUB_LOG"
blk status; expect 3 'REFUSED: the saved profile changed' "a step refuses when the saved profile points elsewhere"
called ' nix ' && fail "nix ran with a changed profile" || pass "no Nix start with a changed profile"
ln -sfn "$STUB_STORE_PATH" "$ST/dev-profile"
# shellcheck disable=SC2016  # expanded by the shell that reads BASH_ENV
printf '[ -n "${CUTOVER_START:-}" ] && touch %s/bash-env-ran\n' "$WORK" > "$WORK/bash-env"
mk status; call; OUT=$(cd "$WORK" && BASH_ENV=$WORK/bash-env caller bash -c "$CALL" </dev/null 2>&1)
[ ! -e "$WORK/bash-env-ran" ] && pass "BASH_ENV adds no code to Nix or the step's shell" || fail "a step read BASH_ENV"
git clone -q "$WORK/origin.git" "$WORK/other" && gitc "$WORK/other" commit -qm upstream --allow-empty &&
  git -C "$WORK/other" push -q origin main
blk status; expect 0 "window SHA $SHA" "a merge to main after 0.0 doesn't block a step"
echo "# edit" >> "$REPO/infra/local-talos/versions.json"; blk status
expect 3 'not a clean checkout' "steps refuse a modified checkout"
git -C "$REPO" checkout -q -- infra/local-talos/versions.json
git -C "$REPO" pull -q --ff-only origin main; blk status
expect 3 'not a clean checkout at the window SHA' "steps refuse a checkout moved off the window SHA"
git -C "$REPO" reset -q --hard "$SHA"
for f in t0 er0 ra0 s0; do echo 1 > "$ST/$f"; blk 0.0 "SHA=$SHA"
  expect 3 "earlier window \\( $f\\)" "0.0 refuses a stale $f alone"; rm "$ST/$f"; done
echo 1 > "$ST/t0"; blk 0.0 "SHA=$SHA; ARCHIVE=yes"; expect 0 'archived in' "0.0 with ARCHIVE=yes keeps the earlier window aside"
ls "$ST".archive/*/t0 >/dev/null 2>&1 && [ ! -e "$ST/t0" ] && pass "the archive holds the earlier T0" || fail "archive contents"

# ---- ops' credentials: named in the block, never inherited --------------------------------------------------
fresh; blk 4.2; expect 0 'exactly the 8' "a block reaches the cluster from a shell without credential variables"
CALLER_CREDS=1 blk 4.2; expect 0 'exactly the 8' "a block ignores credential variables the caller set elsewhere"
mk 4.2; sed -i '/^export KUBECONFIG=/d' "$WORK/b.cmd"; go
[ "$RC" != 0 ] && pass "mutation: without the block's export the stubbed tools refuse" || fail "mutation: export not needed?"
for f in kubeconfig talosconfig gcp.json; do
  fresh; rm "$STUB_OPS_RUN/$f"; blk 4.2
  hint="check ops-credentials\\.service"; [ "$f" = kubeconfig ] && hint="run ops-kubeconfig"
  expect 3 "REFUSED: no .*/$f: $hint\$" "a block refuses without ops' $f, naming its remedy"
  called 'talosctl|kubectl|terraform' && fail "a cluster tool ran without $f" || pass "no cluster tool runs without $f"
done
fresh; mkdir -p "$H/bin"; ln -sf "$HERE/stub" "$H/bin/hubble"
GO_PATH="$H/bin:$WORK/bin:$PATH" blk 0.1; expect 1 "hubble isn't the saved profile's" "0.1 fails when a tool resolves outside the profile"
rm -rf "${H:?}/bin"

# ---- the lock -------------------------------------------------------------------------------------------------
flock "$ST/lock" sleep 3 & sleep 0.5
blk status; expect 3 'another step is running' "an overlapping step is refused"; wait
blk status; expect 0 'window SHA' "the lock is released afterwards"
fresh; STUB_DAEMON='upgrade-k8s' blk 4.2
[ -n "$(alive)" ] && lock_free && pass "a process a step leaves behind doesn't hold the lock" || fail "lock held after the step"
mk 4.2; sed -i 's/ 9>&- 0<&0 & wait/ 0<\&0 \& wait/' "$WORK/b.cmd"; STUB_DAEMON='upgrade-k8s' go
lock_free && fail "mutation: without 9>&- the test still found the lock free" || pass "mutation: without 9>&- the lock is held"
for p in $(alive); do kill "$p"; done

# ---- cancellation: a TERM to the step's process group --------------------------------------------------------
cancel() {  # cancel SIGNAL NAME: run $WORK/b.cmd in its own session, signal it once a stub sleeps, check what's left
  local pid rc sig=$1; shift
  : > "$STUB_STATE/sleepers"; call
  (cd "$WORK" && caller setsid bash -c "$CALL" </dev/null >"$WORK/c.out" 2>&1) &
  pid=$!
  for _ in $(seq 100); do [ -s "$STUB_STATE/sleepers" ] && break; sleep 0.1; done
  sleep 0.5; kill "-$sig" -- "-$pid" 2>/dev/null; wait "$pid"; rc=$?; sleep 1
  [ "$rc" = 143 ] && pass "$1: exits 143" || fail "$1: exit $rc, not 143"
  [ -z "$(alive)" ] && pass "$1: no command outlives the cancelled step" || fail "$1: left running: $(alive)"
  held=$(holders "$WORK/c.out")
  [ -z "$held" ] && pass "$1: no process keeps the step's output open" || fail "$1: output held by $held"
  lock_free && pass "$1: the lock is free" || fail "$1: the lock is still held"
}
for sig in TERM INT HUP; do
  fresh; set_t0 '-30 min'; echo x > "$ST/allow"; mk 2.4
  STUB_SLEEP='cni-pods verify:30' cancel "$sig" "$sig to 2.4 mid-verify"
  fresh; blk 0.14 >/dev/null; mk 6c "COL=forward"
  STUB_SLEEP='hubble observe:30' cancel "$sig" "$sig to 6c mid-Hubble (port-forward running)"
done
fresh; blk 0.14 >/dev/null; blk 6c "COL=forward"
[ -z "$(alive)" ] && pass "6c's Hubble port-forward ends with the check" || fail "a port-forward outlived 6c"

# ---- stdin: no command can read the rest of the step -------------------------------------------------------
fresh; set_t0 '-30 min'; echo x > "$ST/allow"
STUB_EAT='cni-pods verify' STUB_FAIL='get deploy cilium-operator' blk 2.4
expect 1 'operator not 2/2' "a command reading stdin doesn't swallow 2.4's later checks"
STUB_EAT='logs probe-' STUB_FAIL='get deploy cilium-operator' blk 2.4
expect 1 'operator not 2/2' "a probe reading stdin doesn't swallow 2.4's verdict"
mk 2.4; sed -i -e '/^main() {$/d' -e '/^main <\/dev\/null$/d' "$WORK/b.cmd"; sed -i '$!N;/^}\nOP$/s/^}\n/\n/;P;D' "$WORK/b.cmd"
STUB_EAT='cni-pods verify' STUB_FAIL='get deploy cilium-operator' go
[ "$RC" = 0 ] && ! grep -q 'operator not' <<<"$OUT" && pass "mutation: without main </dev/null the script is swallowed" ||
  fail "mutation: the stdin test can't tell (exit $RC)"

# ---- apply, T0, the applied-node log ------------------------------------------------------------------------
fresh
for b in 2.0 2.1 2.3 2.3b; do blk "$b"; [ "$RC" = 3 ] && pass "$b refuses without T0" || fail "$b ran without T0 ($RC)"; done
blk 1.1 "N=c2"; expect 3 'apply c1 first' "apply c2 refuses before c1"
STUB_PLAN_EXTRA='module.cluster.talos_machine.worker["w1.k8s.kalski.xyz"]' blk 1.1 "N=c1"
expect 1 'STOP before T0' "a c1 plan with more than c1 stops before T0"
STUB_LIE='terraform -chdir=local-talos show' blk 1.1 "N=c1"; expect 1 "FAIL: reading c1's plan" "a failed plan read that printed c1's update stops"
STUB_GARBLE='terraform -chdir=local-talos show' blk 1.1 "N=c1"; expect 1 "FAIL: parsing c1's plan" "an unparsable plan stops"
[ ! -e "$ST/t0" ] && ! called ' apply ' && pass "no T0 and no apply without c1's exact plan" || fail "T0 or an apply on a bad plan"
blk 1.1 "N=c1"; expect 0 'applied c1' "apply c1 sets T0 and applies"
called 'terraform .* plan .*-var cni=cilium -target=module.cluster.talos_machine.controlplane\["c1.k8s.kalski.xyz"\] -out=' &&
  called 'terraform .* apply .*/c1.tfplan$' && pass "c1: a targeted -var cni=cilium plan, then that plan file" ||
  fail "apply c1's terraform calls"
t0=$(cat "$ST/t0"); blk 1.1 "N=c1"; [ "$(cat "$ST/t0")" = "$t0" ] && pass "applying c1 again keeps T0" || fail "T0 moved"
blk status; expect 0 '^Rollback A$' "only c1 attempted routes to A"
: > "$STUB_LOG"; STUB_LIE='terraform -chdir=local-talos show' blk A.1 "MODE=a"
expect 1 "FAIL: reading c1's plan" "rollback A stops on a failed plan read that printed c1's update"
called ' apply ' && fail "rollback A applied an unread plan" || pass "no rollback apply without a read plan"
blk 1.1 "N=w1"; expect 3 'control planes first' "workers wait for the control planes"
blk 1.1 "N=c2"; expect 0 'applied c2' "apply c2 after c1"
blk status; expect 0 '^Rollback B$' "an attempt beyond c1 routes to B"
blk A.1 "MODE=a"; expect 3 'calls for Rollback B' "rollback A refuses when the log calls for B"
STUB_NOCHANGE=c2 blk 1.1 "N=c2"; expect 0 'it had the config' "a node with the config isn't applied again"
STUB_APPLY_FAIL=c3 blk 1.1 "N=c3"; expect 1 'ROUTE: roll back by log: Rollback B' "a failed apply prints the rollback by log"
grep -q '^attempt c3 ' "$ST/applied" && ! grep -q '^applied c3 ' "$ST/applied" && pass "a failed apply stays an attempt" ||
  fail "applied-node log"

# ---- runbook deadlines and the 29-minute cap ----------------------------------------------------------------
fresh; set_t0 '-19 min'
blk 2.1; expect 124 'DEADLINE: recreation \(T0 \+ 18\) ended: not a failure' "recreate after T0 + 18 exits 124, go to M1"
called 'cni-pods recreate' && fail "recreate ran after T0 + 18" || pass "no recreation after T0 + 18"
fresh; set_t0 '-46 min'; echo x > "$ST/allow"; blk 2.4; expect 124 'DEADLINE: the M2 deadline' "m2 after T0 + 45 exits 124"
fresh; set_t0 '-17 min -50 sec'; blk 2.1; max=$(longest cni-pods)
[ -n "$max" ] && [ "$max" -le 70 ] && pass "recreate's commands end by T0 + 18 (longest $max s)" || fail "recreate's bound (${max:-none})"
fresh; set_t0 '-1 min'; CAP=5 blk 2.1; max=$(awk '$1 == "bounded" {print $2}' "$STUB_LOG" | sort -n | tail -1)
[ -n "$max" ] && [ "$max" -le 5 ] && pass "the cap bounds every command (longest $max s with a 5 s cap)" || fail "cap bound (${max:-none})"
fresh; set_t0 '-30 sec'; blk 2.0; max=$(longest kubectl)
[ -n "$max" ] && [ "$max" -le 240 ] && pass "remove-cni0 stays within its 4 minutes (longest $max s)" || fail "remove-cni0 bound"
fresh; set_t0 '-10 min'
blk 2.3b; expect 3 "2.3 hasn't passed" "m1-confirm needs 2.3 first"
blk 2.3; expect 0 'M1 OP checks passed' "2.3 passes OP's M1 checks"
blk 2.1 "MODE=post-m1"; expect 3 "M1 isn't confirmed" "recreate post-m1 refuses before 2.3b"
blk 2.3b; expect 0 'M1 passed' "2.3b records M1"
set_t0 '-25 min'; blk 2.1 "MODE=post-m1"; expect 0 'recreated' "recreate post-m1 continues after minute 18"
set_t0 '-46 min'; blk 2.1 "MODE=post-m1"; expect 124 'DEADLINE: T0 \+ 45 passed' "recreate post-m1 exits 124 after minute 45"
fresh; set_t0 '-21 min'; date +%s > "$ST/m1op"; blk 2.3b; expect 124 'M1 \(T0 \+ 20\) passed' "a confirmation after T0 + 20 is a missed M1"
fresh; echo "attempt c2 x" > "$ST/applied"
CAP=6 STUB_SLEEP='controlplane["c2:10' blk A.1 "MODE=b"; expect 125 'STEP CAP: run this again' "a cap hit midway through rollback B says rerun"
refute "$TERMINAL" "a capped rollback B prints no E1 or STOP"
CAP=4 STUB_SLEEP='verify -cni flannel:10' blk A.7a; expect 125 'STEP CAP' "a cap hit in rollback-verify says rerun"
refute "$TERMINAL" "a capped rollback-verify prints no STOP"
fresh; blk 0.14 >/dev/null; date -d '-59 min -54 sec' +%s > "$ST/ra0"
CAP=20 STUB_SLEEP='canary-:10' blk 6a "COL=rollback"
expect 124 "DEADLINE: rollback acceptance's 60 min ended" "a runbook deadline before the cap exits 124"
fresh; CAP=3 STUB_SLEEP='cni-pods plan:6' blk 0.1; expect 125 'STEP CAP' "a preflight whose last check runs over the cap exits 125"
refute '^preflight passed' "a capped preflight claims nothing"
fresh; set_t0 '-30 min'; echo x > "$ST/allow"
CAP=3 STUB_SLEEP='cni-pods endpoints:6' blk EO.1 "START=fresh"; expect 125 'STEP CAP' "a capture over the cap exits 125"
refute '^captured in' "a capped capture claims nothing"
fresh; CAP=3 STUB_NIX_DELAY=4 blk 0.1; expect 125 'STEP CAP' "the cap's clock starts before Nix: a slow start counts"
called 'terraform' && fail "the preflight ran commands after its cap" || pass "nothing runs after a cap spent starting Nix"

# ---- the preflight's plan check -----------------------------------------------------------------------------
fresh; blk 0.1; expect 0 'preflight passed' "preflight accepts the five CNI updates"
plan_json $'---\napiVersion: v1alpha1\nkind: EthernetConfig\nname: end0\n' > "$STUB_DIR/cilium.tfplan.json"
blk 0.1; expect 1 'changes more than CNI, proxy, Cilium' "preflight refuses any other change"
plan_json "" > "$STUB_DIR/cilium.tfplan.json"
STUB_LIE='show -json' blk 0.1; expect 1 'FAIL: reading the plan' "preflight stops on a failed plan read that printed a good plan"
STUB_GARBLE='show -json' blk 0.1; expect 1 'FAIL: parsing the plan' "preflight stops on an unparsable plan"

# ---- reads must succeed and parse ---------------------------------------------------------------------------
fresh
STUB_FAIL='logs cni-repair-' blk 5.4; expect 1 "couldn't be inspected" "5.4 fails when the CNI inspection fails"
STUB_LIE='logs cni-repair-' blk 5.4; expect 1 "couldn't be inspected" "5.4 fails on a failed inspection that printed a clean one"
STUB_EMPTY='logs cni-repair-' blk 5.4; expect 1 "couldn't be inspected" "5.4 fails on an empty inspection"
STUB_FAIL='get links' blk 5.4; expect 1 "links couldn't be read" "5.4 fails when the links can't be read"
STUB_LIE='get links' blk 5.4; expect 1 "links couldn't be read" "5.4 fails on a failed link read that printed a clean listing"
STUB_EMPTY='get links' blk 5.4; expect 1 "link listing is empty" "5.4 fails on an empty link listing"
STUB_LIE='cilium-dbg status --brief' blk 5.4; expect 1 '' "5.4 fails when an agent's status read fails after printing OK"
STUB_GARBLE='get vmi' blk 0.14; expect 1 'parsing the VMs' "0.14 fails on an unparsable VM list"
STUB_EMPTY='get vmi' blk 0.14; expect 1 'parsing the VMs' "0.14 fails on an empty VM read, not an empty baseline"
[ ! -e "$ST/vmi" ] && pass "no VM baseline from a failed parse" || fail "an empty VM baseline was saved"
blk 6c; expect 1 'FAIL T10: no VM list from 0.14' "T10 fails without 0.14's list"
blk 0.14 >/dev/null
STUB_FAIL='logs deploy/external-dns-stationary' blk 6c; expect 1 'FAIL T11' "T11 fails when a log can't be read"
STUB_FAIL='get vmi' blk 6c; expect 1 'FAIL T10' "T10 fails without its VM read"
STUB_GARBLE='get vmi' blk 6c; expect 1 'FAIL T10' "T10 fails on an unparsable VM read"
STUB_EMPTY='get vmi' blk 6c; expect 1 'FAIL T10' "T10 fails on an empty VM read"
STUB_VMI_PHASE=Paused blk 6c; expect 1 'FAIL T10' "T10 fails when a VM's phase changed"
STUB_FAIL='get apiservices' blk 6c; expect 1 'FAIL T9' "T9 fails without its read"
STUB_GARBLE='get apiservices' blk 6c; expect 1 'FAIL T9' "T9 fails on unparsable JSON"
STUB_EMPTY='get apiservices' blk 6c; expect 1 'FAIL T9' "T9 fails on an empty read"
STUB_LIE='get apiservices' blk 6c; expect 1 'FAIL T9' "T9 fails on a failed read that printed a healthy list"
STUB_LIE='logs sandbox-probe-' blk 6b; expect 1 'FAIL T7' "T7 fails on a failed log read that printed the expected lines"
STUB_GARBLE='get nodes -o json' blk A.4 2>/dev/null; STUB_PRUNE=rollback STUB_GARBLE='get nodes -o json' blk A.4
expect 1 'parsing the nodes' "A.4 fails on an unparsable node list"
STUB_FAIL='get kustomizations' blk 0.14; expect 1 'reading the Kustomizations' "0.14 fails without the listing"
CAP=8 STUB_FLUX_NOT_READY=1 blk T12; expect 125 'STEP CAP' "T12 never passes while a Kustomization isn't Ready"
CAP=8 STUB_FLUX_NOT_READY=1 STUB_FAIL_AFTER='get kustomizations:2' blk T12; expect 125 'STEP CAP' "T12 never passes when later listings fail"
refute '^every Kustomization Ready' "T12 claims nothing on failed listings"
CAP=20 STUB_FLANNEL_NOT_READY=1 blk A.6b "N=w2"; expect 125 'STEP CAP' "A.6b never passes until the node's kube-flannel is Ready"
refute 'kube-flannel Ready' "A.6b claims nothing while kube-flannel isn't Ready"

# ---- E5 and reboots -----------------------------------------------------------------------------------------
fresh
STUB_FAIL=kubectl blk E5 "N=c2"; expect 0 'c2 rebooted \(boot ID boot-1\)' "E5 works with the Kubernetes API down"
called ' kubectl ' && fail "E5 called kubectl" || pass "E5 makes no Kubernetes call"
grep 'etcd status' "$STUB_LOG" | grep -q '10.10.10.11,10.10.10.13' && pass "E5 asks the other two members" || fail "E5's etcd check"
: > "$STUB_LOG"; STUB_FAIL='etcd status' blk E5 "N=c2"; expect 1 "STOP: the other two etcd members" "E5 refuses without two healthy members"
called ' reboot ' && fail "E5 rebooted without healthy survivors" || pass "no reboot without healthy survivors"
fresh; CAP=3 STUB_SLEEP='reboot --wait:10' blk E5 "N=c2"; expect 125 'STEP CAP' "a cap during E5 exits 125"
refute "$TERMINAL" "a capped E5 claims nothing terminal"
fresh; CAP=3 STUB_SLEEP='reboot --wait:10' blk 5.3 "N=w1"
expect 125 'STEP CAP: the reboot of w1 may have started' "a cap during a reboot says check the boot ID, never reboot again"
refute "$TERMINAL" "a capped reboot claims nothing terminal"

# ---- PoE: 0.8's read-only port check and E2's power cycle -----------------------------------------------------
fresh; rm "$STUB_OPS_RUN/routeros.netrc"; blk 0.8; expect 0 'PoE ports match' "0.8 runs ops-routeros and matches the ports"
called 'script/run' && fail "0.8 cycled a port" || pass "0.8 cycles nothing"
STUB_POE_SWAP=1 blk 0.8; expect 1 "FAIL: c1's D8:3A:DD:D2:F1:EB isn't on ether4 alone" "0.8 fails when a Pi isn't on its port"
STUB_POE_SCRIPT=1 blk 0.8; expect 1 "ops-poe-cycle-c1 doesn't cycle ether4 alone" "0.8 fails on a script cycling another port"
STUB_POE_OFF=1 blk 0.8; expect 1 "FAIL: ether4 is 'powered-off'" "0.8 fails on an unpowered port"
STUB_GARBLE=bridge/host blk 0.8; expect 1 'FAIL: reading the bridge hosts' "0.8 fails on an unparsable bridge-host read"
STUB_FAIL=ops-routeros blk 0.8; expect 1 "ops-routeros didn't write" "0.8 fails when ops-routeros does"
fresh; rm "$STUB_OPS_RUN/routeros.netrc"; STUB_FAIL='-n 10.10.10.11 version' blk E2 "N=c1"
expect 3 'REFUSED: no .*/routeros.netrc: run ops-routeros' "E2 refuses without the RouterOS netrc"
ops_files; blk E2 "N=c1"; expect 1 "ROUTE: c1's Talos API answers: not E2" "E2 refuses a Pi whose Talos API answers"
STUB_FAIL='etcd status' blk E2 "N=c1"; expect 1 'STOP: the other two etcd members' "E2 refuses without two healthy members"
STUB_FAIL='-n 10.10.10.11 version' STUB_POE_OFF=1 blk E2 "N=c1"; expect 1 'STOP: ether4 is powered-off' "E2 stops on an unpowered port"
STUB_FAIL='-n 10.10.10.11 version' STUB_GARBLE=poe/monitor blk E2 "N=c1"; expect 1 "STOP: can't read ether4" "E2 stops on an unread port"
called 'script/run' && fail "E2 cycled a port it refused" || pass "no cycle when E2 refuses"
STUB_FAIL='-n 10.10.10.11 version' blk E2 "N=c1"; expect 0 'c1 power-cycled and back \(boot ID boot-0\)' "E2 cycles c1 and waits for it"
grep 'script/run' "$STUB_LOG" | grep -qF '"ops-poe-cycle-c1"' && pass "E2 runs c1's script" || fail "E2's script"
grep 'etcd status' "$STUB_LOG" | grep -q '10.10.10.12,10.10.10.13' && pass "E2 asks the other two members" || fail "E2's etcd check"
STUB_FAIL='-n 10.10.10.11 version' blk E2 "N=c1"; expect 1 'STOP: c1 was power-cycled in this window already' "E2 refuses a second cycle"
[ "$(wc -l < "$STUB_STATE/poe-cycles")" = 1 ] && pass "c1 was cycled once" || fail "c1 cycled more than once"
STUB_FAIL='-n 10.10.10.12 version' blk E2 "N=c2"; expect 0 'c2 power-cycled' "E2 cycles another Pi in the same window"
fresh; POE_WAIT=3 STUB_FAIL='-n 10.10.10.11 version' STUB_EMPTY=boot_id blk E2 "N=c1"
expect 1 "STOP: c1's Talos API isn't back 10 min after its cycle" "E2 stops when the Pi doesn't come back"
fresh; CAP=3 STUB_FAIL='-n 10.10.10.11 version' STUB_SLEEP='script/run:10' blk E2 "N=c1"
expect 125 "STEP CAP: c1's PoE cycle may have run: never cycle it again" "a cap during E2 says never cycle again"
refute "$TERMINAL" "a capped E2 claims nothing terminal"

# ---- endpoint episodes --------------------------------------------------------------------------------------
fresh; set_t0 '-30 min'; echo x > "$ST/allow"
blk EO.1 "START=again"; expect 3 'no endpoint episode' "a capture needs an episode"
blk EO.1 "START=fresh"; expect 0 'captured in' "START=fresh begins an episode"
er0=$(cat "$ST/er0"); sleep 1; blk EO.1 "START=again"; expect 0 'captured in' "START=again captures again"
[ "$(cat "$ST/er0")" = "$er0" ] && pass "another capture keeps the episode's start" || fail "a capture moved the start"
date -d '-20 min' +%s > "$ST/er0"; er0=$(cat "$ST/er0")
blk EO.1 "START=again"; expect 0 'for the record only' "after the budget, a capture still records evidence"
[ "$(cat "$ST/er0")" = "$er0" ] && pass "the ended budget stays ended" || fail "a capture after expiry reset the budget"
blk EO.3 "CEP=app/web-0"; expect 124 'DEADLINE: the episode' "EO.3 exits 124 after the budget"
blk EO.4; expect 124 'DEADLINE: the episode' "EO.4 exits 124 after the budget"
fresh; echo fresh > "$ST/eb"; date +%s > "$ST/er0"; echo x > "$ST/allow"
CAP=2 STUB_FAIL='get pods -l k8s-app=cilium -o name' blk EO.4; expect 125 'STEP CAP' "converge waiting into the cap exits 125"
refute "$TERMINAL" "a capped converge prints no route"
fresh; echo fresh > "$ST/eb"; date -d '+5 min' +%s > "$ST/er0"; echo x > "$ST/allow"
CONVERGE=20 STUB_FAIL='get pods -l k8s-app=cilium -o name' blk EO.4
expect 1 'ROUTE: terminal' "converge's own window ends in the terminal verdict"
fresh; echo fresh > "$ST/eb"; date +%s > "$ST/er0"; echo x > "$ST/allow"
CONVERGE=12 STUB_SLEEP='cilium-dbg status --brief:4' blk EO.4
expect 1 'ROUTE: terminal' "converge with slow reads ends at its window"
refute '^recovered' "converge accepts nothing after its window"
fresh; echo m2 > "$ST/eb"; blk EO.4; expect 3 'no endpoint episode' "an episode needs its saved start (no T0)"
fresh; set_t0 '-30 min'; echo x > "$ST/allow"
STUB_CEP_ERR=1 blk EO.1 "START=m2"; expect 0 '123 on cilium-a: app/web LOST CREATE' "EO.1 classifies a lost create"
for src in 'cilium-dbg endpoint list' 'get pods -A -o json' 'get ciliumendpoints.cilium.io' 'cilium-dbg status --verbose'; do
  STUB_CEP_ERR=1 STUB_LIE="$src" blk EO.1 "START=again"
  expect 0 'UNCLASSIFIED' "EO.1 marks endpoints unclassified when '$src' fails after printing good data"
  refute 'LOST CREATE|STALE CEP' "EO.1 classifies nothing from a failed '$src'"
  ls "$ST"/diag-*/*.failed >/dev/null 2>&1 && pass "EO.1 keeps the failed '$src' capture, marked .failed" ||
    fail "no .failed capture for '$src'"
  rm -rf "$ST"/diag-*
done

# ---- every block's happy path, every cluster command bounded ------------------------------------------------
fresh
run() { local want=$1 pat=$2; shift 2; blk "$@"; expect "$want" "$pat" "happy path: $*"; }
run 0 'preflight passed' 0.1
run 0 'PoE ports match' 0.8
run 0 'suspended' 0.14
for b in 6a 6b 6c; do run 0 '^accepted' "$b" "COL=baseline"; done
run 0 'applied c1' 1.1 "N=c1"
run 0 'verified: no cni0' 2.0
run 0 'ALLOW=pocket-id/pocket-id-sync-x' 2.1
run 0 'M1 OP checks passed' 2.3
run 0 'M1 passed' 2.3b
rm -rf "$STUB_STATE/created"; run 0 'M2 passed' 2.4
n=0; for f in "$STUB_STATE"/created/*.yaml; do
  yq -e '.kind == "Pod" and .spec.nodeName != null and (.spec.containers[0].command[2] | test("nslookup .*nc -w 3 -z 10.244.1.9 80"))' \
    "$f" >/dev/null && n=$((n + 1)); done
[ "$n" = 5 ] && pass "2.4 creates five probe Pods, each pinned to its node with its whole command" || fail "probe manifests ($n of 5)"
run 0 'captured in' EO.1 "START=m2"
run 0 'cleared' EO.3 "CEP=app/web-0"
run 0 'recreated' EO.3a "POD=app/web-0"
run 0 'recovered' EO.4
for n in c2 c3 w1 w2; do blk 1.1 "N=$n"; done
run 0 'exactly the 8' 4.2
run 0 'pruned' 4.3
run 0 'verified: no cni0' 2.0 "ACTION=flannel1"
run 0 'M2 passed' 2.4 "MODE=prune"
run 0 'forfeited' 5.1 "N=c2"
run 0 'w1 rebooted' 5.3 "N=w1"
run 0 'w1 clean' 5.4 "N=w1"
rm -rf "$STUB_STATE/created"; run 0 '^accepted' 6b "COL=forward"
f=$(grep -l 'sandbox-probe-' "$STUB_STATE"/created/*.yaml)
yq -e '.kind == "Pod" and .spec.securityContext.runAsNonRoot and
  (.spec.containers[0].command[2] | test("nc -w 2 -z 192.168.100.1 80")) and
  (.spec.containers[0].command[2] | test("nc -w 2 -z 10.96.0.10 53"))' "$f" >/dev/null &&
  pass "T7's sandbox Pod keeps its command and Restricted settings" || fail "T7's manifest"
for b in 6a 6c; do run 0 '^accepted' "$b" "COL=forward"; done
run 0 'every Kustomization Ready' T12
STUB_PRUNE=rollback run 0 'Cilium pruned' A.4
run 0 'w2 rebooted' 5.3 "N=w2"
run 0 'w2 kube-flannel Ready' A.6b "N=w2"
run 0 'after:' A.6 "N=w2"
run 0 'rollback verified' A.7a
for b in 6a 6b 6c; do run 0 '^accepted' "$b" "COL=rollback"; done
run 0 'no changes' plain-plan
run 0 'c2 rebooted' E5 "N=c2"
STUB_FAIL='-n 10.10.10.11 version' run 0 'c1 power-cycled and back' E2 "N=c1"
run 0 'Rollback' status
cat "$STUB_LOG" >> "$WORK/all.log"; : > "$STUB_LOG"
run 0 'rollback b applied' A.1 "MODE=b"
plans=$(grep -cE 'terraform .* plan .*-var cni=flannel -target=' "$STUB_LOG")
applies=$(grep -cE 'terraform .* apply .*\.tfplan$' "$STUB_LOG")
[ "$plans" = 5 ] && [ "$applies" = 5 ] && ! called 'cni=cilium' &&
  pass "rollback B plans each node with -var cni=flannel and applies those plans" || fail "rollback B ($plans plans, $applies applies)"
cat "$STUB_LOG" >> "$WORK/all.log"
grep -E ' kubectl run ' "$WORK/all.log" && fail "a block uses kubectl run" || pass "no block uses kubectl run"
grep UNBOUNDED "$WORK/all.log" | grep -v ' nix ' > "$WORK/unbounded"
[ -s "$WORK/unbounded" ] && { fail "cluster commands ran without a bound:"; sort -u "$WORK/unbounded" | sed 's/^/     /' | head -20; } ||
  pass "every cluster command in every block ran under a bound"
missing=$(cd "$BLK" && for f in *.cmd; do grep -qxF "${f%.cmd}" "$WORK/ran" || echo "${f%.cmd}"; done)
[ -z "$missing" ] && pass "every block in the runbook was run" || fail "blocks never run: $missing"

echo; [ $FAILURES = 0 ] && echo "all tests passed" || { echo "$FAILURES failed"; exit 1; }
