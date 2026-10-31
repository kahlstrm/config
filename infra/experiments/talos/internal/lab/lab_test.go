package lab

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func production(t *testing.T) Production {
	t.Helper()
	infra, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	return Production{Infra: infra}
}

func TestEnvironDropsCallerClusterConfig(t *testing.T) {
	env := Environ([]string{"PATH=/bin", "KUBECONFIG=/etc/real", "TALOSCONFIG=/run/real", "KUBECONFIGX=kept"}, []string{"KUBECONFIG=/lab/kubeconfig"})
	want := []string{"PATH=/bin", "KUBECONFIGX=kept", "KUBECONFIG=/lab/kubeconfig"}
	if !slices.Equal(env, want) {
		t.Fatalf("got %v, want %v", env, want)
	}
}

func TestProductionConfigIsReadable(t *testing.T) {
	p := production(t)
	versions, err := p.Versions()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(versions.Talos, "v1.") {
		t.Fatalf("unexpected Talos version %q", versions.Talos)
	}
	contract, err := p.ConfigContract()
	if err != nil {
		t.Fatal(err)
	}
	if !talosRelease.MatchString(contract) {
		t.Fatalf("unexpected config contract %q", contract)
	}
	image, err := p.CanaryImage()
	if err != nil || !strings.HasPrefix(image, "busybox:") {
		t.Fatalf("unexpected canary image %q: %v", image, err)
	}
	if _, err := os.Stat(p.PodNetworkPolicy()); err != nil {
		t.Fatal(err)
	}
}

func TestCNIPatchesFollowTheModule(t *testing.T) {
	p := production(t)
	flannel, err := p.Patches(Flannel)
	if err != nil {
		t.Fatal(err)
	}
	cilium, err := p.Patches(Cilium)
	if err != nil {
		t.Fatal(err)
	}
	networkPolicy := p.Path("modules", "talos-cluster", "cni", "flannel-controlplane.yaml")
	none := p.Path("modules", "talos-cluster", "cni", "none.yaml")
	if !slices.Contains(flannel.ControlPlane, networkPolicy) || slices.Contains(flannel.All, none) {
		t.Errorf("flannel patches: %+v", flannel)
	}
	if slices.Contains(cilium.ControlPlane, networkPolicy) || !slices.Contains(cilium.All, none) {
		t.Errorf("cilium patches: %+v", cilium)
	}
	for path, want := range map[string]string{networkPolicy: "kubeNetworkPoliciesEnabled: true", none: "name: none"} {
		if data, err := os.ReadFile(path); err != nil || !strings.Contains(string(data), want) {
			t.Errorf("%s no longer has %q: %v", path, want, err)
		}
	}
	if _, err := p.Patches("calico"); err == nil {
		t.Error("an unknown CNI must fail")
	}
}

func TestCiliumFollowsProduction(t *testing.T) {
	p := production(t)
	manifest, err := p.CiliumManifest()
	if err != nil || !strings.Contains(manifest, "kind: DaemonSet") {
		t.Fatalf("production Cilium manifest: %v", err)
	}
	for _, file := range []string{p.CiliumValues(), p.CiliumPostRender()} {
		if _, err := os.Stat(file); err != nil {
			t.Fatal(err)
		}
	}
	f := &fake{}
	if _, err := RenderCilium(context.Background(), f.run, "/chart.tgz", t.TempDir(), "1.37.1", "/post-render.yq", "/production.yaml", "/extra.yaml"); err != nil {
		t.Fatal(err)
	}
	// As local-talos/cilium/default.nix renders it, with the extras last,
	// then the post-render.
	want := []string{
		"helm template cilium /chart.tgz --namespace kube-system --kube-version 1.37.1 --values /production.yaml --values /extra.yaml",
		"yq --from-file /post-render.yq",
	}
	if got := f.commands(); !slices.Equal(got, want) {
		t.Errorf("got %v, want %q", got, want)
	}
}

type fake struct {
	calls []Cmd
	fail  func(Cmd) (string, error)
}

// run answers every command successfully, except that the NixOS firewall
// rule is absent, unless fail overrides it.
func (f *fake) run(_ context.Context, c Cmd) (string, error) {
	f.calls = append(f.calls, c)
	if f.fail != nil {
		return f.fail(c)
	}
	return absentRule(c)
}

func absentRule(c Cmd) (string, error) {
	if slices.Contains(c.Args, "-C") {
		return "", errors.New("no such rule")
	}
	return "", nil
}

func (f *fake) commands() []string {
	lines := []string{}
	for _, c := range f.calls {
		lines = append(lines, strings.Join(append([]string{c.Name}, c.Args...), " "))
	}
	return lines
}

func (f *fake) ran(fragment string) bool {
	for _, line := range f.commands() {
		if strings.Contains(line, fragment) {
			return true
		}
	}
	return false
}

