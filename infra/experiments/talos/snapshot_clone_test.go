//go:build integration

package talos_test

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

const (
	lvmChartVersion = "1.10.1"
	nixImage        = "docker.io/nixos/nix:2.36.0"
	cloneSize       = "8Gi"
	bakeFiles       = 100000
)

// bakeScript fills /data with an environment: the image's Nix store with
// its database, and 100 directories of 1,000 small files.
const bakeScript = `set -eu
start=$(date +%s%N)
cp -a /nix /data/nix
for d in $(seq 0 99); do
  mkdir -p /data/files/$d
  for i in $(seq 0 999); do echo "$d-$i" > /data/files/$d/$i; done
done
sync
echo store-paths=$(nix --extra-experimental-features nix-command path-info --store /data --all | wc -l)
echo files=$(find /data/files -type f | wc -l)
echo files-sum=$(cd /data/files && find . -type f -print0 | sort -z | xargs -0 md5sum | md5sum | cut -d' ' -f1)
echo bytes=$(du -sb /data | cut -f1)
echo bake-ms=$(( ($(date +%s%N) - start) / 1000000 ))
`

// cloneCheck verifies a clone's store against its database, counts what the
// bake left with a checksum of the small files, reports another clone's marker if it can see one, and leaves
// its own.
const cloneCheck = `set -eu
start=$(date +%s%N)
nix-store --store /data --verify --check-contents
echo verify-ok
echo store-paths=$(nix --extra-experimental-features nix-command path-info --store /data --all | wc -l)
echo files=$(find /data/files -type f | wc -l)
echo files-sum=$(cd /data/files && find . -type f -print0 | sort -z | xargs -0 md5sum | md5sum | cut -d' ' -f1)
if [ -e /data/marker ]; then echo marker=$(cat /data/marker); else echo marker=none; fi
echo ${NAME} > /data/marker
sync
echo check-ms=$(( ($(date +%s%N) - start) / 1000000 ))
`

// TestSnapshotClone bakes an environment into an OpenEBS LVM-LocalPV thin
// volume, snapshots it, and checks that claims restored from the snapshot
// are private copy-on-write clones that cost little to create.
func TestSnapshotClone(t *testing.T) {
	b := newBench(t, "snapshot-clone", setup{
		storage: true,
		timeout: 60 * time.Minute,
		patches: func(t *testing.T, p lab.Production, _ string) lab.Patches {
			return baselinePatches(t, p, "").With(lab.Patches{Worker: []string{"patches/lvm-thin.yaml"}})
		},
	})
	b.installLVM()
	b.snapshotClones()
}

