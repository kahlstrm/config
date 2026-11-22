//go:build integration

package talos_test

import (
	"cmp"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

const (
	// Under runsc-docker, a pod's own Docker; the netpol canary's busybox
	// runs as its nested container.
	dindImage = "docker:29.10.0-dind"
	// Has Python, for the packet-socket check.
	socketImage = "nicolaka/netshoot:v0.14"
)

// Each pod prints its kernel and whether it may write to a packet socket on
// its own interface: an unused EtherType, broadcast onto the pod network.
const socketScript = `
import socket
print("kernel:", open("/proc/version").read().strip())
try:
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    s.bind(("eth0", 0))
    s.send(b"\xff" * 6 + b"\x02\x00\x00\x00\x00\x01" + b"\x88\xb5" + b"talos-lab" * 6)
    print("packet-write: allowed")
except OSError as e:
    print("packet-write: denied", e.errno, e.strerror)
`

// Docker in the sandbox as gVisor's Docker guide starts it
// (images/basic/docker/start-dockerd.sh): its storage on a tmpfs, its own
// NAT instead of Docker's iptables rules, and the pod's MTU.
const dockerScript = `
set -eu
trap 'echo "== dockerd log"; tail -n 40 /tmp/dockerd.log' EXIT
echo "kernel: $(cat /proc/version)"
mkdir -p /var/lib/docker
mount -t tmpfs -o size=2g tmpfs /var/lib/docker
addr=$(ip -4 addr show dev eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
mtu=$(cat /sys/class/net/eth0/mtu)
echo 1 > /proc/sys/net/ipv4/ip_forward
ipt=iptables; command -v iptables-legacy >/dev/null && ipt=iptables-legacy
$ipt -t nat -A POSTROUTING -o eth0 -j SNAT --to-source "$addr" -p tcp
$ipt -t nat -A POSTROUTING -o eth0 -j SNAT --to-source "$addr" -p udp
dockerd --host=unix:///var/run/docker.sock --iptables=false --ip6tables=false --mtu="$mtu" >/tmp/dockerd.log 2>&1 &
for i in $(seq 90); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info --format 'dockerd: {{.ServerVersion}} storage={{.Driver}}'
docker run --rm %[1]s echo nested-container: ok
docker run --rm %[1]s wget -q -T 10 -O /dev/null http://%[2]s/ && echo nested-egress: ok
`

// TestGvisor boots production's orb_worker schematic with
// orb-gvisor-worker.yaml on the worker and checks both runtime handlers:
// runsc as Talos's gVisor extension ships it, and runsc-docker with raw
// sockets and packet-socket writes, under which dockerd runs.
func TestGvisor(t *testing.T) {
	b := newBench(t, "gvisor", setup{
		initramfs: "gvisor/initramfs-amd64.xz",
		patches: func(t *testing.T, p lab.Production, _ string) lab.Patches {
			patches := baselinePatches(t, p, "")
			// gVisor needs user namespaces, which production's workers allow.
			// orb-dedicated-worker.yaml's taint is left out: the bench's
			// probes run on the worker.
			return patches.With(lab.Patches{Worker: []string{
				p.Path("local-talos", "patches", "userns-worker.yaml"),
				p.Path("local-talos", "patches", "orb-gvisor-worker.yaml"),
			}})
		},
	})

	schematic := b.schematic()
	extensions, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "get", "extensions", "-o", "yaml")
	must(t, err)
	fmt.Fprintf(b.results, "== worker extensions (schematic %s)\n%s\n", schematic, extensions)
	if !strings.Contains(extensions, "name: gvisor") || !strings.Contains(extensions, schematic) {
		t.Errorf("worker does not run the gvisor extension of schematic %s", schematic)
	}
	for file, want := range map[string]string{
		"/proc/sys/vm/max_map_count": "4194304",
		"/etc/runsc-docker.toml":     `allow-packet-socket-write = "true"`,
		"/etc/cri/conf.d/cri.toml":   "runtimes.runsc-docker.options",
	} {
		value, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "read", file)
		must(t, err)
		fmt.Fprintf(b.results, "== worker %s\n%s\n", file, value)
		if !strings.Contains(value, want) {
			t.Errorf("worker %s lacks %q", file, want)
		}
	}

	b.kubectl(b.manifest("gvisor.yaml"), "apply", "-f", "-")
	host, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "read", "/proc/version")
	must(t, err)
	host = strings.TrimSpace(host)
	for _, c := range []struct {
		runtime string
		write   string
	}{{"", "allowed"}, {"gvisor", "denied"}, {"gvisor-docker", "allowed"}} {
		name := "sockets-" + cmp.Or(c.runtime, "runc")
		log := b.gvisorPod(name, c.runtime, socketImage, []string{"python3", "-c", socketScript}, "NET_RAW")
		sandboxed := !strings.Contains(log, "kernel: "+host)
		if sandboxed != (c.runtime != "") {
			t.Errorf("%s: sandboxed=%t, want %t; host kernel %q", name, sandboxed, c.runtime != "", host)
		}
		if !strings.Contains(log, "packet-write: "+c.write) {
			t.Errorf("%s: packet-socket write not %s", name, c.write)
		}
	}

	docker := fmt.Sprintf(dockerScript, b.image, externalIP)
	log := b.gvisorPod("docker", "gvisor-docker", dindImage, []string{"sh", "-c", docker}, "ALL")
	for _, want := range []string{"nested-container: ok", "nested-egress: ok"} {
		if !strings.Contains(log, want) {
			t.Errorf("dockerd under gvisor-docker: no %q", want)
		}
	}
	if strings.Contains(log, "kernel: "+host) {
		t.Error("the docker pod ran on the host kernel, not in gVisor")
	}
}