func cluster(t *testing.T, f *fake) *Cluster {
	c := &Cluster{Name: "talos-lab", Directory: t.TempDir(), Assets: "/assets", CNIBin: "/cache/cni", Versions: Versions{Talos: "v1.14.4", Kubernetes: "1.37.1"}, Contract: "v1.11.5", Patches: Patches{All: []string{"/lab.yaml"}, ControlPlane: []string{"/cp.yaml"}}, Run: f.run}
	t.Cleanup(func() {
		if c.StateLink != "" {
			os.RemoveAll(filepath.Dir(c.StateLink))
		}
	})
	return c
}

func TestCreateUsesSparseDisksAndLabClientFiles(t *testing.T) {
	f := &fake{}
	c := cluster(t, f)
	if err := c.Create(context.Background()); err != nil {
		t.Fatal(err)
	}
	// QEMU puts monitor sockets in the state directory, under its VM's name.
	if socket := filepath.Join(c.StateLink, c.Name, c.Name+"-controlplane-1.monitor"); len(socket) >= 108 {
		t.Errorf("monitor socket path too long for QEMU: %s", socket)
	}
	if target, err := os.Readlink(c.StateLink); err != nil || target != c.Path("state") {
		t.Errorf("state link points to %q: %v", target, err)
	}
	create := strings.Join(c.CreateArgs(), " ")
	for _, want := range []string{"--state " + c.StateLink, "--disk-preallocate=false", "--skip-kubeconfig", "--talos-version v1.11.5", "--kubernetes-version 1.37.1", "--config-patch @/lab.yaml", "--config-patch-control-plane @/cp.yaml"} {
		if !strings.Contains(create, want) {
			t.Errorf("create args lack %q: %s", want, create)
		}
	}
	for _, call := range f.calls {
		line := strings.Join(append([]string{call.Name}, call.Args...), " ")
		if strings.Contains(line, "talosctl") && !strings.Contains(line, "KUBECONFIG="+c.Kubeconfig()) && !slices.Contains(call.Env, "KUBECONFIG="+c.Kubeconfig()) {
			t.Errorf("talosctl ran without the lab kubeconfig: %s", line)
		}
	}
}

func TestDestroyRunsEveryStepAfterAFailedCreate(t *testing.T) {
	f := &fake{fail: func(c Cmd) (string, error) {
		if slices.Contains(c.Args, "create") {
			return "boot failed", errors.New("create failed")
		}
		return absentRule(c)
	}}
	c := cluster(t, f)
	if err := c.Create(context.Background()); err == nil {
		t.Fatal("create succeeded")
	}
	// talosctl created the cluster's state before failing.
	if err := os.Mkdir(c.Path("state", c.Name), 0700); err != nil {
		t.Fatal(err)
	}
	f.fail = func(c Cmd) (string, error) {
		if slices.Contains(c.Args, "destroy") {
			return "", errors.New("destroy failed")
		}
		return absentRule(c)
	}
	f.calls = nil
	if err := c.Destroy(context.Background()); err == nil {
		t.Fatal("destroy hid the talosctl failure")
	}
	for _, want := range []string{"cluster destroy --name talos-lab", "iptables -C nixos-fw", "rm -rf " + c.Path("state")} {
		if !f.ran(want) {
			t.Errorf("destroy skipped %q; ran %v", want, f.commands())
		}
	}
}

func TestDestroyReportsLeftovers(t *testing.T) {
	f := &fake{fail: func(c Cmd) (string, error) {
		if c.Name == "ip" {
			return "talos1a2b3c4d UP\nlo UNKNOWN\n", nil
		}
		return absentRule(c)
	}}
	c := cluster(t, f)
	err := c.Destroy(context.Background())
	if err == nil || !strings.Contains(err.Error(), "talos1a2b3c4d") {
		t.Fatalf("leftover bridge not reported: %v", err)
	}
}

func TestFirewallRuleIsRemovedUntilAbsent(t *testing.T) {
	present := 2
	f := &fake{}
	f.fail = func(c Cmd) (string, error) {
		switch {
		case slices.Contains(c.Args, "-C") && present > 0:
			return "", nil
		case slices.Contains(c.Args, "-C"):
			return "", errors.New("no rule")
		case slices.Contains(c.Args, "-D"):
			present--
		}
		return "", nil
	}
	if err := cluster(t, f).closeFirewall(context.Background()); err != nil || present != 0 {
		t.Fatalf("rules left: %d, err %v", present, err)
	}
}

func TestOwnsTheClusterProcesses(t *testing.T) {
	c := cluster(t, &fake{})
	c.StateLink = "/tmp/tl-1/s"
	for argv, want := range map[string]bool{
		"/assets/bin/talosctl\x00loadbalancer-launch\x00--loadbalancer-addr\x0010.5.0.1": true,
		"/assets/bin/talosctl\x00dnsd-launch\x00--addr\x0010.5.0.1":                      true,
		"qemu-system-x86_64\x00-monitor\x00unix:/tmp/tl-1/s/talos-lab/w.monitor":         true,
		"/assets/bin/talosctl\x00--talosconfig\x00x\x00version":                          false,
		"/other/talosctl\x00dnsd-launch":                                                 false,
	} {
		if got := c.owns(strings.Split(argv, "\x00")); got != want {
			t.Errorf("%q: got %t", argv, got)
		}
	}
}