// installLVM checks that Talos loaded dm_thin_pool and created the volume
// group, then installs OpenEBS LVM-LocalPV, whose chart brings the snapshot
// CRDs and controller.
func (b *bench) installLVM() {
	b.t.Helper()
	modules, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "read", "/proc/modules")
	must(b.t, err)
	if !strings.Contains(modules, "dm_thin_pool ") {
		b.t.Fatal("dm_thin_pool is not loaded on the worker")
	}
	for started := time.Now(); ; {
		vgs, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "get", "vgs")
		if err == nil && strings.Contains(vgs, "lvmvg") {
			fmt.Fprintf(b.results, "== worker vgs\n%s\n", vgs)
			break
		}
		if time.Since(started) > 5*time.Minute {
			b.t.Fatalf("Talos created no volume group lvmvg after 5m: %s %v", vgs, err)
		}
		must(b.t, lab.Sleep(b.ctx, 5*time.Second))
	}

	home := b.cluster.Path("helm")
	env := []string{"HOME=" + home, "HELM_CACHE_HOME=" + home + "/cache", "HELM_CONFIG_HOME=" + home + "/config", "HELM_DATA_HOME=" + home + "/data"}
	chart, err := b.cluster.Run(b.ctx, lab.Cmd{Name: "helm", Env: env, Args: []string{
		"template", "lvm-localpv", "lvm-localpv", "--repo", "https://openebs.github.io/lvm-localpv", "--version", lvmChartVersion,
		"--namespace", "openebs", "--include-crds", "--kube-version", b.cluster.Versions.Kubernetes,
	}})
	must(b.t, err)
	b.kubectl("", "create", "namespace", "openebs")
	b.kubectl("", "label", "namespace", "openebs", "pod-security.kubernetes.io/enforce=privileged")
	// The chart leaves the namespace off some of its objects.
	b.kubectl(chart, "-n", "openebs", "apply", "--server-side", "-f", "-")
	b.kubectl("", "-n", "openebs", "rollout", "status", "daemonset/lvm-localpv-node", "--timeout=10m")
	b.kubectl("", "-n", "openebs", "rollout", "status", "deployment/lvm-localpv-controller", "--timeout=10m")
	b.kubectl(b.manifest("snapshot-clone.yaml"), "apply", "-f", "-")
	for started := time.Now(); ; {
		groups, _ := b.cluster.Kubectl(b.ctx, "", "-n", "openebs", "get", "lvmnode", b.worker, "-o", "jsonpath={.volumeGroups[*].name}")
		if strings.Contains(groups, "lvmvg") {
			break
		}
		if time.Since(started) > 5*time.Minute {
			b.t.Fatalf("LVM-LocalPV reports no lvmvg on %s after 5m: %q", b.worker, groups)
		}
		must(b.t, lab.Sleep(b.ctx, 5*time.Second))
	}
}

// snapshotClones bakes the env claim, snapshots it and restores it three
// times: two clones side by side, and one after the claim it came from is
// deleted.
func (b *bench) snapshotClones() {
	b.t.Helper()
	disk := b.labDisk()
	b.claim("env", "")
	before := b.diskstats(disk)
	bake := b.workerPod("snapshot-clone", "bake", nixImage, []string{"bash", "-c", bakeScript}, "persistentVolumeClaim: {claimName: env}")
	baked := b.diskstats(disk).written - before.written
	fmt.Fprintf(b.results, "== bake wrote %d bytes to %s\n", baked, disk)
	paths, files, sum := logField(bake, "store-paths"), logField(bake, "files"), logField(bake, "files-sum")
	if files != strconv.Itoa(bakeFiles) || paths == "" || paths == "0" {
		b.t.Fatalf("the bake left %q files and %q store paths; want %d files and a store", files, paths, bakeFiles)
	}
	// The snapshot is taken with nothing mounting the claim: deleting the
	// pod returns before the CSI unmount, so wait for the LV to close.
	b.kubectl("", "-n", "snapshot-clone", "delete", "pod/bake")
	b.lvClosed(b.kubectl("", "-n", "snapshot-clone", "get", "pvc", "env", "-o", "jsonpath={.spec.volumeName}"))
	b.thinPool("after the bake")
	b.snapshot("env-1", "env")

	check := func(name, log string) {
		if !strings.Contains(log, "verify-ok") || logField(log, "store-paths") != paths || logField(log, "files") != files || logField(log, "files-sum") != sum {
			b.t.Errorf("%s does not hold the bake's %s store paths and %s files with checksum %s", name, paths, files, sum)
		}
		if marker := logField(log, "marker"); marker != "none" {
			b.t.Errorf("%s sees marker %q from another clone: clones are not private", name, marker)
		}
	}
	one, written := b.clone("clone-1", "env-1", disk)
	check("clone-1", one)
	if written > baked/10 {
		b.t.Errorf("clone-1 wrote %d bytes, more than a tenth of the bake's %d: restoring copies instead of sharing", written, baked)
	}
	two, _ := b.clone("clone-2", "env-1", disk)
	check("clone-2", two)

	withClones := b.thinPool("with two clones")
	b.kubectl("", "-n", "snapshot-clone", "delete", "pod/clone-1", "pvc/clone-1", "--timeout=3m")
	if b.volumeGone("clone-1") {
		if after := b.thinPool("after deleting clone-1"); after > withClones {
			b.t.Errorf("the thin pool grew from %.2f%% to %.2f%% when clone-1 was deleted", withClones, after)
		}
	}

	// A snapshot outlives the claim it was taken from. LVM-LocalPV keeps
	// that claim's volume while the snapshot exists, so it is only recorded.
	b.kubectl("", "-n", "snapshot-clone", "delete", "pvc/env", "--timeout=3m")
	volumes := b.kubectl("", "get", "pv", "-o", "custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,STATUS:.status.phase")
	fmt.Fprintf(b.results, "== volumes after deleting env's claim\n%s\n", volumes)
	three, _ := b.clone("clone-3", "env-1", disk)
	check("clone-3", three)
	b.thinPool("at the end")
}

