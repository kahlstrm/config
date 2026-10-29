#!/usr/bin/env bash
# Runs an orb through the dispatch program's lifecycle under QEMU/KVM, with the
# disks it attaches (state, swap, token), and a listener standing in for Amp:
#   1. cold boot with token A: bootstrap reaches AMP_URL with A;
#   2. pause: the power button hibernates the VM, which powers off;
#   3. resume with token B: the kernel restores the image instead of booting
#      (the guest keeps its boot_id), and bootstrap reconnects with B;
#   4. stay up past the TCO watchdog's timeout, then pause and resume again,
#      which needs hibernation to work a second time, without a clock stall
#      or skew from the time the orb ran before;
#   5. pause with hibernation failing (swap off): the VM still powers off;
#   6. spawn a new image with token C: a cold boot that keeps /home but not the
#      old system layer.
# Prints the time each step took.
set -euo pipefail
out=$(cd "$1" && pwd)
work=$(mktemp -d)
port=18080
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT

python3 -c '
import hashlib, http.server, sys, time
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        print(time.monotonic(), self.path, hashlib.sha256(auth.encode()).hexdigest()[:12], flush=True)
        self.send_response(503); self.end_headers()
    do_POST = do_GET
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
' "$port" >"$work/requests.log" &

token_disk() {
  mkdir -p "$work/env-$1"
  printf '%s' "$1" >"$work/env-$1/ORB_TOKEN"
  printf "http://10.0.2.2:$port" >"$work/env-$1/AMP_URL"
  xorriso -as mkisofs -quiet -o "$work/env-$1.iso" "$work/env-$1" 2>/dev/null
}
token_disk token-a
token_disk token-b
token_disk token-c
token_disk token-d
truncate -s 4G "$work/state.img"
truncate -s 5G "$work/swap.img"

now() { python3 -c 'import time; print(time.monotonic())'; }

image=test
# The dispatch program's kernel arguments. kvm-clock never runs backwards, so after
# restoring into a new VM, whose clock starts near zero, the guest would stall for
# as long as it had run before the pause; the TSC clocksource is rebased instead.
kernel_args="root=LABEL=orb-root ro console=ttyS0 quiet clocksource=tsc tsc=reliable"
boot() { # boot <token> <kernel args>
  rm -f "$work/qmp.sock" "$work/qga.sock"
  qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -m 4096 -smp 2 -nographic -no-reboot \
    -qmp "unix:$work/qmp.sock,server=on,wait=off" \
    -chardev "socket,path=$work/qga.sock,server=on,wait=off,id=qga" -device virtio-serial \
    -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0 \
    -kernel "$out/vmlinuz" -initrd "$out/initrd.img" \
    -append "$kernel_args orb.image=$image $2" \
    -drive "file=$out/disk.qcow2,if=virtio,snapshot=on,readonly=on" \
    -drive "file=$work/state.img,if=none,id=state,format=raw,discard=unmap" -device virtio-blk-pci,drive=state,serial=state \
    -drive "file=$work/swap.img,if=none,id=swap,format=raw,discard=unmap" -device virtio-blk-pci,drive=swap,serial=swap \
    -drive "file=$work/env-$1.iso,if=none,id=env,format=raw,readonly=on" -device virtio-blk-pci,drive=env,serial=orbenv \
    -nic user,model=virtio-net-pci >>"$work/console.log" 2>&1 &
  qemu=$!
}

await_request() { # await_request <token> <since>
  local hash
  hash=$(printf 'Bearer %s' "$1" | sha256sum | cut -c1-12)
  for _ in $(seq 600); do
    if awk -v since="$2" -v hash="$hash" '$1 > since && $3 == hash { found = 1 } END { exit !found }' "$work/requests.log"; then
      awk -v since="$2" -v hash="$hash" '$1 > since && $3 == hash { print $1; exit }' "$work/requests.log"
      return 0
    fi
    kill -0 "$qemu" 2>/dev/null || break
    sleep 0.2
  done
  tail -n 40 "$work/console.log" >&2
  diagnose >&2
  echo "bootstrap never reached AMP_URL with $1" >&2
  return 1
}

fail() { tail -n 40 "$work/console.log" >&2; diagnose >&2; echo "$1" >&2; exit 1; }

guest_exec() { # runs a shell command in the guest through the QEMU guest agent
  python3 - "$work/qga.sock" "$1" <<'PY'
import base64, json, random, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sys.argv[1]); f = s.makefile("rw")
token = random.randrange(1 << 30)
f.write(json.dumps({"execute": "guest-sync", "arguments": {"id": token}}) + "\n"); f.flush()
while json.loads(f.readline()).get("return") != token:
    pass
