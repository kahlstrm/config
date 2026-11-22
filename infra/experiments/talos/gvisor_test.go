//go:build integration

package talos_test

import (
	"cmp"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
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
mtu=$(ip -o link show dev eth0 | sed -n 's/.*mtu \([0-9]*\).*/\1/p')
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
		storage:   true,
		patches: func(t *testing.T, p lab.Production, runRoot string) lab.Patches {
			patches := baselinePatches(t, p, "")
			// Flux, without sync, installs production's OpenEBS for the quota check.
			flux, err := p.FluxBootstrap()
			must(t, err)
			fluxPatch := filepath.Join(runRoot, "flux-patch.json")
			must(t, os.WriteFile(fluxPatch, flux, 0600))
			// The orb-storage volume starts without project quotas, as w3's
			// does today; quotaAfterReboot turns them on.
			volume, err := p.UserVolume("orb-storage", storageSerial)
			must(t, err)
			volumePatch := filepath.Join(runRoot, "user-volume.yaml")
			must(t, os.WriteFile(volumePatch, volume, 0600))
			// gVisor needs user namespaces, which production's workers allow.
			// orb-dedicated-worker.yaml's taint is left out: the bench's
			// probes run on the worker.
			return patches.With(lab.Patches{ControlPlane: []string{fluxPatch}, Worker: []string{
				p.Path("local-talos", "patches", "userns-worker.yaml"),
				p.Path("local-talos", "patches", "orb-gvisor-worker.yaml"),
				volumePatch,
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
		log := b.gvisorPod(name, c.runtime, socketImage, []string{"python3", "-c", socketScript}, "NET_RAW", "")
		sandboxed := !strings.Contains(log, "kernel: "+host)
		if sandboxed != (c.runtime != "") {
			t.Errorf("%s: sandboxed=%t, want %t; host kernel %q", name, sandboxed, c.runtime != "", host)
		}
		if !strings.Contains(log, "packet-write: "+c.write) {
			t.Errorf("%s: packet-socket write not %s", name, c.write)
		}
	}

	docker := fmt.Sprintf(dockerScript, b.image, externalIP)
	log := b.gvisorPod("docker", "gvisor-docker", dindImage, []string{"sh", "-c", docker}, "ALL", "")
	for _, want := range []string{"nested-container: ok", "nested-egress: ok"} {
		if !strings.Contains(log, want) {
			t.Errorf("dockerd under gvisor-docker: no %q", want)
		}
	}
	if strings.Contains(log, "kernel: "+host) {
		t.Error("the docker pod ran on the host kernel, not in gVisor")
	}

	b.quotaAfterReboot()
}

var fillBytes = regexp.MustCompile(`fill-bytes=(\d+)`)

// quotaAfterReboot turns on project quotas on the worker's formatted
// orb-storage volume as production's w3 entry does, reboots the worker as its
// upgrade would, and checks that the volume kept its data and that an OpenEBS
// hostpath class with XFSQuota caps a 1 GiB claim at its size.
func (b *bench) quotaAfterReboot() {
	b.t.Helper()
	quota := func() string {
		status, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "get", "mountstatus", "u-orb-storage", "-o", "yaml")
		must(b.t, err)
		fmt.Fprintf(b.results, "== worker mountstatus u-orb-storage\n%s\n", status)
		return status
	}
	if !strings.Contains(quota(), "projectQuotaSupport: false") {
		b.t.Fatal("orb-storage has project quotas before they were turned on")
	}
	b.gvisorPod("marker", "", b.image, []string{"sh", "-c", "echo before-quota > /data/marker"}, "", "hostPath: {path: /var/mnt/orb-storage, type: Directory}")

	// Production merges templates/project-quota.yaml into the template's
	// document; their keys don't overlap, so appending is the same merge.
	volume, err := b.production.UserVolume("orb-storage", storageSerial)
	must(b.t, err)
	projectQuota, err := os.ReadFile(b.production.Path("local-talos", "templates", "project-quota.yaml"))
	must(b.t, err)
	patch := b.cluster.Path("project-quota-volume.yaml")
	must(b.t, os.WriteFile(patch, append(volume, projectQuota...), 0600))
	bootID := func() string {
		id, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "read", "/proc/sys/kernel/random/boot_id")
		if err != nil {
			return ""
		}
		return strings.TrimSpace(id)
	}
	before := bootID()
	output, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "patch", "mc", "--mode=no-reboot", "--patch", "@"+patch)
	fmt.Fprintf(b.results, "== patch orb-storage with project quotas\n%s %v\n", output, err)
	must(b.t, err)
	output, err = b.cluster.Talos(b.ctx, "-n", b.workerIP, "reboot", "--wait=false")
	must(b.t, err)
	for started := time.Now(); bootID() == "" || bootID() == before; {
		if time.Since(started) > 10*time.Minute {
			b.t.Fatal("worker did not come back from its reboot after 10m")
		}
		must(b.t, lab.Sleep(b.ctx, 5*time.Second))
	}
	b.kubectl("", "wait", "node/"+b.worker, "--for=condition=Ready", "--timeout=10m")

	if !strings.Contains(quota(), "projectQuotaSupport: true") {
		b.t.Error("orb-storage has no project quotas after the reboot")
	}
	marker, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "read", "/var/mnt/orb-storage/marker")
	fmt.Fprintf(b.results, "== /var/mnt/orb-storage/marker after the reboot: %q %v\n", marker, err)
	if err != nil || strings.TrimSpace(marker) != "before-quota" {
		b.t.Error("orb-storage lost its data: the volume was reformatted")
	}

	for started := time.Now(); ; {
		if _, err := b.cluster.Kubectl(b.ctx, "", "-n", "flux-system", "get", "fluxinstance", "flux"); err == nil {
			break
		}
		if time.Since(started) > 10*time.Minute {
			b.t.Fatal("no FluxInstance after 10m")
		}
		must(b.t, lab.Sleep(b.ctx, 5*time.Second))
	}
	b.kubectl("", "-n", "flux-system", "wait", "fluxinstance/flux", "--for=condition=Ready", "--timeout=10m")
	b.kubectl("", "apply", "-f", b.production.Kubernetes("infrastructure", "controllers", "openebs.yaml"))
	b.kubectl("", "-n", "openebs", "wait", "helmrelease/openebs", "--for=condition=Ready", "--timeout=10m")
	b.kubectl(b.manifest("orb-storage.yaml"), "apply", "-f", "-")
	fill := "dd if=/dev/zero of=/data/fill bs=1M count=1200; echo dd-exit=$?; echo fill-bytes=$(wc -c < /data/fill); df -k /data"
	log := b.gvisorPod("quota", "", b.image, []string{"sh", "-c", fill}, "", "persistentVolumeClaim: {claimName: quota}")
	match := fillBytes.FindStringSubmatch(log)
	if match == nil || strings.Contains(log, "dd-exit=0") {
		b.t.Fatal("writing 1200 MiB to a 1 GiB XFSQuota claim did not fail")
	}
	written, err := strconv.ParseInt(match[1], 10, 64)
	must(b.t, err)
	if written > 1<<30 || written < 1<<29 {
		b.t.Errorf("the 1 GiB claim took %d bytes; want its quota to stop it at 1 GiB", written)
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
// ("" for runc) and returns its log. The pod selects the worker instead of
// naming it, so a WaitForFirstConsumer claim binds.
// A volume, if set, is mounted at /data.
func (b *bench) gvisorPod(name, runtime, image string, command []string, capability, volume string) string {
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
%s  nodeSelector: {kubernetes.io/hostname: %s}
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
	if volume != "" {
		manifest += "      volumeMounts: [{name: data, mountPath: /data}]\n  volumes:\n    - name: data\n      " + volume + "\n"
	}
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