func (b *bench) claim(name, snapshot string) {
	b.t.Helper()
	manifest := fmt.Sprintf(`apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: %s, namespace: snapshot-clone}
spec:
  storageClassName: lvm-thin
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: %s}}
`, name, cloneSize)
	if snapshot != "" {
		manifest += fmt.Sprintf("  dataSource: {apiGroup: snapshot.storage.k8s.io, kind: VolumeSnapshot, name: %s}\n", snapshot)
	}
	b.kubectl(manifest, "create", "-f", "-")
}

func (b *bench) snapshot(name, claim string) {
	b.t.Helper()
	start := time.Now()
	b.kubectl(fmt.Sprintf(`apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: {name: %s, namespace: snapshot-clone}
spec:
  volumeSnapshotClassName: lvm
  source: {persistentVolumeClaimName: %s}
`, name, claim), "create", "-f", "-")
	b.kubectl("", "-n", "snapshot-clone", "wait", "volumesnapshot/"+name, "--for=jsonpath={.status.readyToUse}=true", "--timeout=5m")
	fmt.Fprintf(b.results, "== snapshot %s of %s ready after %s\n", name, claim, time.Since(start).Round(time.Millisecond))
}

// clone restores snapshot into a new claim and runs cloneCheck on it. It
// returns the pod's log and the bytes written to the lab disk from creating
// the claim to the pod's completion.
func (b *bench) clone(name, snapshot, disk string) (string, int64) {
	b.t.Helper()
	before := b.diskstats(disk)
	start := time.Now()
	b.claim(name, snapshot)
	log := b.workerPod("snapshot-clone", name, nixImage, []string{"bash", "-c", strings.ReplaceAll(cloneCheck, "${NAME}", name)}, "persistentVolumeClaim: {claimName: "+name+"}")
	elapsed := time.Since(start)
	after := b.diskstats(disk)
	written := after.written - before.written
	fmt.Fprintf(b.results, "== %s from %s: claim to completed pod %s (check %s ms), %d bytes written and %d discarded on %s\n",
		name, snapshot, elapsed.Round(time.Millisecond), logField(log, "check-ms"), written, after.discarded-before.discarded, disk)
	return log, written
}

// volumeGone waits for the persistent volume of claim to be deleted, and
// reports an error if it is not within three minutes.
func (b *bench) volumeGone(claim string) bool {
	b.t.Helper()
	for started := time.Now(); ; {
		claims, err := b.cluster.Kubectl(b.ctx, "", "get", "pv", "-o", "jsonpath={.items[*].spec.claimRef.name}")
		if err == nil && !strings.Contains(" "+claims+" ", " "+claim+" ") {
			fmt.Fprintf(b.results, "== %s's volume deleted after %s\n", claim, time.Since(started).Round(time.Second))
			return true
		}
		if time.Since(started) > 3*time.Minute {
			b.t.Errorf("%s's volume is still there 3m after its claim was deleted: %s %v", claim, claims, err)
			return false
		}
		must(b.t, lab.Sleep(b.ctx, 5*time.Second))
	}
}

