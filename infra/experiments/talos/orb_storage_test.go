//go:build integration

package talos_test

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

// TestOrbStorage gives the worker w3's orb-storage user volume and checks
// that turning on its project quotas keeps its data and caps OpenEBS claims.
func TestOrbStorage(t *testing.T) {
	b := newBench(t, "orb-storage", setup{
		storage: true,
		patches: func(t *testing.T, p lab.Production, runRoot string) lab.Patches {
			patches := baselinePatches(t, p, "")
			// Flux, without sync, installs production's OpenEBS for the quota check.
			flux, err := p.FluxBootstrap()
			must(t, err)
			fluxPatch := filepath.Join(runRoot, "flux-patch.json")
			must(t, os.WriteFile(fluxPatch, flux, 0600))
			// The orb-storage volume starts without project quotas;
			// quotaAfterReboot turns them on.
			volume, err := p.UserVolume("orb-storage", storageSerial)
			must(t, err)
			volumePatch := filepath.Join(runRoot, "user-volume.yaml")
			must(t, os.WriteFile(volumePatch, volume, 0600))
			// orb-dedicated-worker.yaml's taint is left out: the bench's
			// probes run on the worker.
			return patches.With(lab.Patches{ControlPlane: []string{fluxPatch}, Worker: []string{volumePatch}})
		},
	})
	b.kubectl(b.manifest("orb-storage.yaml"), "apply", "-f", "-")
	b.quotaAfterReboot()
}

var fillBytes = regexp.MustCompile(`fill-bytes=(\d+)`)

// quotaAfterReboot turns on project quotas on the worker's formatted
// orb-storage volume as production's w3 entry does, reboots the worker, and checks that the volume kept its data and that an OpenEBS
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
	b.workerPod("orb-storage", "marker", b.image, []string{"sh", "-c", "echo before-quota > /data/marker"}, "hostPath: {path: /var/mnt/orb-storage, type: Directory}")

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
	log := b.workerPod("orb-storage", "quota", b.image, []string{"sh", "-c", fill}, "persistentVolumeClaim: {claimName: quota}")
	match := fillBytes.FindStringSubmatch(log)
	if match == nil || strings.Contains(log, "dd-exit=0") {
		b.t.Fatal("writing 1200 MiB to a 1 GiB XFSQuota claim did not fail")
	}
	written, err := strconv.ParseInt(match[1], 10, 64)
	must(b.t, err)
	if written != 1<<30 {
		b.t.Errorf("the 1 GiB claim took %d bytes; want its quota to stop it at exactly 1 GiB", written)
	}
}

// workerPod runs a pod to completion in namespace on the worker and returns its log. The pod selects the worker instead of
// naming it, so a WaitForFirstConsumer claim binds.
// A volume, if set, is mounted at /data.
func (b *bench) workerPod(namespace, name, image string, command []string, volume string) string {
	b.t.Helper()
	quoted := []string{}
	for _, arg := range command {
		quoted = append(quoted, fmt.Sprintf("%q", arg))
	}
	manifest := fmt.Sprintf(`apiVersion: v1
kind: Pod
metadata:
  name: %s
  namespace: %s
spec:
  nodeSelector: {kubernetes.io/hostname: %s}
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: main
      image: %s
      command: [%s]
`, name, namespace, b.worker, image, strings.Join(quoted, ", "))
	if volume != "" {
		manifest += "      volumeMounts: [{name: data, mountPath: /data}]\n  volumes:\n    - name: data\n      " + volume + "\n"
	}
	b.kubectl(manifest, "create", "-f", "-")
	start := time.Now()
	_, waitErr := b.cluster.Kubectl(b.ctx, "", "-n", namespace, "wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/"+name, "--timeout=10m")
	log, _ := b.cluster.Kubectl(b.ctx, "", "-n", namespace, "logs", name)
	pod, _ := b.cluster.Kubectl(b.ctx, "", "-n", namespace, "get", "pod", name, "-o", "jsonpath={.status.phase} {.status.containerStatuses[0].state}")
	fmt.Fprintf(b.results, "== %s image=%s after %s: %s\n%s\n", name, image, time.Since(start).Round(time.Second), pod, log)
	b.t.Logf("%s: %s\n%s", name, pod, log)
	if waitErr != nil {
		b.t.Errorf("%s did not succeed: %v", name, waitErr)
	}
	return log
}
