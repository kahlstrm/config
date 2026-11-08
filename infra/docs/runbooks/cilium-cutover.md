# Cilium cutover runbook

The runbook for moving klusse from Flannel to Talos-owned Cilium (#228). It is committed so the window SHA pins its operator blocks with the code they run against. Delete it once the migration is done and the window's evidence has been kept.

The cutover PR (#228) makes `cilium` the default of `local-talos`' `cni` variable and merges only after M3, before anyone runs a plain `terraform plan` or `apply`. Until then, the window applies `-var cni=cilium` per node, and a rollback `-var cni=flannel`.

**After M3:** merge #228. Ops fast-forwards its checkout and runs 0.0 again with the new SHA and `ARCHIVE=yes`, then the plain-plan block: with `cilium` now the default, a plain plan shows no changes. This is the only time the window SHA changes.

Evidence: ADR 11 and the Talos lab (#219, #220, #229, #231, #242).

## Before the window

- #267, #268 and #269 are merged; `agent-deploy` has run on ops; the user has deployed pannu (#268).
- An ops check passes from a delegated ops task: `ops-kubeconfig`; `kubectl auth can-i '*' '*' -A` prints `yes`; `curl -sk -o /dev/null -w '%{http_code}\n' https://10.10.10.80/` prints a code.
- `ops-kubeconfig` has run on ops since its last reboot: it writes `/run/ops-credentials/kubeconfig`, and a reboot clears `/run`. After any ops reboot, run it again before the next block, and block 0.8 (or `ops-routeros`) before E2, which needs `/run/ops-credentials/routeros.netrc`.
- 0.0 has run, then 0.1–0.15. No pannu deploy, ops VM setup or `git pull` during the window.

## Roles, risk, conventions

- **OP**: one delegated ops thread for the whole window: T3 `delegate_task` to the linked `ops` environment, Claude Code at `approval-required`.
  - Each OP step is **one Bash call**: the block below, copied literally from this file at the window SHA and sent whole, so the phone approval shows every command that runs. There is no script, no sourced file and no hidden function. Edit only the `# parameters` line.
  - Its first line makes any cancellation exit 143; its next refuses unless `~/cutover/dev-profile` still resolves to the store path 0.0 recorded.
  - It then starts the block's clock (`CUTOVER_START`), before Nix starts, and runs the body with `env -u BASH_ENV nix develop <that store path> --offline --command env -u BASH_ENV bash --noprofile --norc -s`.
    - **What Nix does here:** it builds, fetches and evaluates no flake. It does generate a startup script from the saved environment and run its `shellHook` (empty for `.#cutover`). It runs that script with an interactive bash it looks up as `nixpkgs#bashInteractive` through the flake registry (offline, only from what is already in the store), falling back to `bash` on PATH. The startup script then runs the command.
    - The step's own shell is the `bash` first on the saved environment's PATH, started without profile, rc files or `BASH_ENV`, so only the block's text adds code. Its tools are those 0.0 saved from the window SHA: Nix puts the profile first on PATH, and 0.1 checks that none of the cluster tools resolve outside it. `ops-kubeconfig` and `ops-routeros` are the only commands from ops' own system.
  - **Credentials are named in the block, never inherited.** Each block with a deadline sets `KUBECONFIG`, `TALOSCONFIG` and `GOOGLE_APPLICATION_CREDENTIALS` to ops' files in `/run/ops-credentials` itself. It refuses (exit 3) when one can't be read: the kubeconfig needs `ops-kubeconfig` after every ops reboot, and the other two come from `ops-credentials.service` at boot. So it doesn't matter whether T3's tool shell has these variables.
  - The body runs inside `main () { … }; main </dev/null`, so no command can read the rest of the script from stdin.
  - Its opening lines refuse (exit 3) unless the checkout is clean and at the window SHA 0.0 recorded (no fetch), and unless no other step runs (`flock` on `~/cutover/lock`).
  - Every cluster command runs in the background of the step's shell, which waits for it, without the lock's descriptor. Nothing a command leaves behind holds the lock, and cancelling a step (TERM, INT or HUP; exit 143) kills its running commands, including Hubble's port-forward.
  - Separate calls share nothing but files in `~/cutover`: `window-sha`, `profile-path`, `t0` (epoch), `applied` (the applied-node log), `log`, `allow`, `m1op`/`m1`, `eb`/`er0`, `s0`, `ra0`, `vmi`, plan files and diagnostics.
- **Deadlines.**
  - Every block but the read-only status block runs every command under `w`, within the earlier of its runbook deadline `R` and 29 minutes from `CUTOVER_START` (ops ends a command after 30). Which of the two binds is fixed when the block starts, so a later cleanup can't change the verdict.
  - Exit 124: the runbook deadline passed, and the block prints the action this runbook names. Exit 125: the 29 minutes ran out; run the same block again, unless it says otherwise (after a reboot it says to check the boot ID). A capped block prints no route and no terminal claim.
  - A block succeeds only before its end, so a final check over time still returns 124 or 125.
  - A block's own waits end in a verdict, exit 1 with this runbook's route: the reboot's 15 minutes, the 10-minute waits for kube-flannel and Flux, and converge's two minutes. Each read inside such a wait is bounded by it, and nothing read after it ended is accepted.
  - **Reads:** every read's exit status is checked, and its output parsed, before its content counts.
  - **Other exit codes:** 0 done; 1 failed (follow the printed `ROUTE:` or `STOP:`); 2 a bad parameter; 3 refused; 143 cancelled, by TERM, INT or HUP alike: as 125, but after 5.3 or E5 check the boot ID before anything else.
  - **Exception to infra/AGENTS.md's "delegate one node per task and verify each from the agents VM before the next".** The steps run against absolute deadlines from T0 (M1 by T0 + 20) and share `~/cutover`; a delegation per node would add round trips and lose context mid-outage. Applies stay one node at a time, each from a targeted plan file that must update exactly that node, and the VM still gates between nodes.
- **Approval latency counts.** Deadlines run from T0 while a prompt waits on the phone; a late approval can make a block exit 124.
- **USER**: UART (0.7, E1), T2's browser login, T3's Harbor push and pull (ops has no Harbor or Docker credentials; block 6a checks Harbor over HTTPS), T5's Docsight view and T13's Prometheus targets.
- **VM**: the agent VM: read-only kubectl and an `os:reader` talosconfig; it reaches only the API VIP (:6443) and the Talos APIs (:50000). Its `cni-pods plan|verify` are diagnostic, never a gate. It sets the same `T0` OP posts.
- **Risk acceptance**: production is the first hardware to run Cilium's arm64 datapath on the Pi 5's `macb` NIC (`end0`), which logs TX-stall re-kicks under Flannel; the lab can't model it. Starting the window accepts that, with the user present and recovery access verified in step 0. Recovery beyond one power cycle is not in this runbook: those cases **STOP** for the user (Escalation).
- **Applied nodes**: block 1.1 logs `attempt <node>` in `~/cutover/applied` before each apply and `applied <node>` after. Talos may accept a config even when Terraform times out, so an attempt counts as a possible change.
  - "Roll back (by log)": Rollback A only when the log shows c1 alone attempted; anything else, or no log, means Rollback B. B reapplies Flannel everywhere, a no-op where nothing changed.
  - No read of node state overrides the log. The status block prints the rollback the log calls for.
- **Default**: any failure this runbook doesn't classify is a STOP.

### VM helpers (from `infra/` at the window SHA, in bash inside `nix develop`)

Read-only, checked against production on 2026-10-30:
- the Flannel gate passes and the Cilium gate fails;
- a missing manifest, an unreachable node and a failed `dmesg` each fail with a reason;
- `stalls_since` gave 19, 38 and 28 TX stalls in an hour on c1–c3, before c2's offload trial.

The VM's `T0` is the UTC time OP posts.

```sh
set -o pipefail
CPS=10.10.10.11,10.10.10.12,10.10.10.13; NODES=$CPS,10.10.10.21,10.10.10.22
TV=$(jq -r .kubernetes local-talos/versions.json)    # Kubernetes version (1.37.1 today)
t0s() { date -d "${T0}Z" +%s; }                     # T0 in epoch seconds
left() { echo $(( $(t0s) + $1 * 60 - $(date +%s) )); }   # seconds until T0 + $1 minutes (≤ 0: past)
# within_base BASE MINUTES CMD...: run CMD bounded by the time left until BASE (UTC, no Z) + MINUTES.
# Refuses (exit 124) when no time is left, as `timeout 0` would disable the limit and a negative one is
# invalid; exit 124 means the deadline.
within_base() {
  local s=$(( $(date -d "${1}Z" +%s) + $2 * 60 - $(date +%s) )); shift 2
  if [ "$s" -le 0 ]; then echo "DEADLINE PASSED: not running: $*" >&2; return 124; fi
  timeout "$s" "$@"; local rc=$?
  [ $rc = 124 ] && echo "DEADLINE REACHED: interrupted: $*" >&2
  return $rc
}
within() { within_base "$T0" "$@"; }                 # forward deadlines, from T0
now() { date -u +%Y-%m-%dT%H:%M:%S; }
ip_of() { case $1 in c1) echo 10.10.10.11;; c2) echo 10.10.10.12;; c3) echo 10.10.10.13;; w1) echo 10.10.10.21;; w2) echo 10.10.10.22;; *) return 1;; esac; }
# manifest_hash NODE ID: hash of exactly one non-null Talos manifest body; fails, saying why, otherwise.
manifest_hash() {
  local out n
  out=$(talosctl -n "$1" get manifests "$2" -o json 2>&1) || { echo "$1 $2: READ FAILED: $out" >&2; return 1; }
  n=$(printf '%s' "$out" | jq -s 'length' 2>/dev/null) || { echo "$1 $2: INVALID JSON" >&2; return 1; }
  [ "$n" = 1 ] || { echo "$1 $2: expected 1 resource, got $n" >&2; return 1; }
  printf '%s' "$out" | jq -e '.spec != null and .spec != {}' >/dev/null || { echo "$1 $2: NULL BODY" >&2; return 1; }
  printf '%s' "$out" | jq -cS .spec | sha256sum | cut -d' ' -f1
}
manifest_ids() {
  local out
  out=$(talosctl -n "$1" get manifests -o json 2>&1) || { echo "$1: READ FAILED: $out" >&2; return 1; }
  printf '%s' "$out" | jq -er .metadata.id || { echo "$1: INVALID JSON" >&2; return 1; }
}
# cni_gate cilium|flannel: every CP renders that CNI's manifests, none of the other's, identically. Prints GATE PASS, or GATE FAILED and returns 1.
cni_gate() {
  local want other ids h first="" n id
  if [ "$1" = cilium ]; then want="99-cilium"; other="05-flannel 10-kube-proxy"; else want="05-flannel 10-kube-proxy"; other="99-cilium"; fi
  for n in 11 12 13; do
    ids=$(manifest_ids 10.10.10.$n) || { echo "GATE FAILED"; return 1; }
    for id in $want; do grep -qx "$id" <<<"$ids" || { echo "GATE FAILED: 10.10.10.$n lacks $id"; return 1; }; done
    for id in $other; do grep -qx "$id" <<<"$ids" && { echo "GATE FAILED: 10.10.10.$n still has $id"; return 1; }; done
    h=$(for id in $want; do manifest_hash 10.10.10.$n "$id" || exit 1; done) || { echo "GATE FAILED"; return 1; }
    [ -z "$first" ] && first=$h
    [ "$h" = "$first" ] || { echo "GATE FAILED: 10.10.10.$n renders a different $want"; return 1; }
  done
  echo "GATE PASS ($1)"
}
# dmesg_read NODE: the kernel log, retried once after 30 s; fails unless the read succeeds and has timestamped lines.
dmesg_read() {
  local out try
  for try in 1 2; do
    if out=$(talosctl -n "$1" dmesg 2>&1) && grep -qE '\[[0-9]{4}-[0-9T:.-]+Z\]' <<<"$out"; then printf '%s\n' "$out"; return 0; fi
    [ $try = 1 ] && sleep 30
  done
  echo "$1: dmesg READ FAILED" >&2; return 1
}
# count_since PATTERN SINCE < log: lines matching PATTERN stamped at or after SINCE (UTC, without Z).
count_since() { awk -v s="$2" -v p="$1" '$0 ~ p { if (match($0, /\[[0-9T:.-]+Z\]/)) { t = substr($0, RSTART + 1, RLENGTH - 3); if (t >= s) c++ } } END { print c + 0 }'; }
stalls_since() { local d; d=$(dmesg_read "$1") || return 1; count_since 'TX stall detected' "$2" <<<"$d"; }
# api_watch MINUTES: exit 0 once the API answered 120 s straight, 1 if not by now + MINUTES.
api_watch() {
  local deadline=$(( $(date +%s) + $1 * 60 )) up= now
  while :; do now=$(date +%s)
    if kubectl get --raw /readyz --request-timeout=2s >/dev/null 2>&1; then up=${up:-$now}; else up=; fi
    if [ -n "$up" ] && [ $((now-up)) -ge 120 ]; then echo "API STABLE"; return 0; fi
    if [ "$now" -ge "$deadline" ]; then echo "API ABORT: not up 120 s straight within $1 min"; return 1; fi
    sleep 2; done
}
# etcd_ok: exactly 3 member rows, one leader, no errors.
etcd_ok() {
  local out
  out=$(talosctl -n $CPS etcd status 2>&1) || { echo "etcd READ FAILED: $out"; return 1; }
  awk 'NR>1 && NF {rows++; if ($NF !~ /^[0-9.]+$/) bad++} END {exit !(rows==3 && !bad)}' <<<"$out" || { echo "etcd UNHEALTHY:"; echo "$out"; return 1; }
  [ "$(awk 'NR>1 && NF {print $(NF-6)}' <<<"$out" | sort -u | wc -l)" = 1 ] || { echo "etcd: members disagree on the leader"; return 1; }
  echo "etcd OK"
}
# etcd_two_ok IP1 IP2: the two surviving members both answer without errors and agree on one leader that is
# one of them; up to 3 tries over 90 s. Membership (`etcd members`) is never taken as health.
etcd_two_ok() {
  local out try ids leaders
  for try in 1 2 3; do
    if out=$(timeout 30 talosctl -n "$1,$2" etcd status 2>&1); then
      ids=$(awk 'NR>1 && NF {print $2}' <<<"$out" | sort -u)
      leaders=$(awk 'NR>1 && NF {print $(NF-6)}' <<<"$out" | sort -u)
      if [ "$(awk 'NR>1 && NF' <<<"$out" | wc -l)" = 2 ] && awk 'NR>1 && NF {if ($NF !~ /^[0-9.]+$/) bad++} END {exit bad}' <<<"$out" &&
         [ "$(wc -l <<<"$leaders")" = 1 ] && [ "$leaders" != 0000000000000000 ] && grep -qx "$leaders" <<<"$ids"; then
        echo "etcd two survivors OK, leader $leaders"; return 0
      fi
    fi
    [ $try -lt 3 ] && sleep 30
  done
  echo "etcd two survivors NOT OK:"; echo "$out"; return 1
}
```

## 0. Before T0

**0.A Separate change: done.** Ops applied it on 2026-11-01, about 18:18–18:33Z: c2's EthernetConfig, the worker image without the gVisor extension (#167, pulled in by `-target`), and removal of w1's and w2's `orb-storage` volumes. A full plain plan then showed no changes.

**0.0 Pin the window** (OP, once, with #228's predecessors merged). It fetches and builds, the only step that does. It saves the `.#cutover` shell as a GC-rooted profile and records its store path and the SHA.

```sh
trap 'exit 143' TERM INT HUP   # a cancelled step exits 143
bash -s <<'OP'
# 0.0 init · OP · before T0; SHA = the approved main commit · expect: "window SHA <sha>"
main() {
SHA=0000000000000000000000000000000000000000; ARCHIVE=no   # parameters
set -uo pipefail; S=~/cutover; mkdir -p "$S" && chmod 700 "$S" || exit 3
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no checkout"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP; x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
[ -z "$(git status --porcelain)" ] || { echo "REFUSED: local changes"; exit 3; }
if ! { x 60 git fetch -q origin main && [ "$(git rev-parse HEAD)" = "$SHA" ] &&
  git merge-base --is-ancestor "$SHA" origin/main; }; then echo "REFUSED: HEAD is not $SHA on origin/main"; exit 3; fi
stale=; for f in t0 ra0 er0 s0; do [ -e "$S/$f" ] && stale="$stale $f"; done
[ -z "$stale" ] || [ "$ARCHIVE" = yes ] || { echo "REFUSED: $S holds an earlier window ($stale); ARCHIVE=yes"; exit 3; }
if [ -n "$(find "$S" -mindepth 1 -maxdepth 1 ! -name lock)" ]; then A=$S.archive/$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$A" && find "$S" -mindepth 1 -maxdepth 1 ! -name lock -exec mv -t "$A" {} + && echo "archived in $A"; fi
x 1500 nix develop --profile "$S/dev-profile" .#cutover --command true || { echo "FAIL: saving the shell"; exit 1; }
p=$(readlink -f "$S/dev-profile") && [[ $p == /nix/store/* ]] || { echo "FAIL: no saved profile"; exit 1; }
echo "$p" > "$S/profile-path" && echo "$SHA" > "$S/window-sha" &&
  echo "$(date -u +%FT%TZ) init $SHA $p" >> "$S/log" && echo "window SHA $SHA" || exit 1
}
main </dev/null
OP
```

**0.B Checks, in this order.** Any failure stops the preflight.

| # | Who | What | Expected |
|---|---|---|---|
| 0.1–0.6 | OP | block 0.1 | `preflight passed`. It checks talosctl, five nodes, `ops-kubeconfig`, cluster-admin, the LB, the Talos API and `terraform init`. Then a plain plan with no changes, and `-var cni=cilium` updating exactly the five `talos_machine` resources, each in nothing but `cluster.network.cni`, `cluster.proxy` and the `cilium` inline manifest |
| 0.7 | USER | **UART**: open each Pi's serial console, press Enter | output from c1, c2, c3; leave them attached |
| 0.8 | OP | block 0.8: runs `ops-routeros`, then reads kuberack: c1–c3's MACs on ether4–6, each `ops-poe-cycle-<node>` script cycling only its port, all three powered on. Nothing is cycled | `PoE ports match` |
| 0.9 | VM | `kubectl get nodes`; `talosctl -n $CPS etcd status`; `etcd_ok` | 5 Ready; 3 rows, one LEADER; `etcd OK` |
| 0.10 | VM | `talosctl -n $CPS get addresses \| grep 10.10.10.10/32` and LEADER from 0.9 | VIP holder and leader recorded (2026-10-30: VIP c2, leader c3); re-read before step 5 |
| 0.11 | VM | `cni_gate flannel` | `GATE PASS (flannel)` |
| 0.12 | VM | `timeout 120 nix run .#cni-pods -- plan` | no Ready Cilium agent on c1–c3, w1, w2; `cni0 still up` on all five |
| 0.13 | VM | **NIC baseline**, on the window's day: `S=$(date -u -d '-60 min' +%Y-%m-%dT%H:%M:%S); for n in 11 12 13; do printf "10.10.10.$n "; stalls_since 10.10.10.$n "$S" \|\| break; done` | B per Pi per hour, logged. c2's is near zero since its offload trial, so its trigger sits at the floor of 3. A `READ FAILED` stops the preflight. |
| 0.14 | OP | block 0.14 | VMs and Jobs saved; `Flux suspended` |
| 0.15 | OP + USER | blocks 6a, 6b and 6c with `COL=baseline`; USER: T2, T3, T5, T13 | `accepted (a)`, `(b)`, `(c)`; the user's results posted |

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 0.1 preflight · OP · within 29 min · expect: "preflight passed"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
bad=0; ok() { "$@" || { echo "FAIL: $*"; bad=1; }; }
for t in kubectl talosctl terraform flux hubble cni-pods; do case $(command -v $t) in ""|/run/*|/etc/*|/usr/*|"$HOME"/*)
  echo "FAIL: $t isn't the saved profile's"; bad=1;; esac; done
ok w 30 talosctl config info
v=$(w 60 talosctl -n 10.10.10.11,10.10.10.12,10.10.10.13,10.10.10.21,10.10.10.22 version --short) &&
  [ "$(grep -c 'Tag:' <<<"$v")" -ge 5 ] || { echo "FAIL: not five nodes"; bad=1; }
ok w 120 ops-kubeconfig; ok w 30 kubectl auth whoami
c=$(w 30 kubectl auth can-i '*' '*' -A) && [ "$c" = yes ] || { echo "FAIL: not cluster-admin"; bad=1; }
ok w 15 curl -sk --max-time 10 -o /dev/null -w '%{http_code}\n' https://10.10.10.80/
ok w 10 nc -z -w 5 10.10.10.11 50000; ok w 300 terraform -chdir=local-talos init -input=false -no-color
tp() { w 600 terraform -chdir=local-talos plan -input=false -no-color -lock-timeout=60s -detailed-exitcode "$@"; }
tp >/dev/null || { echo "FAIL: a plain plan has changes"; bad=1; }
tp -var cni=cilium -out="$S/cilium.tfplan" >/dev/null; [ $? = 2 ] || { echo "FAIL: plan -var cni=cilium"; bad=1; }
pj=$(w 120 terraform -chdir=local-talos show -json "$S/cilium.tfplan") || fail "FAIL: reading the plan"
pc=$(jq -r '.resource_changes[] | select(.change.actions != ["no-op"])
  | "\(.address) \(.change.actions | join(","))"' <<<"$pj") || fail "FAIL: parsing the plan"
want=$(for n in c1 c2 c3; do echo "module.cluster.talos_machine.controlplane[\"$n.k8s.kalski.xyz\"] update"; done
  for n in w1 w2; do echo "module.cluster.talos_machine.worker[\"$n.k8s.kalski.xyz\"] update"; done)
[ "$(sort <<<"$pc")" = "$(sort <<<"$want")" ] || { echo "FAIL: not exactly the five node updates"; bad=1; }
x='select(.cluster) |= (del(.cluster.network.cni) | del(.cluster.proxy)
  | del(.cluster.inlineManifests[] | select(.name == "cilium")))'
ua=$(jq -er '[.resource_changes[] | select(.change.actions == ["update"]) | .address] | join(" ")' <<<"$pj") ||
  fail "FAIL: parsing the plan"
for a in $ua; do
  for s in before after; do
    jq -er --arg a "$a" --arg s $s '.resource_changes[] | select(.address == $a) | .change[$s].machine_configuration' \
      <<<"$pj" | yq "$x" > "$S/plan-$s.yaml" || { echo "FAIL: parsing $a"; bad=1; }; done
  cmp -s "$S/plan-before.yaml" "$S/plan-after.yaml" || { echo "FAIL: $a changes more than CNI, proxy, Cilium"; bad=1; }
done
ok w 30 hubble version; ok w 30 cni-pods plan
[ $bad = 0 ] || fail "FAIL: stop the preflight"; finish "preflight passed"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 0.8 poe-ports · OP · read-only, before T0; nothing is cycled · expect: "PoE ports match"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
w 300 ops-routeros >/dev/null || fail "FAIL: ops-routeros didn't write the RouterOS netrc"
k=(-sS --fail-with-body --netrc-file "$O/routeros.netrc" -H 'content-type: application/json'
  --resolve kuberack.networking.kalski.xyz:443:10.10.10.1); r=https://kuberack.networking.kalski.xyz/rest
h=$(w 30 curl "${k[@]}" "$r/interface/bridge/host" |
  jq -er '.[] | "\(.["on-interface"]) \(.["mac-address"] | ascii_upcase)"') || fail "FAIL: reading the bridge hosts"
{ sj=$(w 30 curl "${k[@]}" "$r/system/script") && jq -e 'type == "array"' <<<"$sj" >/dev/null; } ||
  fail "FAIL: reading the scripts"
bad=0
for e in "c1 ether4 D8:3A:DD:D2:F1:EB" "c2 ether5 2C:CF:67:B7:02:A0" "c3 ether6 2C:CF:67:B7:03:34"; do
  read -r n p m <<<"$e"
  [ "$(awk -v m="$m" '$2 == m {print $1}' <<<"$h" | sort -u)" = "$p" ] ||
    { echo "FAIL: $n's $m isn't on $p alone"; bad=1; }
  src=$(jq -r --arg s "ops-poe-cycle-$n" '.[] | select(.name == $s) | .source' <<<"$sj")
  [[ $src == *"power-cycle $p duration=10s"* ]] && [ "$(grep -o 'ether[0-9]\+' <<<"$src" | sort -u)" = "$p" ] ||
    { echo "FAIL: ops-poe-cycle-$n doesn't cycle $p alone for 10 s"; bad=1; }
  s=$(w 20 curl "${k[@]}" "$r/interface/ethernet/poe/monitor" -d "{\"numbers\":\"$p\",\"once\":\"\"}" |
    jq -er '.[0]["poe-out-status"]') && [ "$s" = powered-on ] || { echo "FAIL: $p is '${s:-unread}'"; bad=1; }
done
[ $bad = 0 ] || fail "FAIL: no E2 until the ports match"
finish "PoE ports match: c1 ether4, c2 ether5, c3 ether6, powered-on"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 0.14 suspend-flux · OP · expect: VMs and Jobs saved; "Flux suspended"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
VQ='.items | arrays | map("\(.metadata.namespace)/\(.metadata.name) \(.status.phase // "None")
  \([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown")") | join("\n")'
j=$(w 30 kubectl get vmi -A -o json) || fail "FAIL: reading the VMs"
v=$(jq -er "$VQ" <<<"$j") || fail "FAIL: parsing the VMs"; printf '%s\n' "$v" | sed '/^$/d' > "$S/vmi"
w 30 kubectl get jobs -A > "$S/jobs" || fail "FAIL: reading the Jobs"; cat "$S/vmi" "$S/jobs"
w 120 flux suspend kustomization --all || fail "FAIL: flux suspend"
o=$(w 60 flux get kustomizations -A --no-header) || fail "FAIL: reading the Kustomizations"
[ -n "$o" ] || fail "FAIL: no Kustomizations listed"; echo "$o"
awk 'NF && $4 != "True" {b=1} END {exit b}' <<<"$o" || fail "FAIL: not every Kustomization is suspended"
finish "Flux suspended"
}
main </dev/null
OP
```

Flux stays suspended until T12 at the end (forward) or after rollback acceptance.

## 1. Apply c1. The outage starts here (T0)

1. **OP**: block 1.1 with `N=c1`.
   - It plans c1 alone with `-var cni=cilium`, and refuses (STOP before T0) unless the plan's read and parse succeed and it updates exactly c1.
   - Then it sets T0, logs `attempt c1` and applies that plan file under 300 s. Expected: 1 changed, under a minute, no reboot, `applied c1`.
   - Post the printed T0 to the VM thread.
   - Talos then installs Cilium on all five nodes at once; each node's Flannel-networked pods lose their network as its agent starts, until step 2.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 1.1, 3.1 apply · OP · N=c1 starts T0 (then c2, c3, w1, w2) · expect: "applied <node>"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
N=c1   # parameters
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
rt() { if [ -s "$S/applied" ] && [ -z "$(awk '$2 != "c1"' "$S/applied")" ]; then
  echo "Rollback A"; else echo "Rollback B"; fi; }
case $N in c?) A="module.cluster.talos_machine.controlplane[\"$N.k8s.kalski.xyz\"]";;
  w?) A="module.cluster.talos_machine.worker[\"$N.k8s.kalski.xyz\"]";; *) echo "N?"; exit 2;; esac
[ "$N" = c1 ] || grep -q '^applied c1 ' "$S/applied" || { echo "REFUSED: apply c1 first"; exit 3; }
case $N in w?) grep -q '^applied c3 ' "$S/applied" || { echo "REFUSED: control planes first"; exit 3; };; esac
w 300 terraform -chdir=local-talos plan -input=false -no-color -lock-timeout=60s -detailed-exitcode \
  -var cni=cilium -target="$A" -out="$S/$N.tfplan" >/dev/null; rc=$?
if [ $rc = 0 ] && [ -s "$S/t0" ]; then echo "applied $N $(date -u +%FT%TZ) (no change)" >> "$S/applied"
  finish "applied $N (it had the config)"; fi
[ "$(date +%s)" -lt "$END" ] || fail ""
if [ -s "$S/t0" ]; then why="ROUTE: roll back by log: $(rt)"; else why="STOP before T0"; fi
[ $rc = 2 ] || fail "FAIL: $N's plan exited $rc; $why"
pj=$(w 120 terraform -chdir=local-talos show -json "$S/$N.tfplan") || fail "FAIL: reading $N's plan"
pc=$(jq -r '.resource_changes[] | select(.change.actions != ["no-op"])
  | "\(.address) \(.change.actions | join(","))"' <<<"$pj") || fail "FAIL: parsing $N's plan"
[ "$pc" = "$A update" ] || fail "FAIL: $N's plan isn't exactly its update; $why"
[ -s "$S/t0" ] || { date +%s > "$S/t0"; : > "$S/applied"; }
echo "T0 $(date -u -d "@$(cat "$S/t0")" +%FT%TZ)"; echo "attempt $N $(date -u +%FT%TZ)" >> "$S/applied"
w 300 terraform -chdir=local-talos apply -input=false -no-color -lock-timeout=60s "$S/$N.tfplan" ||
  fail "FAIL: $N's apply; ROUTE: roll back by log: $(rt)"
echo "applied $N $(date -u +%FT%TZ)" >> "$S/applied"; finish "applied $N"
}
main </dev/null
OP
```

2. **VM: API watch.** Run `api_watch $(( $(left 10) / 60 ))`; it exits 0 on STABLE.
   - **Stop rule.** While the API is down, make no change (no apply, no `upgrade-k8s`, no recreation). Lab: outages of 11–70 s at a time, once 110 s with flapping, on overcommitted VMs.
   - Exit 1 (not stable by T0 + 10 min) → roll back (by log): the status block on OP.
3. **VM: etcd**, `etcd_ok` every minute until step 3 ends. Two failures in a row → Rollback A or B as in 1.2.
4. **VM: NIC trigger** at T0 + 5, 10 and 15 min. The window may overlap step 3; then the applied-node log decides A or B.

   ```sh
   E=$(( ($(date +%s) - $(t0s)) / 60 ))
   for n in 11 12 13; do
     d=$(dmesg_read 10.10.10.$n) || { echo "10.10.10.$n NO DMESG"; continue; }
     s=$(count_since 'TX stall detected' "$T0" <<<"$d")
     bad=$(count_since 'NETDEV WATCHDOG|transmit queue [0-9]+ timed out|end0: Link is Down' "$T0" <<<"$d")
     st=$(timeout 30 talosctl -n 10.10.10.$n get links end0 -o jsonpath='{.spec.operationalState}' 2>&1) || st="READ FAILED"
     echo "10.10.10.$n elapsed=${E}m stalls=$s watchdog/timeout/linkdown=$bad end0=$st"
   done
   ```

   Roll back (A or B) for a Pi if any of these holds:
   - `stalls` exceeds `max(3, 4 × B × E / 60)`, with B from 0.13 and E the printed elapsed minutes;
   - `bad > 0`;
   - `end0` is anything but `up`.

   If a Pi prints `NO DMESG` or `READ FAILED`, run `timeout 30 talosctl -n <ip> version`:
   - **It answers**: the Talos API is up but the NIC data can't be read; treat it as a NIC anomaly and roll back (A or B).
   - **It fails twice, 30 s apart**: the Talos API is unreachable; roll back (A or B) and go to **Escalation E1** for that Pi.
5. **Gate 1: agents Ready** (VM): `kubectl -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}'` prints `5 5`. Lab: 1m58s–2m53s.
   - Here: not `5 5` by T0 + 10 min → Rollback A.
   - `kubectl -n kube-system get pods -l k8s-app=cilium -o wide`: a CP agent with RESTARTS > 2 → Rollback A.
   - **Reused later** (step 4.3, step 5): the T0 + 10 min deadline doesn't apply. The gate gets 10 minutes from when it starts, and a failure rolls back by log (the status block).

## 2. Restore traffic (M1 by T0 + 20), then complete (M2 by T0 + 45)

Recreation runs until T0 + 18 and M1's checks until T0 + 20; a miss at T0 + 20 → roll back (by log). After M1, everything runs until T0 + 45; a miss there → no further forward step: choose rollback (by log) or STOP, and log it.

0. **OP: block 2.0** (`ACTION=cni0`): removes Flannel's `cni0` bridge (`10.244.<n>.1`: c1 .0.1, c2 .2.1, c3 .4.1, w1 .1.1, w2 .5.1) on each node whose agent is Ready, so no replacement gets its address.
   - Each pod refuses unless Cilium's CNI config is active, and verifies that the link, address and routes are gone (lab: 4–11 s per node).
   - A node it misses keeps the bridge until its reboot; recreate and the probes handle a collision.
   - A pod it can't delete is logged `UNRESOLVED`: delete it after the window (it has no `activeDeadlineSeconds`).

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 2.0 remove-cni0 · OP · ACTION=cni0: 4 min, by T0 + 14; flannel1 (4.3): 5 min · expect: "verified: …" per node
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
ACTION=cni0   # parameters
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
E=$(( $(date +%s) + 240 )); [ "$ACTION" = flannel1 ] && E=$(( $(date +%s) + 300 ))
if [ "$ACTION" = cni0 ]; then T0=$(rd t0) || { echo "REFUSED: no T0"; exit 3; }
  [ "$E" -lt $((T0 + 840)) ] || E=$((T0 + 840)); fi
[ "$E" -lt "$END" ] || E=$END
k() { local t=$(( E - $(date +%s) )); [ "$t" -gt "$1" ] && t=$1; shift; [ "$t" -gt 0 ] &&
  x "$t" kubectl -n kube-system "$@"; }
for N in c1 c2 c3 w1 w2; do p=cni0-remove-$N
  [ "$(date +%s)" -lt "$E" ] || { echo "$N: NOT STARTED, budget spent"; continue; }
  r=$(k 30 get pods -l k8s-app=cilium --field-selector spec.nodeName=$N \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}') && [ "$r" = True ] ||
    { echo "$N: NOT REMOVED, agent not Ready"; continue; }
  k 40 delete pod $p --ignore-not-found --wait --timeout=30s >/dev/null &&
    sed -e s/NODE_NAME/$N/ -e s/ACTION_VALUE/$ACTION/ local-talos/cni0-remove.yaml | k 30 create -f - >/dev/null ||
    echo "$N: create failed"
  ph=; until [ "$ph" = Succeeded ] || [ "$ph" = Failed ] || [ "$(date +%s)" -ge "$E" ]; do sleep 2
    ph=$(k 15 get pod $p -o jsonpath='{.status.phase}') || ph=; done
  o=$(k 30 logs $p) || o=; echo "$o"
  x 20 kubectl -n kube-system describe pod $p > "$S/remove-diag-$N" 2>&1
  x 30 kubectl -n kube-system delete pod $p --ignore-not-found --wait=false >/dev/null ||
    log "UNRESOLVED: pod kube-system/$p not deleted; delete it after the window"
  [ "$ph" = Succeeded ] && grep -q '^verified:' <<<"$o" || echo "$N: NOT REMOVED ($ph)"
done
o=$(w 120 cni-pods plan) && { grep 'still up' <<<"$o" || echo "no cni0 left"; } || echo "WARN: cni-pods plan failed"
finish "removal done ($ACTION)"
}
main </dev/null
OP
```

1. **OP: block 2.1** (admin kubeconfig: `recreate` reads CiliumEndpoints).
   - It keeps the `report` pods it leaves alone as `ALLOW` for 2.4. Log a disposition for each:
     - `pocket-id-sync-*` (a one-off Job; T4 re-runs it) and `descheduler-*`/`netpol-canary-*` (CronJob pods) stay;
     - virt-launcher pods: stop/start the VM;
     - standalone pods: by hand;
     - `INCLUDE=` names a report-only pod to recreate anyway.
   - `recreate` accepts a replacement, and advances a StatefulSet, only once the old pod's CiliumEndpoint is gone and the new one owns a ready endpoint; it never deletes CiliumEndpoints.
   - Exit 124 (T0 + 18) is not a failure by itself: go to M1.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 2.1 recreate · OP · until T0 + 18; MODE=post-m1 (after 2.3b): until T0 + 45 · expect: "recreated"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
MODE=pre; INCLUDE=   # parameters; INCLUDE=ns/pod,…: report-only pods to recreate anyway
T0=$(rd t0) || { echo "REFUSED: no T0"; exit 3; }
R=$((T0 + 1080)); DL="recreation (T0 + 18) ended: not a failure by itself, go to 2.3"
if [ "$MODE" = post-m1 ]; then [ -s "$S/m1" ] || { echo "REFUSED: M1 isn't confirmed (2.3b)"; exit 3; }
  R=$((T0 + 2700)); DL="T0 + 45 passed: choose rollback (by log) or STOP"; fi
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
plan=$(w 120 cni-pods plan) || fail "FAIL: cni-pods plan"; echo "$plan"
awk -v i=",$INCLUDE," '$1 == "report" && !index(i, "," $2 ",") {print $2}' <<<"$plan" | paste -sd, - > "$S/allow" ||
  fail "FAIL: saving ALLOW"
echo "ALLOW=$(cat "$S/allow")"
w 1800 cni-pods recreate ${INCLUDE:+-include "$INCLUDE"} ||
  fail "FAIL: recreate: an endpoint wait → EO.1 (START=m2); else fix or accept the owner it names and rerun"
finish recreated
}
main </dev/null
OP
```

3. **M1, traffic restored** (lab: 2m35s–5m18s after T0):
   - OP: block 2.3 (T1 through the LB, Harbor's health over HTTPS).
   - USER: T2 (login chain) and T3 (push and pull) at once.
   - OP: block 2.3b, which records M1; after T0 + 20 it exits 124, a missed M1.
   - If `recreate` didn't finish: block 2.1 with `MODE=post-m1` (until T0 + 45; refused before 2.3b).
   - Fail or a miss → roll back (by log).

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 2.3 m1 · OP · until T0 + 20 · expect: "M1 OP checks passed"; then USER T2, T3; then 2.3b
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
rt() { if [ -s "$S/applied" ] && [ -z "$(awk '$2 != "c1"' "$S/applied")" ]; then
  echo "Rollback A"; else echo "Rollback B"; fi; }
T0=$(rd t0) || { echo "REFUSED: no T0"; exit 3; }; R=$((T0 + 1200)); DL="M1 (T0 + 20) passed: roll back by log ($(rt))"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
bad=0; for h in grafana harbor id auth; do
  r=$(w 10 curl -sS --max-time 10 -o /dev/null -w "%{http_code} %{ssl_verify_result}" \
    --resolve "$h.kube.kalski.xyz:443:10.10.10.80" "https://$h.kube.kalski.xyz/") || r=
  echo "$h $r"; [[ $r =~ ^(200|302)\ 0$ ]] || bad=1; done
r=$(w 15 curl -sS --max-time 15 --resolve harbor.kube.kalski.xyz:443:10.10.10.80 \
  https://harbor.kube.kalski.xyz/api/v2.0/health) && jq -e '.status == "healthy"' <<<"$r" >/dev/null || bad=1
[ $bad = 0 ] || fail "FAIL: M1; ROUTE: roll back by log: $(rt)"
date +%s > "$S/m1op"; finish "M1 OP checks passed; USER: T2 and T3 now"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 2.3b m1-confirm · OP · after the user's T2 and T3 passed, by T0 + 20 · expect: "M1 passed"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
rt() { if [ -s "$S/applied" ] && [ -z "$(awk '$2 != "c1"' "$S/applied")" ]; then
  echo "Rollback A"; else echo "Rollback B"; fi; }
T0=$(rd t0) || { echo "REFUSED: no T0"; exit 3; }; [ -s "$S/m1op" ] || { echo "REFUSED: 2.3 hasn't passed"; exit 3; }
R=$((T0 + 1200)); DL="M1 (T0 + 20) passed before confirmation: roll back by log ($(rt))"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
[ "$(date +%s)" -lt "$R" ] || fail ""; date +%s > "$S/m1"; finish "M1 passed"
}
main </dev/null
OP
```

4–5. **M2: block 2.4**, until T0 + 45 (lab: `recreate` took 8–14 min, mostly waiting for a crash-looping operator replica):
   - `cni-pods verify`, the hard gate (the VM's is diagnostic);
   - `cni-pods endpoints -allow $ALLOW`: it joins every CiliumEndpoint to running pods by owner UID and checks node, host IP and addresses. It fails on a pod without an endpoint outside `ALLOW`, an endpoint not ready or on another node, or an owner that is no running pod;
   - five agents `OK` and `cilium-operator` 2/2;
   - a probe Pod per node, from a complete manifest, reaching DNS through 10.96.0.10, Traefik's pod on 80 and a CoreDNS pod on another node. A probe on its node's `cni0` address is retried.

   An `error in controller sync-to-k8s-ciliumendpoint (<id>): … cannot take ownership of CEP` is a **stop and investigate** → Endpoint ownership. Cilium retries it without a bound (its stored pod has no host IP; `endpointsynchronizer.go`, 1.20.4), and the pod's endpoint stays unpublished.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 2.4 m2 · OP · until T0 + 45; MODE=prune (4.3): 15 min from its first run · expect: "M2 passed"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
MODE=m2   # parameters
if [ "$MODE" = prune ]; then [ -s "$S/s0" ] || date +%s > "$S/s0"; R=$(rd s0) || exit 3; R=$(( R + 900 ))
else R=$(rd t0) || { echo "REFUSED: no T0"; exit 3; }; R=$(( R + 2700 )); fi
al=$(cat "$S/allow") || { echo "REFUSED: no ALLOW from 2.1"; exit 3; }
DL="the M2 deadline passed: choose rollback (by log) or STOP"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
bad=0; w 900 cni-pods verify || bad=1; w 120 cni-pods endpoints -allow "$al" || bad=1
pods=$(w 30 kubectl -n kube-system get pods -l k8s-app=cilium -o name) || fail "FAIL: reading the agents"
[ "$(wc -w <<<"$pods")" = 5 ] || { echo "FAIL: not 5 agents"; bad=1; }
for p in $pods; do s=$(w 30 kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status --brief 2>&1) || s=
  echo "$p: $s"; [ "$s" = OK ] || bad=1; done
r=$(w 30 kubectl -n kube-system get deploy cilium-operator -o jsonpath='{.status.readyReplicas}') && [ "$r" = 2 ] ||
  { echo "FAIL: operator not 2/2"; bad=1; }
probe() {  # a pod on NODE reaches DNS, Traefik and CoreDNS
  local p o rc; p=probe-$1-$(date +%s)
  w 30 kubectl -n kube-system create -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: Pod
metadata: {name: $p}
spec:
  nodeName: $1
  restartPolicy: Never
  tolerations: [{operator: Exists}]
  containers:
  - name: probe
    image: busybox:1.37
    command: [sh, -c, 'echo ip=\$(hostname -i); timeout 5 nslookup kubernetes.default.svc.cluster.local
      10.96.0.10 >/dev/null && echo ok; nc -w 3 -z $tr 80 && echo ok; nc -w 3 -z $dns 53 && echo ok']
EOF
  w 90 kubectl -n kube-system wait "pod/$p" --for=jsonpath='{.status.phase}'=Succeeded --timeout=80s >/dev/null &&
    o=$(w 30 kubectl -n kube-system logs "$p"); rc=$?
  x 30 kubectl -n kube-system delete pod "$p" --wait=false >/dev/null
  echo "$1: $(tr '\n' ' ' <<<"$o")"; [ "$rc" = 0 ] && [ "$(grep -cx ok <<<"$o")" = 3 ] && return 0
  grep -qE 'ip=10\.244\.[0-9]+\.1$' <<<"$o" && return 2; return 1; }  # 2: its node's cni0 address, retry
tr=$(w 30 kubectl -n traefik get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}') &&
  [ -n "$tr" ] || fail "FAIL: reading Traefik's pod"
dj=$(w 30 kubectl -n kube-system get pods -l k8s-app=kube-dns -o json) || fail "FAIL: reading CoreDNS"
for n in c1 c2 c3 w1 w2; do
  dns=$(jq -er --arg n $n '[.items[] | select(.spec.nodeName != $n and .status.phase == "Running")][0]
    .status.podIP' <<<"$dj") || fail "FAIL: no CoreDNS pod off $n"
  for try in 1 2 3; do probe $n; rc=$?; [ $rc = 2 ] && [ $try -lt 3 ] && continue; [ $rc = 0 ] || bad=1; break; done
done
[ $bad = 0 ] || fail "FAIL: M2: endpoint error → EO.1; stale endpoints → rerun in 60 s; else rollback or STOP"
finish "M2 passed"
}
main </dev/null
OP
```

### Endpoint ownership (OP, from 2, 4.3 or 5.4)

Run this when `recreate` times out on an endpoint wait, when `endpoints` keeps reporting stale ownership, or when an agent reports `cannot take ownership of CEP`.
- **Budget:** one episode, with M2's deadline (EO.1 `START=m2`) or, from 4.3 and 5.4, 15 fresh minutes (`START=fresh`), shared by its later blocks through `~/cutover`.
- **Captures:** `START=again` captures again without resetting the budget. After the budget ended it still captures, for the record only, while EO.3–EO.4 exit 124.

1. **Capture and identify**: EO.1 saves CiliumEndpoints, pods, events, and each agent's endpoints, status and log. It classifies each `sync-to-k8s-ciliumendpoint (<id>)`, taking the pod from the endpoint's `resolve-labels-<ns>/<pod>` controller (1.20's external identifiers lack it):
   - **STALE CEP**: the owner UID isn't the running pod's (StatefulSet name reuse).
   - **LOST CREATE**: the owner *is* the running pod. The agent's `Cannot create CEP` (for example an etcd timeout) stored it but never returned its UID; the agent won't adopt it, and it never heals (seen once in the lab, on #239).
3. **Stale CEP: EO.3** (`cni-pods clear-stale-ceps -cep`): deletes it only if its owner matches no pod, with UID and resourceVersion preconditions. #231's test mocks the Conflict; a real API-server rejection is unexercised. Prints `cleared`, `healthy` or `unresolved`.
3a. **Lost create: EO.3a** (`cni-pods recreate -include`): replaces the live pod by its owner (a StatefulSet pod one at a time, the old CEP gone and the new one ready first). Never delete a live pod's CEP.
4. **Converge: EO.4**: within 2 minutes and the budget, five agents `OK` and `endpoints` passing → recovered; resume.
5. **Terminal** (EO.4 exit 1, or the budget ended): no further forward step; EO.1 `START=again` for the record. Then:
   - from 2: roll back (by log);
   - from 4.3: rollback or STOP, logged;
   - from 5.4: STOP, no rollback without the user.

   Beyond 3a, deleting the pod by hand is the hands-on fix.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# EO.1 endpoint-capture · OP · START=m2 or fresh begins an episode; START=again captures again · expect: "captured in …"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
START=m2   # parameters
case $START in m2) echo m2 > "$S/eb";; fresh) echo fresh > "$S/eb"; date +%s > "$S/er0";; again) ;; *) exit 2;; esac
case $(cat "$S/eb" 2>/dev/null) in m2) R=$(rd t0) && R=$(( R + 2700 ));;
  fresh) R=$(rd er0) && R=$(( R + 900 ));; *) false;; esac || { echo "REFUSED: no endpoint episode (EO.1)"; exit 3; }
if [ "$(date +%s)" -ge "$R" ]; then echo "the episode's budget ended: capturing for the record only (5 min)"
  R=$(( $(date +%s) + 300 )); fi
DL="the episode's budget ended: terminal (EO.5)"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
d=$S/diag-$(date +%s); mkdir -p "$d"
# e FILE SECONDS CMD…: a capture. A failed one is kept as FILE.failed for the record, and never classified.
e() { local f=$1; shift; w "$@" > "$f" && return 0; mv "$f" "$f.failed"; echo "WARN: $f failed; kept as .failed"
  return 1; }
k() { e "$1" 30 kubectl -n kube-system "${@:2}"; }
for o in ciliumendpoints.cilium.io pods events; do e "$d/$o.json" 60 kubectl get "$o" -A -o json; done
ag=$(w 30 kubectl -n kube-system get pods -l k8s-app=cilium -o name) || { echo "UNCLASSIFIED: agents unreadable"; ag=; }
for a in $ag; do a=${a#pod/}
  k "$d/$a-ep.json" exec "$a" -c cilium-agent -- cilium-dbg endpoint list -o json
  k "$d/$a-agent.log" logs "$a" -c cilium-agent --tail=1000
  k "$d/$a-status.log" exec "$a" -c cilium-agent -- cilium-dbg status --verbose ||
    { echo "$a: UNCLASSIFIED (its status is unreadable)"; continue; }
  grep -oE 'sync-to-k8s-ciliumendpoint \([0-9]+\)' "$d/$a-status.log" | grep -oE '[0-9]+' | sort -u |
  while read -r id; do
    if ! { k=$(jq -er --argjson i "$id" 'first(.[] | select(.id == $i) | .status.controllers[].name
        | select(startswith("resolve-labels-")) | ltrimstr("resolve-labels-"))' "$d/$a-ep.json") &&
      pu=$(jq -er --arg k "$k" 'first(.items[] | select("\(.metadata.namespace)/\(.metadata.name)" == $k)
        | .metadata.uid)' "$d/pods.json") &&
      ou=$(jq -er --arg k "$k" '[.items[] | select("\(.metadata.namespace)/\(.metadata.name)" == $k)
        | .metadata.ownerReferences[0].uid][0] // ""' "$d/ciliumendpoints.cilium.io.json"); }; then
      echo "$id on $a: UNCLASSIFIED (a capture is unreadable)"; continue; fi
    if [ -z "$ou" ]; then echo "$id on $a: $k has no CEP"
    elif [ "$ou" = "$pu" ]; then echo "$id on $a: $k LOST CREATE → EO.3a"
    else echo "$id on $a: $k STALE CEP → EO.3"; fi
  done; done
e "$d/endpoints.txt" 120 cni-pods endpoints -allow "$(cat "$S/allow" 2>/dev/null)"; cat "$d"/endpoints.txt*
finish "captured in $d"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# EO.3 clear-cep (stale CEP) · OP · within the episode · expect: "cleared", "healthy" or "unresolved"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
CEP=ns/name   # parameters
case $(cat "$S/eb" 2>/dev/null) in m2) R=$(rd t0) && R=$(( R + 2700 ));;
  fresh) R=$(rd er0) && R=$(( R + 900 ));; *) false;; esac || { echo "REFUSED: no endpoint episode (EO.1)"; exit 3; }
DL="the episode's budget ended: terminal (EO.5)"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
o=$(w 120 cni-pods clear-stale-ceps -cep "$CEP") || fail "FAIL: clear-stale-ceps: $o"; finish "$o"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# EO.3a recreate-include (lost create) · OP · within the episode · expect: "verified: …"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
POD=ns/pod   # parameters
case $(cat "$S/eb" 2>/dev/null) in m2) R=$(rd t0) && R=$(( R + 2700 ));;
  fresh) R=$(rd er0) && R=$(( R + 900 ));; *) false;; esac || { echo "REFUSED: no endpoint episode (EO.1)"; exit 3; }
DL="the episode's budget ended: terminal (EO.5)"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
w 660 cni-pods recreate -include "$POD" -timeout 10m || fail "FAIL: recreate -include"; finish "recreated $POD"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# EO.4 converge · OP · 2 min, within the episode · expect: "recovered"; exit 1 = terminal (EO.5)
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
case $(cat "$S/eb" 2>/dev/null) in m2) R=$(rd t0) && R=$(( R + 2700 ));;
  fresh) R=$(rd er0) && R=$(( R + 900 ));; *) false;; esac || { echo "REFUSED: no endpoint episode (EO.1)"; exit 3; }
al=$(cat "$S/allow") || { echo "REFUSED: no ALLOW from 2.1"; exit 3; }
DL="the episode's budget ended: terminal (EO.5)"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
U=$(( $(date +%s) + 120 )); [ "$U" -lt "$END" ] || U=$END   # the two minutes, within the budget and the cap
u() { local t=$(( U - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1; shift; w "$t" "$@"; }
while [ "$(date +%s)" -lt "$U" ]; do good=1
  pods=$(u 30 kubectl -n kube-system get pods -l k8s-app=cilium -o name) && [ "$(wc -w <<<"$pods")" = 5 ] || good=0
  for p in $pods; do s=$(u 30 kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status --brief) || s=
    [ "$s" = OK ] || good=0; done
  if [ $good = 1 ] && u 60 cni-pods endpoints -allow "$al" &&
    [ "$(date +%s)" -lt "$U" ]; then finish "recovered: resume where you came from"; fi
  sleep 15; done
[ "$U" -lt "$END" ] || fail ""
echo "ROUTE: terminal (EO.5): EO.1 START=again; from M2 roll back by log; from 4.3 rollback or STOP; from 5.3 STOP"
exit 1
}
main </dev/null
OP
```

## 3. Remaining nodes (live, no reboots)

1. **OP**: block 1.1 with `N=c2`, then `c3`, `w1`, `w2`. Workers are refused before c3, because targeting a worker also applies pending control-plane changes. Each: 1 changed, no reboot. A failed apply prints the rollback by log.
2. **VM**: `etcd_ok` after each.
3. **Gate 3** (VM): `cni_gate cilium` → `GATE PASS (cilium)`.

## 4. Prune

1. **Gates**: nodes Ready, `etcd_ok`, gate 3, M2.
2. **OP: block 4.2**: the dry run must prune exactly Flannel's and kube-proxy's 8 objects; anything else stops the window.
3. **OP: block 4.3**: up to 3 tries, checking etcd between them (the lab saw an etcd timeout mid-prune). Then:
   - block 2.0 with `ACTION=flannel1` (a miss is only logged: the reboot removes it);
   - VM gate 1 again (10 minutes; a failure rolls back by log);
   - block 2.4 with `MODE=prune`: 15 fresh minutes. An endpoint failure → EO.1 `START=fresh`; otherwise rollback or STOP, logged.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 4.2 prune-dry-run · OP · expect: "dry run prunes exactly the 8"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
tv=$(jq -er .kubernetes local-talos/versions.json) || fail "FAIL: reading versions.json"
o=$(w 300 talosctl -n 10.10.10.11 upgrade-k8s --to "$tv" --dry-run 2>&1) ||
  fail "FAIL: the dry run: $o"; echo "$o"
got=$(awk '$1 == "<" && $2 == "Pruned" {print $3}' <<<"$o" | sort | paste -sd' ')
want=$(printf '%s\n' ClusterRole/flannel ClusterRoleBinding/{flannel,kube-proxy} \
  ConfigMap/kube-system/kube-flannel-cfg DaemonSet/kube-system/{kube-flannel,kube-proxy} \
  ServiceAccount/kube-system/{flannel,kube-proxy} | sort | paste -sd' ')
[ "$got" = "$want" ] || fail "FAIL: pruned: $got; STOP"; finish "dry run prunes exactly the 8"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 4.3 prune · OP · up to 3 tries · expect: "pruned"; then 2.0 ACTION=flannel1, VM gate 1, 2.4 MODE=prune
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
tv=$(jq -er .kubernetes local-talos/versions.json) || fail "FAIL: reading versions.json"
for _ in 1 2 3; do w 600 talosctl -n 10.10.10.11 upgrade-k8s --to "$tv" && finish pruned
  [ "$(date +%s)" -lt "$END" ] || fail ""
  w 30 talosctl -n 10.10.10.11,10.10.10.12,10.10.10.13 etcd status || break; done
fail "FAIL: the prune failed: choose rollback (by log) or STOP, and log it"
}
main </dev/null
OP
```

## 5. Forward reboots, one node at a time

1. **VM**: re-read the VIP holder and leader (0.10); if one node holds both, OP runs block 5.1 on it and the VM re-reads.
2. **Order**: VIP holder, etcd leader, the third CP, w1 (Traefik, Harbor), w2. Lab API impact: 1.2–3.4 s for the VIP holder, 1.1–2.4 s for the leader. UART stays attached.
3. **Per node**: VM `etcd_ok` before a CP, then OP block 5.3: cordon, reboot, a new boot ID and Ready on it within one 15-minute wait, uncordon, delete the operator's Failed pods, report any `PILE-UP`.
   - VM: after a CP, `etcd_ok` within 10 min; otherwise E4.
   - A `STOP:` from 5.3 (cordon, reads, no new boot ID, not Ready): no further reboots. A CP whose Talos API doesn't answer → E1; anything else → STOP.
   - Exit 125 from 5.3: check the boot ID; never reboot again blindly.
4. **OP: block 5.4** on the node: `cni-pods verify`, five agents `OK`, the repair pod's inspection without `10-flannel.conflist`, and the link listing without `cni0` or `flannel`. A failed or unparsable read fails it.
   - Failed checks: no further reboots. An endpoint failure → Endpoint ownership (`fresh`), then 5.4 again; otherwise STOP, no rollback without the user.
   - VM: `cni-pods plan` no longer lists `cni0` for the node.
5. **Optional, after M3**: a replica that fell back to a control plane stays there (a preferred affinity doesn't move running pods; the descheduler only targets non-control-plane nodes). Once stable, with each command approved on its own: confirm the other replica Ready, delete only the control-plane one, then require 2/2 Ready on distinct nodes within 5 min.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 5.1 forfeit · OP · N=<the CP holding both the VIP and etcd leadership> · expect: "forfeited"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
N=c2   # parameters
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
case $N in c1) ip=10.10.10.11;; c2) ip=10.10.10.12;; c3) ip=10.10.10.13;;
  w1) ip=10.10.10.21;; w2) ip=10.10.10.22;; *) echo "N?"; exit 2;; esac
w 60 talosctl -n "$ip" etcd forfeit-leadership || fail "FAIL: forfeit"; finish "forfeited"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 5.3 reboot · OP · N=<node>; UNCORDONED=yes only if a rollback's cordon fails · expect: "<node> rebooted"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
N=w1; UNCORDONED=no   # parameters
R=0; CAP="the reboot of $N may have started: check its boot ID; never reboot it again blindly"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
case $N in c1) ip=10.10.10.11;; c2) ip=10.10.10.12;; c3) ip=10.10.10.13;;
  w1) ip=10.10.10.21;; w2) ip=10.10.10.22;; *) echo "N?"; exit 2;; esac
w 60 kubectl cordon "$N" || { [ "$UNCORDONED" = yes ] && log "UNCORDONED REBOOT $N"; } || fail "STOP: cordon failed"
pods=$(w 60 kubectl get pods -A --field-selector spec.nodeName="$N" \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}') || fail "STOP: can't read the pods"
b0=$(w 30 talosctl -n "$ip" read /proc/sys/kernel/random/boot_id) || fail "STOP: can't read $N's boot ID"
[ -n "$b0" ] || fail "STOP: can't read $N's boot ID"
W=$(( $(date +%s) + 900 )); [ "$W" -lt "$END" ] || W=$END   # one 15-min wait: reboot, new boot ID, Ready
v() { local t=$(( W - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
v 600 talosctl -n "$ip" reboot --wait --timeout 9m || echo "WARN: talosctl reboot exited $?; checking the boot ID"
while :; do b=$(v 15 talosctl -n "$ip" read /proc/sys/kernel/random/boot_id 2>/dev/null) || b=
  [ "$(date +%s)" -lt "$W" ] || fail "STOP: $N's boot ID is unchanged 15 min after the reboot: it didn't reboot"
  [ -n "$b" ] && [ "$b" != "$b0" ] && break; sleep 10; done
while :; do s=$(v 15 kubectl get node "$N" \
    -o jsonpath='{.status.nodeInfo.bootID} {.status.conditions[?(@.type=="Ready")].status}') || s=
  [ "$(date +%s)" -lt "$W" ] || fail "STOP: $N not Ready on its new boot within 15 min"
  [ "$s" = "$b True" ] && break; sleep 10; done
w 60 kubectl uncordon "$N" || fail "STOP: $N still cordoned"
q='{range .items[?(@.status.reason=="NodeShutdown")]}{.metadata.namespace}/{.metadata.name}'
rej=$(w 60 kubectl get pods -A --field-selector spec.nodeName="$N",status.phase=Failed \
  -o jsonpath="$q {.metadata.ownerReferences[0].kind}{\"\\n\"}{end}") || echo "WARN: Failed pods unreadable"
while read -r x kind; do [ -n "$x" ] && [ "$kind" != DaemonSet ] && ! grep -qxF "$x" <<<"$pods" && echo "PILE-UP: $x"
  done <<<"$rej"
w 90 kubectl -n kube-system delete pods -l io.cilium/app=operator --field-selector status.phase=Failed >/dev/null ||
  echo "WARN: the operator's Failed pods weren't deleted"
finish "$N rebooted"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 5.4 node-check · OP · N=<node>, after its forward reboot · expect: "<node> clean"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
N=w1   # parameters
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
case $N in c1) ip=10.10.10.11;; c2) ip=10.10.10.12;; c3) ip=10.10.10.13;;
  w1) ip=10.10.10.21;; w2) ip=10.10.10.22;; *) echo "N?"; exit 2;; esac
bad=0; w 900 cni-pods verify || bad=1
pods=$(w 30 kubectl -n kube-system get pods -l k8s-app=cilium -o name) || fail "FAIL: reading the agents"
[ "$(wc -w <<<"$pods")" = 5 ] || { echo "FAIL: not 5 agents"; bad=1; }
for p in $pods; do s=$(w 30 kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status --brief 2>&1) || s=
  echo "$p: $s"; [ "$s" = OK ] || bad=1; done
c=cni-repair-$N; w 40 kubectl -n kube-system delete pod $c --ignore-not-found --wait --timeout=30s >/dev/null ||
  echo "WARN: an old $c wasn't deleted"
o=; rc=1; sed -e s/NODE_NAME/$N/ -e s/ACTION_VALUE/inspect/ local-talos/cni-repair.yaml |
  w 30 kubectl create -f - >/dev/null && w 180 kubectl -n kube-system wait pod/$c \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m >/dev/null && o=$(w 30 kubectl -n kube-system logs $c); rc=$?
x 60 kubectl -n kube-system delete pod $c --wait >/dev/null; echo "$o"
if [ $rc != 0 ] || ! grep -q '^before:' <<<"$o" || ! grep -q '^after:' <<<"$o"; then
  echo "FAIL: $N's CNI config couldn't be inspected"; bad=1; fi
grep -q 10-flannel.conflist <<<"$o" && { echo "FAIL: Flannel's CNI config left"; bad=1; }
l=$(w 30 talosctl -n "$ip" get links) || { echo "FAIL: $N's links couldn't be read"; bad=1; l=; }
grep -q LinkStatus <<<"$l" || { echo "FAIL: $N's link listing is empty"; bad=1; }
grep -E 'cni0|flannel' <<<"$l" && { echo "FAIL: Flannel links left"; bad=1; }
[ $bad = 0 ] ||
  fail "FAIL: no further reboots: an endpoint error → EO.1 START=fresh; else STOP (no rollback w/o the user)"
finish "$N clean"
}
main </dev/null
OP
```

## 6. Acceptance checks

M3 = blocks 6a, 6b and 6c with `COL=forward` passing after step 5 (also run at M1 and after step 4), plus the user's checks; then T12. Baseline (0.15) and rollback use `COL=baseline` and `COL=rollback`. Every read must succeed, and parse, for its check to pass.

| # | Who | What | Baseline | Forward | Rollback |
|---|---|---|---|---|---|
| T1 Traefik via the LB | OP (6a) | grafana, harbor, id, auth through 10.10.10.80 | 200/302, verify 0 | same | same |
| T2 Login chain | USER | browser, within 5 min: `docsight.kube.kalski.xyz` logged out → `auth.` → Pocket ID → back | loads | same | same |
| T3 Harbor | OP (6a) + USER | OP: `/api/v2.0/health` `healthy`. USER: `docker login`, push a tagged busybox, `rmi`, pull; projects present; a scan within 10 min | OK | OK | OK |
| T4 Pocket ID sync | OP (6a) | the Job rendered from Flux's last applied revision (Kustomize's hashed ConfigMap must exist), re-run under its fixed name (Pocket ID's NetworkPolicy allows `job-name: pocket-id-sync`); Flux suspended | complete | same | same |
| T5 Docsight's /32 | OP (6c) + USER | USER: modem data newer than the check. OP, forward: Hubble flows to 192.168.100.1 FORWARDED, none DROPPED | fresh | fresh; forwarded | fresh |
| T6 Netpol canary | OP (6a) | a Job from `cronjob/netpol-canary` | `OK: the modem was blocked…` | same | same |
| T7 Sandbox first packet | OP (6b) | a Restricted Pod, from a complete manifest, tries the modem and kube-dns at +0 and +5 s | modem blocked at +5 s; dns connected | blocked at +0 and +5; dns at +0 | as baseline |
| T8 Webhooks | OP (6b) | server-side dry runs: Certificate, ExternalSecret, VirtualMachine | 3× `created (server dry run)` | same | same |
| T9 APIServices / metrics | OP (6c) | none unavailable; `kubectl top nodes` | metrics | same | same |
| T10 VMs | OP (6c) | identity, phase and Ready against 0.14's | as 0.14 | same | same |
| T11 external-dns | OP (6c) | errors in 15 min of `-mikrotik` and `-stationary` | 0 | 0 | 0 |
| T12 Flux | OP | last: block T12 | (suspended) | all Ready | all Ready |
| T13 Observability | OP (6c) + USER | USER: Prometheus targets. OP, forward: Hubble's DROPPED flows, judged by eye | up | up; expected drops | up |

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 6a accept (T1, T3, T4, T6) · OP · COL=baseline, forward or rollback (60 min) · expect: "accepted (a)"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
COL=forward   # parameters: baseline, forward or rollback
R=0; if [ "$COL" = rollback ]; then [ -s "$S/ra0" ] || date +%s > "$S/ra0"; R=$(rd ra0) || exit 3; R=$(( R + 3600 )); fi
DL="rollback acceptance's 60 min ended: STOP (on Flannel)"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
F=0; chk() { local n=$1 o; shift; if o=$("$@" 2>&1); then echo "PASS $n"; else echo "FAIL $n: $o"; F=1; fi; }

t1() { local h r; for h in grafana harbor id auth; do
  r=$(w 10 curl -sS --max-time 10 -o /dev/null -w "%{http_code} %{ssl_verify_result}" \
    --resolve "$h.kube.kalski.xyz:443:10.10.10.80" "https://$h.kube.kalski.xyz/") || return 1
  [[ $r =~ ^(200|302)\ 0$ ]] || return 1; done; }
t3() { local r; r=$(w 15 curl -sS --resolve harbor.kube.kalski.xyz:443:10.10.10.80 \
  https://harbor.kube.kalski.xyz/api/v2.0/health) && jq -e '.status == "healthy"' <<<"$r"; }
t4() { local rev d cm; rev=$(w 30 kubectl -n flux-system get kustomization apps \
    -o jsonpath='{.status.lastAppliedRevision}') && [ -n "$rev" ] && d=$(mktemp -d) || return 1
  [ -d "$d" ] && git -C .. archive "${rev##*:}" infra/local-kubernetes/apps/pocket-id-sync | tar -x -C "$d" &&
  w 60 kustomize build "$d/infra/local-kubernetes/apps/pocket-id-sync" > "$d/a.yaml" &&
  cm=$(yq -e 'select(.kind == "ConfigMap") | .metadata.name' "$d/a.yaml") &&
  w 30 kubectl -n pocket-id get configmap "$cm" -o name &&
  yq -e 'select(.kind == "Job" and .metadata.name == "pocket-id-sync")' "$d/a.yaml" > "$d/j.yaml" &&
  grep -q "$cm" "$d/j.yaml" && w 130 kubectl -n pocket-id delete job pocket-id-sync --ignore-not-found --wait &&
  w 30 kubectl -n pocket-id create -f "$d/j.yaml" &&
  w 310 kubectl -n pocket-id wait job/pocket-id-sync --for=condition=complete --timeout=5m &&
  w 30 kubectl -n pocket-id logs job/pocket-id-sync; }
t6() { local j rc; j=canary-$(date +%s)
  w 30 kubectl -n netpol-canary create job "$j" --from=cronjob/netpol-canary >/dev/null || return 1
  w 190 kubectl -n netpol-canary wait "job/$j" --for=condition=complete --timeout=3m &&
    w 30 kubectl -n netpol-canary logs "job/$j"; rc=$?
  x 30 kubectl -n netpol-canary delete job "$j" --wait=false >/dev/null; return "$rc"; }
chk T1 t1; chk T3-https t3; chk T4 t4; chk T6 t6
[ $F = 0 ] || fail "FAIL: report the failed checks (rollback acceptance: STOP)"; finish "accepted (a)"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 6b accept (T7, T8) · OP · COL as in 6a · expect: "accepted (b)"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
COL=forward   # parameters: baseline, forward or rollback
R=0; if [ "$COL" = rollback ]; then [ -s "$S/ra0" ] || date +%s > "$S/ra0"; R=$(rd ra0) || exit 3; R=$(( R + 3600 )); fi
DL="rollback acceptance's 60 min ended: STOP (on Flannel)"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
F=0; chk() { local n=$1 o; shift; if o=$("$@" 2>&1); then echo "PASS $n"; else echo "FAIL $n: $o"; F=1; fi; }

t7() { local p o rc; p=sandbox-probe-$(date +%s)
  w 30 kubectl -n agent-sandbox create -f - >/dev/null <<EOF || return 1
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
    command: [sh, -c, 'for t in 0 5; do [ \$t = 0 ] || sleep 5;
      nc -w 2 -z 192.168.100.1 80 && echo "+\${t}s modem CONNECTED" || echo "+\${t}s modem blocked";
      nc -w 2 -z 10.96.0.10 53 && echo "+\${t}s dns connected" || echo "+\${t}s dns BLOCKED"; done']
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
  w 130 kubectl -n agent-sandbox wait "pod/$p" --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m >/dev/null &&
    o=$(w 30 kubectl -n agent-sandbox logs "$p"); rc=$?
  x 30 kubectl -n agent-sandbox delete pod "$p" --wait=false >/dev/null; echo "$o"; [ "$rc" = 0 ] || return 1
  grep -q '+5s modem blocked' <<<"$o" && grep -q 'dns connected' <<<"$o" || return 1
  [ "$COL" != forward ] || { grep -q '+0s modem blocked' <<<"$o" && grep -q '+0s dns connected' <<<"$o"; }; }
t8() { local o; o=$(w 30 kubectl -n default apply --dry-run=server -f - <<'EOF') || return 1
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: cutover-dry-run}
spec: {secretName: cutover-dry-run, dnsNames: [cutover-dry-run.kube.kalski.xyz],
  issuerRef: {kind: ClusterIssuer, name: letsencrypt}}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: cutover-dry-run}
spec: {secretStoreRef: {kind: ClusterSecretStore, name: gcp-secret-manager}, target: {name: cutover-dry-run},
  data: [{secretKey: x, remoteRef: {key: local-kubernetes}}]}
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata: {name: cutover-dry-run}
spec: {runStrategy: Halted, template: {spec: {domain: {devices: {}, resources: {requests: {memory: 64Mi}}}}}}
EOF
  [ "$(grep -c 'created (server dry run)' <<<"$o")" = 3 ]; }
chk T7 t7; chk T8 t8
[ $F = 0 ] || fail "FAIL: report the failed checks (rollback acceptance: STOP)"; finish "accepted (b)"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# 6c accept (T9–T11, T5, T13) · OP · COL as in 6a · expect: "accepted (c)"; USER: T2, T3, T5, T13
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
COL=forward   # parameters: baseline, forward or rollback
R=0; if [ "$COL" = rollback ]; then [ -s "$S/ra0" ] || date +%s > "$S/ra0"; R=$(rd ra0) || exit 3; R=$(( R + 3600 )); fi
DL="rollback acceptance's 60 min ended: STOP (on Flannel)"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
F=0; chk() { local n=$1 o; shift; if o=$("$@" 2>&1); then echo "PASS $n"; else echo "FAIL $n: $o"; F=1; fi; }
VQ='.items | arrays | map("\(.metadata.namespace)/\(.metadata.name) \(.status.phase // "None")
  \([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown")") | join("\n")'

t9() { local j u; j=$(w 30 kubectl get apiservices -o json) || return 1
  u=$(jq -er '.items | arrays | map(select(any(.status.conditions[]?; .type == "Available" and .status != "True"))
    | .metadata.name) | join(" ")' <<<"$j") || return 1; [ -z "$u" ] || { echo "unavailable: $u"; return 1; }
  w 30 kubectl top nodes; }
t10() { local j now was; [ -e "$S/vmi" ] || { echo "no VM list from 0.14"; return 1; }
  was=$(sort "$S/vmi") || return 1
  j=$(w 30 kubectl get vmi -A -o json) || return 1; now=$(jq -er "$VQ" <<<"$j") || return 1
  [ "$was" = "$(sed '/^$/d' <<<"$now" | sort)" ] || { echo "VMs differ: $now"; return 1; }; }
t11() { local d o; for d in mikrotik stationary; do
  o=$(w 30 kubectl -n external-dns logs "deploy/external-dns-$d" --since=15m) || return 1
  [ "$(grep -ciE 'error|fail' <<<"$o")" = 0 ] || return 1; done; }
hub() { local f rc; trap stop TERM INT HUP  # the port-forward is a job: a signal or the EXIT trap kills it
  timeout "$(( END - $(date +%s) < 180 ? END - $(date +%s) : 180 ))" kubectl -n kube-system \
    port-forward svc/hubble-relay 4245:80 >/dev/null 2>&1 9>&- & f=$!
  for _ in $(seq 30); do x 3 nc -z 127.0.0.1 4245 && break; sleep 1; done
  w 120 hubble observe --server 127.0.0.1:4245 "$@"; rc=$?
  kill "$f" 2>/dev/null; wait "$f" 2>/dev/null; return "$rc"; }
t5() { local o; o=$(hub --namespace docsight --to-ip 192.168.100.1 --since 10m -o compact) &&
  grep -q FORWARDED <<<"$o" && ! grep -q DROPPED <<<"$o"; }
chk T9 t9; chk T10 t10; chk T11 t11
[ "$COL" = forward ] && { chk T5-hubble t5; chk T13-hubble hub --verdict DROPPED --since 10m -o compact --last 100; }
echo "USER: T2, T3 push/pull, T5 Docsight, T13 Prometheus targets"
[ $F = 0 ] || fail "FAIL: report the failed checks (rollback acceptance: STOP)"; finish "accepted (c)"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# T12 resume-flux · OP · last; 10 min for every Kustomization Ready · expect: "every Kustomization Ready"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
w 120 flux resume kustomization --all || fail "FAIL: flux resume"
w 300 flux reconcile source git flux-system || fail "FAIL: reconcile"
F=$(( $(date +%s) + 600 )); [ "$F" -lt "$END" ] || F=$END
while :; do o=; if o=$(w 60 flux get kustomizations -A --no-header) && [ -n "$o" ] &&
    awk 'NF && ($4 != "False" || $5 != "True") {b=1} END {exit b}' <<<"$o" && [ "$(date +%s)" -lt "$F" ]; then break; fi
  [ "$(date +%s)" -lt "$F" ] || { echo "${o:-unreadable}"; fail "FAIL: not every Kustomization Ready within 10 min"; }
  sleep 15; done
echo "$o"; finish "every Kustomization Ready"
}
main </dev/null
OP
```

## Rollback A: only c1 changed (as the log decides)

1. **OP: block A.1** with `MODE=a`, refused unless the log calls for A. It plans c1 with `-var cni=flannel`, requires that the plan updates exactly c1, and applies it under 300 s. It uses c1's Talos API, not Kubernetes (the lab showed the delivery succeeding without etcd quorum). A failed apply → E1.
2. **VM**: `api_watch 10` and `etcd_ok` every minute for those 10 minutes: STABLE and OK → 3; ABORT → E5; etcd failing for 10 min → E4.
3. **VM**: `cni_gate flannel` → `GATE PASS (flannel)`.
4. **OP: block A.4**:
   - saves the agents' state (evidence only; every node reboots regardless);
   - requires the dry run to prune exactly Cilium's 33 objects (anything of Flannel or kube-proxy stops the window);
   - prunes (3 tries);
   - requires no `part-of=cilium` pod left, and removes Cilium's `agent-not-ready` taint.
6. **Node recovery**, every node, one at a time:
   - VM: `etcd_ok` around each CP.
   - OP: block 5.3; set `UNCORDONED=yes` only if the cordon fails and the rollback can't wait (it's logged).
   - OP: then block A.6b: that node's own kube-flannel pod Running and Ready within 10 min.
   - A `STOP:` → a CP whose Talos API doesn't answer: E1; a CP with etcd unhealthy: E4; else STOP.
   - Then block A.6 per node. Where `before:` lists anything `cilium`, run it again with `ACTION=repair`, which moves `*.cilium_bak` back and deletes Cilium's configs. `after:` must list only `10-flannel.conflist` and non-Cilium files.
7. **Rollback acceptance**, 60 minutes from its first block, independent of T0:
   - block A.7a: `cni-pods verify -cni flannel -cni0 none` (Flannel and kube-proxy Ready everywhere, no Cilium pod or taint, every workload ready) and the per-node probes;
   - blocks 6a, 6b and 6c with `COL=rollback`, plus the user's checks;
   - block T12, then the plain-plan block.
   - All pass → close #228. A failure or exit 124 → STOP; the cluster is on Flannel.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# A.1, B.1 rollback-apply · OP · MODE=a (c1) or b (every node) · expect: "rollback <mode> applied"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
MODE=a   # parameters
R=0; CAP="run this again: nodes already on Flannel plan no change"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
rt() { if [ -s "$S/applied" ] && [ -z "$(awk '$2 != "c1"' "$S/applied")" ]; then
  echo "Rollback A"; else echo "Rollback B"; fi; }
[ "$MODE" = a ] && [ "$(rt)" != "Rollback A" ] && { echo "REFUSED: the log calls for $(rt)"; exit 3; }
for N in $([ "$MODE" = a ] && echo c1 || echo c1 c2 c3 w1 w2); do
  case $N in c?) A="module.cluster.talos_machine.controlplane[\"$N.k8s.kalski.xyz\"]";;
    w?) A="module.cluster.talos_machine.worker[\"$N.k8s.kalski.xyz\"]";; *) echo "N?"; exit 2;; esac
  for try in 1 2; do
    w 300 terraform -chdir=local-talos plan -input=false -no-color -lock-timeout=60s -detailed-exitcode \
      -var cni=flannel -target="$A" -out="$S/$N.tfplan" >/dev/null; rc=$?
    [ $rc = 0 ] && { log "rollback $N: no change"; continue 2; }
    if [ $rc = 2 ]; then
      pj=$(w 120 terraform -chdir=local-talos show -json "$S/$N.tfplan") || fail "FAIL: reading $N's plan"
      pc=$(jq -r '.resource_changes[] | select(.change.actions != ["no-op"])
        | "\(.address) \(.change.actions | join(","))"' <<<"$pj") || fail "FAIL: parsing $N's plan"
      [ "$pc" = "$A update" ] || fail "FAIL: $N's rollback plan isn't exactly its update; STOP"
      log "attempt rollback $N"
      w 300 terraform -chdir=local-talos apply -input=false -no-color -lock-timeout=60s "$S/$N.tfplan" &&
        { log "rollback applied $N"; continue 2; }
    fi
    [ "$(date +%s)" -lt "$END" ] || fail ""
    case $N in c?) fail "ROUTE: $N's apply failed: E1 for $N (user)";; esac
    [ "$try" = 1 ] && { w 30 talosctl -n "10.10.10.2${N#w}" version; sleep 60; }
  done; fail "STOP: $N still fails; the control planes are on Flannel"
done
finish "rollback $MODE applied; VM: api_watch 10, etcd_ok, cni_gate flannel"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# A.4 rollback-prune · OP · expect: "Cilium pruned"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
w 60 kubectl -n kube-system get pods -l k8s-app=cilium -o json > "$S/agents-before-prune.json" || echo "WARN: agents"
tv=$(jq -er .kubernetes local-talos/versions.json) || fail "FAIL: reading versions.json"
o=$(w 300 talosctl -n 10.10.10.11 upgrade-k8s --to "$tv" --dry-run 2>&1) || fail "FAIL: the dry run: $o"; echo "$o"
got=$(awk '$1 == "<" && $2 == "Pruned" {print $3}' <<<"$o" | sort | paste -sd' ')
want=$(printf '%s\n' ClusterRoleBinding/{cilium,cilium-operator} ClusterRole/{cilium,cilium-operator} \
  ConfigMap/kube-system/{cilium-config,cilium-envoy-config,hubble-relay-config} \
  CronJob/kube-system/hubble-generate-certs Job/kube-system/hubble-generate-certs-ef4be98870 \
  DaemonSet/kube-system/{cilium,cilium-envoy} \
  Deployment/kube-system/{cilium-operator,hubble-relay} Namespace/cilium-secrets \
  {Role,RoleBinding}/cilium-secrets/{cilium-operator-tlsinterception-secrets,cilium-tlsinterception-secrets} \
  {Role,RoleBinding}/kube-system/{cilium-config-agent,cilium-operator-ztunnel,hubble-generate-certs} \
  ServiceAccount/kube-system/{cilium,cilium-envoy,cilium-operator,hubble-generate-certs,hubble-relay} \
  Service/kube-system/{cilium-envoy,hubble-metrics,hubble-peer,hubble-relay} | sort | paste -sd' ')
[ "$got" = "$want" ] || fail "FAIL: pruned: $got; STOP"
for t in 1 2 3; do w 600 talosctl -n 10.10.10.11 upgrade-k8s --to "$tv" && break
  [ "$t" = 3 ] && fail "STOP: the rollback prune failed 3 times"; done
o=$(w 30 kubectl get pods -A -l app.kubernetes.io/part-of=cilium -o name) || fail "FAIL: reading Cilium's pods"
[ -z "$o" ] || fail "FAIL: Cilium pods remain"
j=$(w 30 kubectl get nodes -o json) || fail "FAIL: reading the nodes"
n=$(jq -er '.items | arrays | map(select(any(.spec.taints[]?; .key == "node.cilium.io/agent-not-ready"))
  | .metadata.name) | join(" ")' <<<"$j") || fail "FAIL: parsing the nodes"
for x in $n; do w 30 kubectl taint nodes "$x" node.cilium.io/agent-not-ready- || fail "FAIL: taint on $x"; done
finish "Cilium pruned; next: 5.3 and A.6b for every node"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# A.6b flannel-wait · OP · N=<node>, after its rollback reboot · expect: "<node> kube-flannel Ready"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
N=w1   # parameters
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
F=$(( $(date +%s) + 600 )); [ "$F" -lt "$END" ] || F=$END   # 10 min for this node's own kube-flannel pod
q='[.items[] | select(any(.metadata.ownerReferences[]?; .name == "kube-flannel")
  and .status.phase == "Running" and any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length == 1'
while :; do r=no; j=$(w 30 kubectl -n kube-system get pods --field-selector spec.nodeName="$N" -o json) &&
    jq -e "$q" <<<"$j" >/dev/null && r=yes
  [ "$(date +%s)" -lt "$F" ] || fail "STOP: no Ready kube-flannel pod on $N within 10 min"
  [ $r = yes ] && break; sleep 10; done
finish "$N kube-flannel Ready"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# A.6 repair · OP · N=<node>; ACTION=inspect or repair · expect: "before:" and "after:" lines
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
N=c1; ACTION=inspect   # parameters
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
c=cni-repair-$N; w 40 kubectl -n kube-system delete pod $c --ignore-not-found --wait --timeout=30s >/dev/null ||
  echo "WARN: an old $c wasn't deleted"
sed -e s/NODE_NAME/$N/ -e s/ACTION_VALUE/$ACTION/ local-talos/cni-repair.yaml | w 30 kubectl create -f - >/dev/null &&
  w 180 kubectl -n kube-system wait pod/$c --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m >/dev/null &&
  o=$(w 30 kubectl -n kube-system logs $c); rc=$?
x 60 kubectl -n kube-system delete pod $c --wait >/dev/null
if [ "$rc" != 0 ] || ! grep -q '^after:' <<<"$o"; then fail "FAIL: the repair pod: $o"; fi
echo "$o"; finish "repair $N $ACTION"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# A.7a rollback-verify · OP · within rollback acceptance's 60 min (from its first block) · expect: "rollback verified"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
[ -s "$S/ra0" ] || date +%s > "$S/ra0"; R=$(rd ra0) || exit 3; R=$(( R + 3600 ))
DL="rollback acceptance's 60 min ended: STOP (on Flannel)"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
bad=0; w 900 cni-pods verify -cni flannel -cni0 none || bad=1
probe() {  # a pod on NODE reaches DNS, Traefik and CoreDNS
  local p o rc; p=probe-$1-$(date +%s)
  w 30 kubectl -n kube-system create -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: Pod
metadata: {name: $p}
spec:
  nodeName: $1
  restartPolicy: Never
  tolerations: [{operator: Exists}]
  containers:
  - name: probe
    image: busybox:1.37
    command: [sh, -c, 'echo ip=\$(hostname -i); timeout 5 nslookup kubernetes.default.svc.cluster.local
      10.96.0.10 >/dev/null && echo ok; nc -w 3 -z $tr 80 && echo ok; nc -w 3 -z $dns 53 && echo ok']
EOF
  w 90 kubectl -n kube-system wait "pod/$p" --for=jsonpath='{.status.phase}'=Succeeded --timeout=80s >/dev/null &&
    o=$(w 30 kubectl -n kube-system logs "$p"); rc=$?
  x 30 kubectl -n kube-system delete pod "$p" --wait=false >/dev/null
  echo "$1: $(tr '\n' ' ' <<<"$o")"; [ "$rc" = 0 ] && [ "$(grep -cx ok <<<"$o")" = 3 ] && return 0
  grep -qE 'ip=10\.244\.[0-9]+\.1$' <<<"$o" && return 2; return 1; }  # 2: its node's cni0 address, retry
tr=$(w 30 kubectl -n traefik get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}') &&
  [ -n "$tr" ] || fail "FAIL: reading Traefik's pod"
dj=$(w 30 kubectl -n kube-system get pods -l k8s-app=kube-dns -o json) || fail "FAIL: reading CoreDNS"
for n in c1 c2 c3 w1 w2; do
  dns=$(jq -er --arg n $n '[.items[] | select(.spec.nodeName != $n and .status.phase == "Running")][0]
    .status.podIP' <<<"$dj") || fail "FAIL: no CoreDNS pod off $n"
  for try in 1 2 3; do probe $n; rc=$?; [ $rc = 2 ] && [ $try -lt 3 ] && continue; [ $rc = 0 ] || bad=1; break; done
done
[ $bad = 0 ] || fail "FAIL: STOP, the cluster is on Flannel"; finish "rollback verified"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# plain-plan · OP · after a rollback, or after M3 once #228 merged and 0.0 ran again · expect: "no changes"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
R=0
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
w 600 terraform -chdir=local-talos plan -input=false -no-color -lock-timeout=60s -detailed-exitcode >/dev/null ||
  fail "FAIL: a plain plan has changes or failed"; finish "no changes"
}
main </dev/null
OP
```

**Rollback B: a node beyond c1 may have changed, or there is no log.**
1. OP: block A.1 with `MODE=b`: c1–c3, then w1, w2, each from its own targeted `-var cni=flannel` plan. A node already on Flannel is skipped. A CP failure → E1; a worker's apply is retried once after 60 s, then STOP. Exit 125 → run it again.
2. VM: `api_watch 10` with `etcd_ok`, as A.2.
3. `cni_gate flannel`, and Talos has recreated `kube-flannel` and `kube-proxy`.
4. Rollback A steps 4–7.

**Policy during rollback** isn't continuously enforced: new and restarted pods get ADR 4's first-packet window; in every lab rollback, one policed probe per worker got through once during the reboots.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# status · OP · read-only · expect: the window SHA, T0, the applied-node log and the rollback it calls for
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
rt() { if [ -s "$S/applied" ] && [ -z "$(awk '$2 != "c1"' "$S/applied")" ]; then
  echo "Rollback A"; else echo "Rollback B"; fi; }
# No deadline: it changes nothing, and the log it reads gives the same answer whenever it is read.
echo "window SHA $(cat "$S/window-sha")"; [ -s "$S/t0" ] && echo "T0 $(date -u -d "@$(cat "$S/t0")" +%FT%TZ)"
cat "$S/applied" 2>/dev/null; rt; tail -n 15 "$S/log" 2>/dev/null; exit 0
}
main </dev/null
OP
```

## Escalation

Never act on more than one control plane at a time. Every row ends in recovery or STOP.

| # | Condition | Action | Terminal |
|---|---|---|---|
| E1 | a CP's Talos API unreachable (`talosctl -n <ip> version` fails twice, 30 s apart) | UART: read the console for 5 min (kernel panic, `macb`/`end0` errors, boot loop); no input beyond Enter | Console shows a hung or panicked kernel → E2. Console shows the node running, or no console output at all in the 5 min → STOP. |
| E2 | E1 found a hung/panicked kernel, and `etcd_two_ok <ip-a> <ip-b>` passes for the other two CPs (both answer, no errors, agree on a leader that is one of them; membership is never health) | OP: block E2 on that Pi: its `ops-poe-cycle-<node>` script on kuberack turns its port off for 10 s. Data on NVMe is untouched. At most once per Pi per window: the block refuses a second (the router doesn't enforce it), and refuses while the Pi's Talos API answers. | `etcd_two_ok` fails → STOP, no power cycle. Talos API back and `etcd_ok` within 10 min → resume where the rollback was. Not back, boots but stays networkless, or no console output → STOP. |
| E4 | Talos answers but etcd is unhealthy on one CP for 10 min, and `etcd_two_ok` passes for the other two | OP: block 5.3 on that CP | `etcd_ok` within 10 min → resume; otherwise, or quorum lost → STOP |
| E5 | Talos and etcd healthy, the Kubernetes API down for 10 min | VM: `talosctl -n $CPS service kubelet`, `talosctl -n $CPS containers -k \| grep apiserver`. OP: block E5 on the VIP holder: no Kubernetes call (nothing can be cordoned with the API down). It's refused unless the other two etcd members are healthy (`etcd_two_ok`) and the target's Talos API answers; the reboot is proven by boot ID within 15 min | VM `etcd_ok`, then `api_watch 10` STABLE → resume. Refused, no new boot ID, or the API stays down → STOP |

E1 is the user's (UART); E2 is OP's block once the user reports E1's verdict.

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# E2 poe-cycle · OP · N=<the hung CP>, after the user's E1 · expect: "<node> power-cycled and back"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
N=c1   # parameters
R=0; CAP="$N's PoE cycle may have run: never cycle it again; check its boot ID and Talos API"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
[ -r "$O/routeros.netrc" ] || { echo "REFUSED: no $O/routeros.netrc: run ops-routeros (or block 0.8)"; exit 3; }
case $N in c1) ip=10.10.10.11 p=ether4;; c2) ip=10.10.10.12 p=ether5;; c3) ip=10.10.10.13 p=ether6;;
  *) echo "N?"; exit 2;; esac
! grep -q " poe-cycle $N\$" "$S/log" 2>/dev/null || fail "STOP: $N was power-cycled in this window already"
two=$(printf '%s\n' 10.10.10.11 10.10.10.12 10.10.10.13 | grep -vx "$ip" | paste -sd,)
for t in 1 2 3; do  # the other two answer, without errors, and agree on a leader among them
  o=$(w 30 talosctl -n "$two" etcd status 2>&1) && l=$(awk 'NR>1 && NF {print $(NF-6)}' <<<"$o" | sort -u) &&
  [ "$(awk 'NR>1 && NF' <<<"$o" | wc -l)" = 2 ] &&
  awk 'NR>1 && NF {if ($NF !~ /^[0-9.]+$/) b++} END {exit b}' <<<"$o" &&
  [ "$(wc -l <<<"$l")" = 1 ] && [ "$l" != 0000000000000000 ] && awk 'NR>1 && NF {print $2}' <<<"$o" | grep -qx "$l" &&
  break
  [ "$t" = 3 ] && fail "STOP: the other two etcd members aren't healthy; no power cycle"; sleep 30; done
! w 30 talosctl -n "$ip" version >/dev/null 2>&1 || fail "ROUTE: $N's Talos API answers: not E2 (E1, E4 or E5)"
k=(-sS --fail-with-body --netrc-file "$O/routeros.netrc" -H 'content-type: application/json'
  --resolve kuberack.networking.kalski.xyz:443:10.10.10.1); r=https://kuberack.networking.kalski.xyz/rest
pm() { w 20 curl "${k[@]}" "$r/interface/ethernet/poe/monitor" -d "{\"numbers\":\"$p\",\"once\":\"\"}" |
  jq -er '.[0]["poe-out-status"]'; }
s0=$(pm) || fail "STOP: can't read $p's PoE status; no power cycle"
[ "$s0" = powered-on ] || fail "STOP: $p is $s0, not powered-on; no power cycle"
log "poe-cycle $N"   # before the cycle: an attempt counts, as it may have run
w 30 curl "${k[@]}" "$r/system/script/run" -d "{\".id\":\"ops-poe-cycle-$N\"}" >/dev/null ||
  echo "WARN: the script call failed; it may still have run"
sleep 2; s1=$(pm) || s1=unread; echo "$p: $s0, then $s1"
W=$(( $(date +%s) + 600 )); [ "$W" -lt "$END" ] || W=$END   # E2's 10 min for the Talos API to come back
while :; do t=$(( W - $(date +%s) )); [ "$t" -gt 0 ] || fail "STOP: $N's Talos API isn't back 10 min after its cycle"
  [ "$t" -gt 15 ] && t=15; b=$(x "$t" talosctl -n "$ip" read /proc/sys/kernel/random/boot_id 2>/dev/null) || b=
  [ -n "$b" ] && break; sleep 10; done
finish "$N power-cycled and back (boot ID $b); VM: etcd_ok"
}
main </dev/null
OP
```

```sh
trap 'exit 143' TERM INT HUP   # any cancel exits 143
[ -s ~/cutover/profile-path ] && [ "$(readlink -f ~/cutover/dev-profile)" = "$(cat ~/cutover/profile-path)" ] ||
  { echo "REFUSED: the saved profile changed or is missing (0.0)"; exit 3; }
CUTOVER_START=$(date +%s) env -u BASH_ENV nix develop "$(cat ~/cutover/profile-path)" --offline \
  --command env -u BASH_ENV bash --noprofile --norc -s <<'OP'
# E5 api-down-reboot · OP · N=<VIP holder CP>; no Kubernetes call · expect: "<node> rebooted (boot ID …)"
main() {
set -uo pipefail; export LC_ALL=C; S=~/cutover
if ! cd ~/config/infra || ! exec 9>>"$S/lock"; then echo "REFUSED: no $S (0.0 first)"; exit 3; fi
flock -n 9 || { echo "REFUSED: another step is running"; exit 3; }
if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(cat "$S/window-sha")" ]; then
  echo "REFUSED: not a clean checkout at the window SHA"; exit 3; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$S/log"; }
kj() { local p; for p in $(jobs -p); do kill "$p" 2>/dev/null; done; }; trap kj EXIT
stop() { kj; exit 143; }; trap stop TERM INT HUP
x() { trap stop TERM INT HUP; timeout "$@" 9>&- 0<&0 & wait $!; }
rd() { local v; v=$(cat "$S/$1" 2>/dev/null) && [[ $v =~ ^[0-9]+$ ]] && echo "$v"; }  # an epoch saved in $S
N=c2   # parameters
R=0; CAP="the reboot of $N may have started: check its boot ID; never reboot it again blindly"
O=/run/ops-credentials
export KUBECONFIG=$O/kubeconfig TALOSCONFIG=$O/talosconfig GOOGLE_APPLICATION_CREDENTIALS=$O/gcp.json
for f in kubeconfig talosconfig gcp.json; do [ -r "$O/$f" ] && continue; h="check ops-credentials.service"
  [ $f = kubeconfig ] && h="run ops-kubeconfig"; echo "REFUSED: no $O/$f: $h"; exit 3; done
END=$(( ${CUTOVER_START:?} + 1740 )); BY=cap; [ "$R" -gt 0 ] && [ "$R" -le "$END" ] && { END=$R; BY=runbook; }
w() { local t=$(( END - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
fail() { if [ "$(date +%s)" -ge "$END" ]; then
    [ "$BY" = cap ] && { echo "STEP CAP: ${CAP:-29 min used: run this step again}"; exit 125; }
    echo "DEADLINE: $DL"; exit 124; fi; echo "$*"; exit 1; }
finish() { [ "$(date +%s)" -lt "$END" ] || fail ""; log "$*"; echo "$*"; exit 0; }
case $N in c1) ip=10.10.10.11;; c2) ip=10.10.10.12;; c3) ip=10.10.10.13;;
  w1) ip=10.10.10.21;; w2) ip=10.10.10.22;; *) echo "N?"; exit 2;; esac
case $N in c?) ;; *) exit 2;; esac
two=$(printf '%s\n' 10.10.10.11 10.10.10.12 10.10.10.13 | grep -vx "$ip" | paste -sd,)
for t in 1 2 3; do  # the other two answer, without errors, and agree on a leader among them
  o=$(w 30 talosctl -n "$two" etcd status 2>&1) && l=$(awk 'NR>1 && NF {print $(NF-6)}' <<<"$o" | sort -u) &&
  [ "$(awk 'NR>1 && NF' <<<"$o" | wc -l)" = 2 ] &&
  awk 'NR>1 && NF {if ($NF !~ /^[0-9.]+$/) b++} END {exit b}' <<<"$o" &&
  [ "$(wc -l <<<"$l")" = 1 ] && [ "$l" != 0000000000000000 ] && awk 'NR>1 && NF {print $2}' <<<"$o" | grep -qx "$l" &&
  break
  [ "$t" = 3 ] && fail "STOP: the other two etcd members aren't healthy; no reboot"; sleep 30; done
w 30 talosctl -n "$ip" version >/dev/null || fail "ROUTE: $N's Talos API doesn't answer: E1 (user), not E5"
b0=$(w 30 talosctl -n "$ip" read /proc/sys/kernel/random/boot_id) || fail "STOP: can't read $N's boot ID"
[ -n "$b0" ] || fail "STOP: can't read $N's boot ID"
W=$(( $(date +%s) + 900 )); [ "$W" -lt "$END" ] || W=$END   # one 15-min wait: reboot, new boot ID, Ready
v() { local t=$(( W - $(date +%s) )); [ "$t" -gt 0 ] || return 124; [ "$t" -gt "$1" ] && t=$1
  shift; x "$t" "$@"; }
v 600 talosctl -n "$ip" reboot --wait --timeout 9m || echo "WARN: talosctl reboot exited $?; checking the boot ID"
while :; do b=$(v 15 talosctl -n "$ip" read /proc/sys/kernel/random/boot_id 2>/dev/null) || b=
  [ "$(date +%s)" -lt "$W" ] || fail "STOP: $N's boot ID is unchanged 15 min after the reboot: it didn't reboot"
  [ -n "$b" ] && [ "$b" != "$b0" ] && break; sleep 10; done
finish "$N rebooted (boot ID $b); VM: etcd_ok, then api_watch 10"
}
main </dev/null
OP
```

**STOP** means hands-on recovery by the user: no further changes. The incident log keeps `~/cutover/applied`, `~/cutover/log`, the last outputs and the console captures.

ADR 1 covers selecting a UKI over UART and reinstalling; this runbook doesn't automate either, and JetKVM is for console access only. STOP applies whenever any of these holds, and is the default for any failure this runbook doesn't classify:
- two CPs are down at once;
- etcd has no quorum for 10 min;
- a Pi needs a second power cycle;
- a node boots but stays networkless;
- any row's terminal says so.

## Evidence and limits

Lab (GitHub runners, QEMU, 3 CPs + 2 workers): #219, #220, #229, #231, #242; ADR 11.

The `cilium-cutover-runbook` flake check, which CI runs, extracts every OP block from this file. It shellchecks each one and runs it exactly as written, wrapper included, against stubbed cluster tools; see `cilium-cutover-tests/`.

Untested:
- the Pi 5 arm64 datapath (gated above);
- production timing;
- production webhooks, APIServices and Harbor data (section 6 checks them);
- StatefulSets with peer-dependent readiness (none in production);
- endpoint identity while the API is down;
- a real PoE power cycle through block E2 (0.8 reads the ports and scripts; ops' access was checked read-only);
- `etcd_ok` with an unhealthy member (it was run against a healthy cluster only).
- the blocks against a live cluster: the lab rehearses the same `cni-pods` code, manifests and reboot sequence through its own Go harness.
