#!/usr/bin/env bash
# Boots the built image with an empty home disk and a token disk, attached the
# way the dispatch program attaches them, and passes when Amp's bootstrap sends
# its first request to AMP_URL, which points at a listener on the host.
set -euo pipefail
out=$(cd "$1" && pwd)
work=$(mktemp -d)
port=18080
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT

python3 -c '
import http.server, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.record()
    def do_POST(self): self.record()
    def record(self):
        print(self.command, self.path, flush=True)
        self.send_response(503); self.end_headers()
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
' "$port" >"$work/requests.log" 2>/dev/null &

mkdir "$work/env"
printf dummy >"$work/env/ORB_TOKEN"
printf "http://10.0.2.2:$port" >"$work/env/AMP_URL"
xorriso -as mkisofs -quiet -o "$work/env.iso" "$work/env" 2>/dev/null
truncate -s 2G "$work/home.img"

qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -m 4096 -smp 2 -nographic -no-reboot \
  -kernel "$out/vmlinuz" -initrd "$out/initrd.img" -append "root=LABEL=orb-root rw console=ttyS0" \
  -drive "file=$out/disk.qcow2,if=virtio,snapshot=on" \
  -drive "file=$work/home.img,if=none,id=home,format=raw" -device virtio-blk-pci,drive=home,serial=home \
  -drive "file=$work/env.iso,if=none,id=env,format=raw,readonly=on" -device virtio-blk-pci,drive=env,serial=orbenv \
  -nic user,model=virtio-net-pci >"$work/console.log" 2>&1 &

for _ in $(seq 150); do
  if [ -s "$work/requests.log" ]; then
    echo "bootstrap reached AMP_URL with the token disk's settings: $(head -n 1 "$work/requests.log")"
    exit 0
  fi
  sleep 2
done
grep -a -E 'FAILED|ALERT' "$work/console.log" || tail -n 40 "$work/console.log"
echo "bootstrap never reached AMP_URL" >&2
exit 1