// labDisk returns the worker's device name for the lab disk.
func (b *bench) labDisk() string {
	b.t.Helper()
	output, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "get", "disks", "-o", "json")
	must(b.t, err)
	decoder := json.NewDecoder(strings.NewReader(output))
	for {
		var disk struct {
			Spec struct {
				DevPath string `json:"dev_path"`
				Serial  string `json:"serial"`
			} `json:"spec"`
		}
		if decoder.Decode(&disk) != nil {
			break
		}
		if disk.Spec.Serial == storageSerial {
			return filepath.Base(disk.Spec.DevPath)
		}
	}
	b.t.Fatalf("no disk with serial %s on the worker: %s", storageSerial, output)
	return ""
}

type diskCounters struct{ written, discarded int64 }

// diskstats reads device's bytes written and discarded since boot.
func (b *bench) diskstats(device string) diskCounters {
	b.t.Helper()
	stats, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "read", "/proc/diskstats")
	must(b.t, err)
	for _, line := range strings.Split(stats, "\n") {
		// Fields 10 and 17 count sectors written and discarded, of 512 bytes.
		fields := strings.Fields(line)
		if len(fields) >= 17 && fields[2] == device {
			written, err := strconv.ParseInt(fields[9], 10, 64)
			must(b.t, err)
			discarded, err := strconv.ParseInt(fields[16], 10, 64)
			must(b.t, err)
			return diskCounters{written * 512, discarded * 512}
		}
	}
	b.t.Fatalf("no %s in the worker's /proc/diskstats", device)
	return diskCounters{}
}

// lvClosed waits up to three minutes for logical volume name to be closed.
func (b *bench) lvClosed(name string) {
	b.t.Helper()
	for started := time.Now(); ; {
		open := false
		for _, line := range strings.Split(b.lvs(), "\n") {
			fields := strings.Split(strings.TrimSpace(line), ",")
			// The sixth attribute character is o while the LV is open.
			open = open || len(fields) == 6 && fields[0] == name && len(fields[1]) > 5 && fields[1][5] == 'o'
		}
		if !open {
			fmt.Fprintf(b.results, "== %s closed after %s\n", name, time.Since(started).Round(time.Second))
			return
		}
		if time.Since(started) > 3*time.Minute {
			b.t.Fatalf("%s is still open 3m after its pod was deleted", name)
		}
		must(b.t, lab.Sleep(b.ctx, 5*time.Second))
	}
}

// lvs lists lvmvg's logical volumes as name,attr,size,data%,origin,pool.
func (b *bench) lvs() string {
	b.t.Helper()
	pod := b.kubectl("", "-n", "openebs", "get", "pods", "-l", "name=openebs-lvm-node", "--field-selector", "spec.nodeName="+b.worker, "-o", "jsonpath={.items[0].metadata.name}")
	return b.kubectl("", "-n", "openebs", "exec", pod, "-c", "openebs-lvm-plugin", "--",
		"lvs", "--noheadings", "--separator", ",", "--units", "b", "--nosuffix", "-o", "lv_name,lv_attr,lv_size,data_percent,origin,pool_lv", "lvmvg")
}

// thinPool records the volume group's logical volumes and returns the thin
// pool's data use in percent.
func (b *bench) thinPool(label string) float64 {
	b.t.Helper()
	output := b.lvs()
	fmt.Fprintf(b.results, "== lvs %s (name,attr,size,data%%,origin,pool)\n%s\n", label, output)
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Split(strings.TrimSpace(line), ",")
		// A thin pool's attributes start with t.
		if len(fields) == 6 && strings.HasPrefix(fields[1], "t") {
			percent, err := strconv.ParseFloat(fields[3], 64)
			must(b.t, err)
			return percent
		}
	}
	b.t.Fatalf("no thin pool in lvmvg %s", label)
	return 0
}

// logField returns the value of the last name=value line in log.
func logField(log, name string) string {
	matches := regexp.MustCompile(`(?m)^`+regexp.QuoteMeta(name)+`=(.*)$`).FindAllStringSubmatch(log, -1)
	if len(matches) == 0 {
		return ""
	}
	return strings.TrimSpace(matches[len(matches)-1][1])
}