func TestNewLinksIgnoresPreexistingInterfaces(t *testing.T) {
	before := "lo UNKNOWN\ntalosaaaa DOWN\n"
	after := before + "talosbbbb UP\neth0 UP\n"
	if got := NewLinks(before, after); !slices.Equal(got, []string{"talosbbbb"}) {
		t.Fatalf("got %v", got)
	}
}

func TestAddedRulesKeepsPreexistingEntries(t *testing.T) {
	before := "filter -N DOCKER-USER\nfilter -A FORWARD -j DOCKER-USER\n"
	after := before + `filter -N CNI-FORWARD
filter -A FORWARD -m comment --comment "CNI firewall plugin rules" -j CNI-FORWARD
filter -A INPUT -j unrelated
nat -A POSTROUTING -s 10.5.0.0/24 -j MASQUERADE
`
	rules, chains := AddedRules(before, after)
	wantRules := [][]string{
		{"-t", "filter", "-D", "FORWARD", "-m", "comment", "--comment", "CNI firewall plugin rules", "-j", "CNI-FORWARD"},
		{"-t", "nat", "-D", "POSTROUTING", "-s", "10.5.0.0/24", "-j", "MASQUERADE"},
	}
	if !slices.EqualFunc(rules, wantRules, slices.Equal) {
		t.Fatalf("rules %q", rules)
	}
	if !slices.EqualFunc(chains, [][]string{{"-t", "filter", "CNI-FORWARD"}}, slices.Equal) {
		t.Fatalf("chains %q", chains)
	}
}

func TestSweepDestroysOnlyRunsWithState(t *testing.T) {
	root := t.TempDir()
	f := &fake{}
	for _, run := range []string{"live", "done"} {
		c := cluster(t, f)
		c.Name = run
		c.Directory = filepath.Join(root, "cilium", run)
		if err := c.Save(); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "cilium", "live", "state", "live"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := Sweep(context.Background(), root, f.run); err != nil {
		t.Fatal(err)
	}
	if !f.ran("--name live") || f.ran("--name done") {
		t.Fatalf("sweep ran %v", f.commands())
	}
}

// The probe script runs under a real shell with stub nc and nslookup that
// reach only allowed.example.
func TestProbeScriptReportsEveryTargetAtEveryOffset(t *testing.T) {
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("no sh")
	}
	bin := t.TempDir()
	for name, body := range map[string]string{
		"nc":       `for a; do [ "$a" = allowed.example ] && exit 0; done; exit 1`,
		"nslookup": `[ "$1" = allowed.example ]`,
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+body+"\n"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	p := Probe{Name: "probe", Offsets: []int{0, 1}, Targets: []Target{
		{Name: "pod", Host: "allowed.example", Port: 8080},
		{Name: "external", Host: "denied.example", Port: 80},
		{Name: "dns", Host: "allowed.example"},
	}}
	cmd := exec.Command("sh", "-c", p.Script())
	cmd.Env = []string{"PATH=" + bin + ":" + os.Getenv("PATH")}
	output, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	result, err := ParseProbe(string(output), p)
	if err != nil {
		t.Fatal(err)
	}
	for _, offset := range p.Offsets {
		if !result[offset]["pod"] || result[offset]["external"] || !result[offset]["dns"] {
			t.Fatalf("offset %d: %v", offset, result[offset])
		}
	}
	if _, err := ParseProbe("probe offset=0 target=pod result=connected\n", p); err == nil {
		t.Fatal("incomplete probe log accepted")
	}
}

func TestProbeManifestFollowsTheRestrictedProfile(t *testing.T) {
	manifest, err := Probe{Name: "p", Namespace: "ns", Node: "worker", Image: "busybox", Offsets: []int{0}}.Manifest()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"runAsNonRoot":true`, `"allowPrivilegeEscalation":false`, `"drop":["ALL"]`, `"type":"RuntimeDefault"`, `"nodeName":"worker"`} {
		if !strings.Contains(manifest, want) {
			t.Errorf("manifest lacks %s", want)
		}
	}
}

func TestTally(t *testing.T) {
	p := Probe{Offsets: []int{0, 3}, Targets: []Target{{Name: "external"}}}
	tally := NewTally(p)
	tally.Add(Result{0: {"external": true}, 3: {"external": false}})
	tally.Add(Result{0: {"external": false}, 3: {"external": false}})
	if tally.Connected(0, "external") != 1 || tally.Connected(3, "external") != 0 || tally.Runs != 2 {
		t.Fatalf("tally %s", tally)
	}
	if !strings.Contains(tally.String(), "external       1/2     0/2") {
		t.Fatalf("table:\n%s", tally)
	}
}

func TestNodeWidePacketSockets(t *testing.T) {
	table := `sk               RefCnt Type Proto  Iface R Rmem   User   Inode
0000000000000000 3      3    0003   0     1 0      0      1001
0000000000000000 3      3    0003   2     1 0      0      1002
0000000000000000 3      2    0800   0     1 0      0      1003
0000000000000000 3      3    88cc   0     1 0      0      1004
`
	if got := NodeWidePacketSockets(table); got != 2 {
		t.Fatalf("got %d", got)
	}
}