def call(cmd, **args):
    f.write(json.dumps({"execute": cmd, "arguments": args}) + "\n"); f.flush()
    return json.loads(f.readline())["return"]
pid = call("guest-exec", path="/bin/sh", arg=["-c", sys.argv[2]], **{"capture-output": True})["pid"]
while not (status := call("guest-exec-status", pid=pid))["exited"]:
    time.sleep(0.2)
print(base64.b64decode(status.get("out-data", "")).decode(errors="replace"), end="")
print(base64.b64decode(status.get("err-data", "")).decode(errors="replace"), end="")
PY
}

diagnose() { # prints the guest's state when a step fails, if its agent answers
  kill -0 "$qemu" 2>/dev/null || { echo "### QEMU has exited"; return 0; }
  for command in "ip -br addr" "ip route" \
    "journalctl -b --no-pager -o short-monotonic -n 80 -u amp-headless-bootstrap -u systemd-networkd -u systemd-hibernate -u amp-orb-cli-update"; do
    echo "### $command"; guest_exec "$command" || true
  done
}

boot_id() { # reads the guest's boot_id through the QEMU guest agent, waiting for it
  python3 - "$work/qga.sock" <<'PY'
import base64, json, random, socket, sys, time
def connect():
    # guest-sync with a fresh id skips replies to requests an earlier attempt left behind.
    s = socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1]); f = s.makefile("rw")
    token = random.randrange(1 << 30)
    f.write(json.dumps({"execute": "guest-sync", "arguments": {"id": token}}) + "\n"); f.flush()
    while json.loads(f.readline()).get("return") != token:
        pass
    return s, f
for _ in range(300):
    try:
        s, f = connect(); break
    except (OSError, ValueError):
        time.sleep(0.2)
else:
    sys.exit("the guest agent did not answer")
s.settimeout(10)
def call(cmd, **args):
    f.write(json.dumps({"execute": cmd, "arguments": args}) + "\n"); f.flush()
    reply = json.loads(f.readline())
    if "error" in reply: sys.exit(reply["error"])
    return reply["return"]
handle = call("guest-file-open", path="/proc/sys/kernel/random/boot_id")
print(base64.b64decode(call("guest-file-read", handle=handle)["buf-b64"]).decode().strip())
call("guest-file-close", handle=handle)
PY
}

start=$(now)
boot token-a ""
first=$(await_request token-a "$start")
printf 'cold boot: bootstrap reached AMP_URL after %.1f s\n' "$(echo "$first - $start" | bc)"
before=$(boot_id) || fail "the guest agent did not answer"
guest_exec 'true' >/dev/null
python3 - "$work/qga.sock" <<'PY' || fail "the guest agent accepts guest-shutdown, so KubeVirt would power the orb off instead of hibernating it"
import json, random, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1]); f = s.makefile("rw")
token = random.randrange(1 << 30)
f.write(json.dumps({"execute": "guest-sync", "arguments": {"id": token}}) + "\n"); f.flush()
while json.loads(f.readline()).get("return") != token:
    pass
f.write(json.dumps({"execute": "guest-shutdown", "arguments": {"mode": "powerdown"}}) + "\n"); f.flush()
sys.exit(0 if "error" in json.loads(f.readline()) else 1)
PY

paused=$(now)
printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n' | socat -t 2 - "UNIX-CONNECT:$work/qmp.sock" >/dev/null
for _ in $(seq 600); do kill -0 "$qemu" 2>/dev/null || break; sleep 0.2; done
kill -0 "$qemu" 2>/dev/null && fail "the VM did not power off after the power button"
[ "$(du -k "$work/swap.img" | cut -f1)" -gt 10240 ] || fail "the power button shut the VM down without hibernating"
grep -aq 'amp-orb: hibernating' "$work/console.log" || fail "the console does not say the orb hibernated"
printf 'pause: hibernated and powered off after %.1f s\n' "$(echo "$(now) - $paused" | bc)"
printf 'pause: swap disk holds %s of the memory image\n' "$(du -h "$work/swap.img" | cut -f1)"
[ "$(du -k "$work/swap.img" | cut -f1)" -lt 131072 ] || fail "the memory image kept the page cache"

