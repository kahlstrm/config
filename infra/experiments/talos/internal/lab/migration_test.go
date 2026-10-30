package lab

import (
	"encoding/json"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestSummarizeFindsTheLongestStretchWithoutSuccess(t *testing.T) {
	s := func(at float64, signal string, ok bool) Sample {
		return Sample{At: time.Duration(at * float64(time.Second)), Signal: signal, OK: ok}
	}
	samples := []Sample{
		s(0, "lb", true), s(1, "lb", true), s(2, "lb", false), s(3, "lb", false), s(6, "lb", true), s(7, "lb", true),
		// Down since before the window and never back.
		s(0, "api", true), s(5, "api", false),
		// Starts reporting only inside the window.
		s(4, "prober", true),
	}
	stats := Summarize(samples, 1*time.Second, 8*time.Second)
	want := map[string]Stat{
		"lb":     {OK: 3, Failed: 2, Outage: 5 * time.Second},
		"api":    {OK: 0, Failed: 1, Outage: 7 * time.Second},
		"prober": {OK: 1, Outage: 4 * time.Second},
	}
	for signal, stat := range want {
		if stats[signal] != stat {
			t.Errorf("%s: got %+v, want %+v", signal, stats[signal], stat)
		}
	}
}

func TestMonitorTableCountsLeaksOfBlockedSignals(t *testing.T) {
	m := NewMonitor(&strings.Builder{})
	m.Blocked = func(signal string) bool { return strings.HasSuffix(signal, "/external") }
	m.Step("cutover")
	report := httptest.NewRequest("GET", "/report?namespace=mig-policed&node=talos-lab-worker-1&target=external&ok=1", nil)
	m.ServeHTTP(httptest.NewRecorder(), report)
	m.Record("mig-policed/worker-1/external", false)
	m.Record("lb", true)
	m.End()
	table := m.Table()
	for _, want := range []string{"cutover", "mig-policed/worker-1/external", "leak 1/2", "lb"} {
		if !strings.Contains(table, want) {
			t.Errorf("table lacks %q:\n%s", want, table)
		}
	}
	recorder := httptest.NewRecorder()
	m.ServeHTTP(recorder, httptest.NewRequest("GET", "/other", nil))
	if recorder.Code != 404 {
		t.Errorf("unknown path answered %d", recorder.Code)
	}
}

func TestManifestChanges(t *testing.T) {
	output := `updating manifests
 < Pruned DaemonSet/kube-system/kube-flannel
--- a/apps/v1.DaemonSet/kube-system/kube-flannel
 < "10.5.0.2": successfully updated
 < deleted ClusterRole/flannel
 < unchanged Namespace/flux-system
 > skipped CustomResourceDefinition/fluxinstances.fluxcd.controlplane.io: no changes
 < configured ConfigMap/kube-system/cilium-config
`
	changes := ManifestChanges(output)
	want := map[string][]string{
		"Pruned":     {"DaemonSet/kube-system/kube-flannel"},
		"deleted":    {"ClusterRole/flannel"},
		"unchanged":  {"Namespace/flux-system"},
		"configured": {"ConfigMap/kube-system/cilium-config"},
	}
	if len(changes) != len(want) {
		t.Fatalf("got %v", changes)
	}
	for action, objects := range want {
		if !slices.Equal(changes[action], objects) {
			t.Errorf("%s: got %v, want %v", action, changes[action], objects)
		}
	}
}

func TestWithoutSyncKeepsTheRestOfTheFluxInstance(t *testing.T) {
	instance := `kind: FluxInstance
spec:
  cluster:
    networkPolicy: true
  sync:
    kind: GitRepository
    url: https://github.com/kahlstrm/config.git
    ref: refs/heads/main
  components:
    - helm-controller
`
	got := WithoutSync(instance)
	if strings.Contains(got, "sync") || strings.Contains(got, "github.com") {
		t.Errorf("sync left in:\n%s", got)
	}
	for _, want := range []string{"networkPolicy: true", "  components:", "- helm-controller"} {
		if !strings.Contains(got, want) {
			t.Errorf("lost %q:\n%s", want, got)
		}
	}
}

func TestFluxBootstrapFollowsProductionWithoutSync(t *testing.T) {
	data, err := production(t).FluxBootstrap()
	if err != nil {
		t.Fatal(err)
	}
	var patch struct {
		Cluster struct {
			ExtraManifests  []string `json:"extraManifests"`
			InlineManifests []struct {
				Name, Contents string
			} `json:"inlineManifests"`
		} `json:"cluster"`
	}
	if err := json.Unmarshal(data, &patch); err != nil {
		t.Fatal(err)
	}
	if len(patch.Cluster.ExtraManifests) != 1 || !strings.Contains(patch.Cluster.ExtraManifests[0], "flux-operator/releases/download/v") || strings.Contains(patch.Cluster.ExtraManifests[0], "${") {
		t.Errorf("extra manifests %v", patch.Cluster.ExtraManifests)
	}
	if len(patch.Cluster.InlineManifests) != 1 {
		t.Fatalf("inline manifests %+v", patch.Cluster.InlineManifests)
	}
	contents := patch.Cluster.InlineManifests[0].Contents
	if !strings.Contains(contents, "kind: FluxInstance") || strings.Contains(contents, "sync:") || strings.Contains(contents, "kahlstrm/config") {
		t.Errorf("FluxInstance:\n%s", contents)
	}
}

func TestUserVolumeSelectsTheLabDisk(t *testing.T) {
	data, err := production(t).UserVolume("local-storage", "LABDISK")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"kind: UserVolumeConfig", "name: local-storage", `disk.serial == "LABDISK"`} {
		if !strings.Contains(string(data), want) {
			t.Errorf("user volume lacks %q:\n%s", want, data)
		}
	}
}

func TestCreateArgsAddWorkersAndTheStorageDisk(t *testing.T) {
	c := cluster(t, &fake{})
	c.Workers = 2
	c.StorageDisk = &Disk{Serial: "LABDISK", SizeMB: 102400}
	args := strings.Join(c.CreateArgs(), " ")
	for _, want := range []string{"--workers 2", "--extra-disks 1", "--extra-disks-size 102400", "--extra-disks-drivers virtio", "--extra-disks-serials LABDISK", "--disk-preallocate=false"} {
		if !strings.Contains(args, want) {
			t.Errorf("create args lack %q: %s", want, args)
		}
	}
}

func TestCreateArgsSizeEachRole(t *testing.T) {
	c := cluster(t, &fake{})
	if args := strings.Join(c.CreateArgs(), " "); !strings.Contains(args, "--memory 3GiB --memory-workers 3GiB") {
		t.Errorf("default memory: %s", args)
	}
	c.ControlPlanes, c.ControlPlaneMemory = 3, "2GiB"
	args := strings.Join(c.CreateArgs(), " ")
	for _, want := range []string{"--controlplanes 3", "--memory 2GiB --memory-workers 3GiB"} {
		if !strings.Contains(args, want) {
			t.Errorf("create args lack %q: %s", want, args)
		}
	}
}