// schematic is the Image Factory ID of production's orb_worker schematic,
// which must be the one the lab's initramfs was built from.
func (b *bench) schematic() string {
	b.t.Helper()
	file, err := os.Open(b.production.Path("local-talos", "schematics", "orb-worker.yaml"))
	must(b.t, err)
	defer file.Close()
	response, err := http.Post("https://factory.talos.dev/schematics", "application/yaml", file)
	must(b.t, err)
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	must(b.t, err)
	if response.StatusCode != http.StatusCreated && response.StatusCode != http.StatusOK {
		b.t.Fatalf("image factory: %s: %s", response.Status, body)
	}
	assets, err := os.ReadFile(filepath.Join(b.cluster.Assets, "gvisor", "schematic"))
	must(b.t, err)
	id := strings.TrimSpace(string(assets))
	if !strings.Contains(string(body), `"id":"`+id+`"`) {
		b.t.Fatalf("local-talos/schematics/orb-worker.yaml is not schematic %s of assets.nix: %s", id, body)
	}
	return id
}

// gvisorPod runs a pod to completion on the worker under the runtime class
// ("" for runc) and returns its log.
func (b *bench) gvisorPod(name, runtime, image string, command []string, capability string) string {
	b.t.Helper()
	runtimeClass := ""
	if runtime != "" {
		runtimeClass = fmt.Sprintf("  runtimeClassName: %s\n", runtime)
	}
	quoted := []string{}
	for _, arg := range command {
		quoted = append(quoted, fmt.Sprintf("%q", arg))
	}
	manifest := fmt.Sprintf(`apiVersion: v1
kind: Pod
metadata:
  name: %s
  namespace: gvisor
spec:
%s  nodeName: %s
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: main
      image: %s
      command: [%s]
      securityContext:
        capabilities:
          add: [%s]
`, name, runtimeClass, b.worker, image, strings.Join(quoted, ", "), capability)
	b.kubectl(manifest, "create", "-f", "-")
	start := time.Now()
	_, waitErr := b.cluster.Kubectl(b.ctx, "", "-n", "gvisor", "wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/"+name, "--timeout=10m")
	log, _ := b.cluster.Kubectl(b.ctx, "", "-n", "gvisor", "logs", name)
	pod, _ := b.cluster.Kubectl(b.ctx, "", "-n", "gvisor", "get", "pod", name, "-o", "jsonpath={.status.phase} {.status.containerStatuses[0].state}")
	fmt.Fprintf(b.results, "== %s runtime=%s image=%s after %s: %s\n%s\n", name, cmp.Or(runtime, "runc"), image, time.Since(start).Round(time.Second), pod, log)
	b.t.Logf("%s (%s): %s\n%s", name, cmp.Or(runtime, "runc"), pod, log)
	if waitErr != nil {
		b.t.Errorf("%s did not succeed: %v", name, waitErr)
	}
	return log
}