resumed=$(now)
boot token-b "resume=/dev/disk/by-id/virtio-swap"
after=$(boot_id) || fail "the guest agent did not answer after resuming"
printf 'resume: guest running again after %.1f s\n' "$(echo "$(now) - $resumed" | bc)"
second=$(await_request token-b "$resumed")
[ "$before" = "$after" ] || fail "the VM booted instead of resuming (boot_id changed)"
grep -aq 'amp-orb: resumed' "$work/console.log" || fail "the console does not say the orb resumed"
printf 'resume: restored, bootstrap reconnected with the new token after %.1f s\n' "$(echo "$second - $resumed" | bc)"
for _ in $(seq 50); do [ "$(du -k "$work/swap.img" | cut -f1)" -lt 10240 ] && break; sleep 0.2; done
printf 'resume: swap disk holds %s after the image was freed\n' "$(du -h "$work/swap.img" | cut -f1)"
[ "$(du -k "$work/swap.img" | cut -f1)" -lt 10240 ] || fail "the hibernation image still occupies the swap disk"

sleep 40
kill -0 "$qemu" 2>/dev/null || fail "the VM went off after resuming"
paused=$(now)
printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n' | socat -t 2 - "UNIX-CONNECT:$work/qmp.sock" >/dev/null
for _ in $(seq 600); do kill -0 "$qemu" 2>/dev/null || break; sleep 0.2; done
kill -0 "$qemu" 2>/dev/null && fail "the VM did not power off at the second pause"
[ "$(grep -ac 'amp-orb: hibernating' "$work/console.log")" = 2 ] || fail "the second pause did not hibernate"
printf 'second pause: hibernated and powered off after %.1f s\n' "$(echo "$(now) - $paused" | bc)"
resumed=$(now)
boot token-d "resume=/dev/disk/by-id/virtio-swap"
[ "$(boot_id)" = "$before" ] || fail "the second resume booted instead"
fourth=$(await_request token-d "$resumed")
printf 'second resume: reconnected with the new token after %.1f s\n' "$(echo "$fourth - $resumed" | bc)"
[ "$(echo "$fourth - $resumed < 20" | bc)" = 1 ] || fail "the second resume stalled until the clock caught up"
skew=$(( $(guest_exec 'date +%s') - $(date +%s) ))
[ "${skew#-}" -le 2 ] || fail "the resumed guest's clock is ${skew} s off"
guest_exec 'echo kept >/home/user/orb-smoke && echo dropped >/etc/orb-smoke && swapoff -a' >/dev/null
paused=$(now)
printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n' | socat -t 2 - "UNIX-CONNECT:$work/qmp.sock" >/dev/null
for _ in $(seq 600); do kill -0 "$qemu" 2>/dev/null || break; sleep 0.2; done
kill -0 "$qemu" 2>/dev/null && fail "the VM stayed on when hibernating failed"
printf 'pause without swap: powered off after %.1f s\n' "$(echo "$(now) - $paused" | bc)"

image=test-2
started=$(now)
boot token-c ""
third=$(await_request token-c "$started")
[ "$(boot_id)" != "$after" ] || fail "the new image resumed instead of booting"
printf 'new image: cold boot reached AMP_URL after %.1f s\n' "$(echo "$third - $started" | bc)"
[ "$(guest_exec 'cat /home/user/orb-smoke; test -e /etc/orb-smoke && echo stale')" = kept ] ||
  fail "the new image did not keep /home or kept the old system layer"
echo "new image: kept /home, dropped the old system layer"
guest_exec '/home/user/.amp/bin/amp --version' | grep -q . || fail "the orb's Amp CLI does not run"
for _ in $(seq 150); do
  [ -z "$(guest_exec 'ls -A /run/orb/state/trash')" ] && break
  sleep 0.2
done
[ -z "$(guest_exec 'ls -A /run/orb/state/trash')" ] || fail "the old system layer was not deleted after boot"
echo "new image: Amp CLI runs, old system layer deleted after boot"
[ "$(guest_exec 'findmnt -n -o FSTYPE /var/lib/containerd; stat -c %U /run/docker.sock')" = "ext4
user" ] || fail "containerd's store is not on the state disk or the user does not own Docker's socket"
node=$(guest_exec 'mkdir -p /tmp/n24 && cd /tmp/n24 &&
  echo "{\"devEngines\":{\"runtime\":{\"name\":\"node\",\"version\":\"^24\"}}}" >package.json &&
  runuser -u user -- bash -lc "node --version"')
[ "${node%%.*}" = v24 ] || fail "a project asking for Node.js 24 runs $node"
echo "new image: containerd store on the state disk, Docker socket owned by the user, Node.js per project"
