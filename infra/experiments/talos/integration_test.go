//go:build integration

package talos_test

import (
	"cmp"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/cnipods"
	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

const (
	externalIP = "1.1.1.1"
	podNetwork = "10.244.0.0/16"
	// Fresh pods per first-packet measurement.
	firstPacketRuns = 10
	shapeRuns       = 3
)

var firstPacket = []int{0, 1, 3}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

type bench struct {
	t          *testing.T
	ctx        context.Context
	source     string
	production lab.Production
	cluster    *lab.Cluster
	image      string
	worker     string
	workerIP   string
	targets    map[string]lab.Target
	results    *os.File
}

// setup describes a scenario's cluster.
type setup struct {
	patches func(*testing.T, lab.Production, string) lab.Patches
	// provision, if set, configures nodes that boot empty, instead of
	// talosctl creating them with patches.
	provision func(*bench)
	// controlPlanes and workers default to one.
	controlPlanes, workers int
	// controlPlaneMemory defaults to lab.DefaultMemory.
	controlPlaneMemory string
	// storage gives each worker a disk for production's local-storage user volume.
	storage bool
	// timeout defaults to 35 minutes.
	timeout time.Duration
}

// newBench creates a cluster for the scenario and destroys it when the test
// ends, whether it passed, failed or was interrupted.
func newBench(t *testing.T, scenario string, s setup) *bench {
	for _, binary := range []string{"sudo", "kubectl", "helm", "qemu-system-x86_64", "iptables", "pgrep", "ip"} {
		_, err := exec.LookPath(binary)
		must(t, err)
	}
	file, err := os.OpenFile("/dev/kvm", os.O_RDWR, 0)
	must(t, err)
	must(t, file.Close())
	_, err = lab.Exec(t.Context(), lab.Cmd{Name: "sudo", Args: []string{"-n", "true"}})
	must(t, err)
	assets := os.Getenv("TALOS_ASSETS")
	if assets == "" {
		t.Fatal("TALOS_ASSETS is unset; run inside `nix develop .#talos`")
	}
	source := os.Getenv("TALOS_LAB_SOURCE")
	if source == "" {
		source, err = os.Getwd()
		must(t, err)
	}
	production := lab.Production{Infra: filepath.Clean(filepath.Join(source, "../.."))}
	versions, err := production.Versions()
	must(t, err)
	contract, err := production.ConfigContract()
	must(t, err)
	image, err := production.CanaryImage()
	must(t, err)

	root, err := lab.StateRoot(os.Getenv("TALOS_LAB_STATE"))
	must(t, err)
	unlock, err := lab.Lock(root)
	must(t, err)
	t.Cleanup(func() { must(t, unlock()) })
	runRoot := filepath.Join(root, scenario, strconv.FormatInt(time.Now().UnixNano(), 10))
	must(t, os.MkdirAll(runRoot, 0700))
	t.Log("Evidence:", runRoot)
	results, err := os.Create(filepath.Join(runRoot, "results.txt"))
	must(t, err)
	t.Cleanup(func() { results.Close() })

	ctx, cancel := context.WithTimeout(t.Context(), cmp.Or(s.timeout, 35*time.Minute))
	t.Cleanup(cancel)
	scenarioPatches, err := s.patches(t, production, runRoot).Abs()
	must(t, err)
	cluster := &lab.Cluster{
		Name:               "talos-lab",
		Directory:          runRoot,
		Assets:             assets,
		CNIBin:             filepath.Join(root, "cache", "cni-"+versions.Talos, "bin"),
		Versions:           versions,
		Contract:           contract,
		Patches:            scenarioPatches,
		ControlPlanes:      s.controlPlanes,
		Workers:            s.workers,
		ControlPlaneMemory: s.controlPlaneMemory,
		Empty:              s.provision != nil,
		Run:                lab.Exec,
	}
	if s.storage {
		// Sparse, and large enough for the production template's minSize.
		cluster.StorageDisk = &lab.Disk{Serial: storageSerial, SizeMB: 102400}
	}
	client, err := cluster.Talos(ctx, "version", "--client", "--short")
	must(t, err)
	if !strings.Contains(client, versions.Talos) {
		t.Fatalf("talosctl is not %s from versions.json: %s", versions.Talos, client)
	}
	fmt.Fprintf(results, "scenario=%s talos=%s kubernetes=%s config-contract=%s\n", scenario, versions.Talos, versions.Kubernetes, contract)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		if t.Failed() {
			if err := cnipods.CaptureDiagnostics(ctx, func(ctx context.Context, args ...string) (string, error) { return cluster.Kubectl(ctx, "", args...) }, cluster.Path("diagnostics")); err != nil {
				t.Log("failure diagnostics:", err)
			}
		}
		if err := cluster.Destroy(ctx); err != nil {
			t.Error("teardown:", err)
		}
	})
	must(t, cluster.Create(ctx))
	b := &bench{t: t, ctx: ctx, source: source, production: production, cluster: cluster, image: image, results: results}
	if s.provision != nil {
		s.provision(b)
	}
	b.prepare()
	return b
}

func (b *bench) kubectl(stdin string, args ...string) string {
	b.t.Helper()
	output, err := b.cluster.Kubectl(b.ctx, stdin, args...)
	must(b.t, err)
	return strings.TrimSpace(output)
}

func (b *bench) manifest(name string, replacements ...string) string {
	data, err := os.ReadFile(filepath.Join(b.source, "manifests", name))
	must(b.t, err)
	return strings.NewReplacer(replacements...).Replace(string(data))
}

func (b *bench) prepare() {
	b.kubectl("", "-n", "kube-system", "rollout", "status", "deployment/coredns", "--timeout=5m")
	b.kubectl(b.manifest("workload.yaml", "${PROBE_IMAGE}", b.image, "${EXTERNAL_IP}", externalIP), "apply", "-f", "-")
	b.kubectl("", "-n", "np-echo", "rollout", "status", "deployment/echo", "--timeout=5m")
	b.worker = b.kubectl("", "get", "nodes", "-l", "!node-role.kubernetes.io/control-plane", "-o", "jsonpath={.items[0].metadata.name}")
	b.workerIP = b.kubectl("", "get", "node", b.worker, "-o", `jsonpath={.status.addresses[?(@.type=="InternalIP")].address}`)
	// The production ipBlock shape only means "the pod network" if pods get
	// addresses from the same range.
	_, network, err := net.ParseCIDR(podNetwork)
	must(b.t, err)
	podCIDR := b.kubectl("", "get", "node", b.worker, "-o", "jsonpath={.spec.podCIDR}")
	podIP, _, err := net.ParseCIDR(podCIDR)
	must(b.t, err)
	if !network.Contains(podIP) {
		b.t.Fatalf("worker pod CIDR %s is outside %s", podCIDR, podNetwork)
	}
	// Packet-socket behaviour (ADR 2) depends on the kernel and on bridge netfilter.
	for _, file := range []string{"/proc/version", "/proc/sys/net/bridge/bridge-nf-call-iptables"} {
		value, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "read", file)
		fmt.Fprintf(b.results, "worker %s: %s %v\n", file, strings.TrimSpace(value), err)
	}
	b.refreshTargets()
	// Pull the probe image onto the worker so image pulls don't delay first packets.
	b.probe("warm-up", "np-control", 1, []int{0}, "external")
}

// refreshTargets finds the echo pod, whose address changes when it restarts.
func (b *bench) refreshTargets() {
	b.kubectl("", "-n", "np-echo", "rollout", "status", "deployment/echo", "--timeout=5m")
	b.targets = map[string]lab.Target{
		"external": {Name: "external", Host: externalIP, Port: 80},
		"pod":      {Name: "pod", Host: b.kubectl("", "-n", "np-echo", "get", "pod", "-l", "app=echo", "--field-selector=status.phase=Running", "-o", "jsonpath={.items[0].status.podIP}"), Port: 8080},
		"service":  {Name: "service", Host: b.kubectl("", "-n", "np-echo", "get", "service", "echo", "-o", "jsonpath={.spec.clusterIP}"), Port: 8080},
		"dns":      {Name: "dns", Host: "echo.np-echo.svc.cluster.local"},
	}
}

func (b *bench) probe(label, namespace string, runs int, offsets []int, targets ...string) *lab.Tally {
	b.t.Helper()
	return b.probeOn(label, namespace, b.worker, runs, offsets, targets...)
}

// probeOn runs fresh probe pods on a given node.
func (b *bench) probeOn(label, namespace, node string, runs int, offsets []int, targets ...string) *lab.Tally {
	b.t.Helper()
	spec := lab.Probe{Namespace: namespace, Node: node, Image: b.image, Offsets: offsets}
	for _, name := range targets {
		spec.Targets = append(spec.Targets, b.targets[name])
	}
	tally := lab.NewTally(spec)
	gateway, collisions := b.cni0Gateway(node), 0
	for run := 0; run < runs; run++ {
		p := spec
		p.Name = fmt.Sprintf("%s-%d-%d", label, run, time.Now().UnixNano()%1_000_000)
		manifest, err := p.Manifest()
		must(b.t, err)
		b.kubectl(manifest, "create", "-f", "-")
		b.kubectl("", "-n", namespace, "wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/"+p.Name, "--timeout=120s")
		// Until the node reboots, Flannel's cni0 keeps its podCIDR's first
		// address, which Cilium's IPAM can give a new pod; that pod can't be
		// reached (ADR 8). It is the known collision, not a first-packet
		// result, so it is recorded and the run repeated.
		if ip := strings.TrimSpace(b.kubectl("", "-n", namespace, "get", "pod", p.Name, "-o", "jsonpath={.status.podIP}")); gateway != "" && ip == gateway {
			collisions++
			note := fmt.Sprintf("%s got %s, the address of %s's cni0; repeating run %d", p.Name, ip, node, run+1)
			fmt.Fprintf(b.results, "== %s\n", note)
			b.t.Log(note)
			b.kubectl("", "-n", namespace, "delete", "pod", p.Name, "--wait=false")
			if collisions > 3 {
				b.t.Fatalf("%d probe pods on %s got cni0's address %s", collisions, node, gateway)
			}
			run--
			continue
		}
		log := b.kubectl("", "-n", namespace, "logs", p.Name)
		result, err := lab.ParseProbe(log, p)
		must(b.t, err)
		tally.Add(result)
		fmt.Fprintf(b.results, "== %s run %d pod=%s\n%s\n", label, run+1, p.Name, log)
		b.kubectl("", "-n", namespace, "delete", "pod", p.Name, "--wait=false")
	}
	summary := fmt.Sprintf("%s (namespace %s, %d fresh pods)\n%s", label, namespace, runs, tally)
	fmt.Fprintf(b.results, "%s\n\n", summary)
	b.t.Log("\n" + summary)
	return tally
}

// cni0Gateway is the address of a node's Flannel cni0 bridge while it is
// still up, or "".
func (b *bench) cni0Gateway(node string) string {
	b.t.Helper()
	ip := strings.TrimSpace(b.kubectl("", "get", "node", node, "-o", `jsonpath={.status.addresses[?(@.type=="InternalIP")].address}`))
	gateways, err := cnipods.TalosCNI0(func(ctx context.Context, args ...string) (string, error) { return b.cluster.Talos(ctx, args...) })(b.ctx, map[string]string{node: ip})
	must(b.t, err)
	return gateways[node]
}

// all fails unless the target connected in every run at the offsets.
func (b *bench) all(tally *lab.Tally, target string, offsets ...int) {
	b.t.Helper()
	for _, offset := range offsets {
		if got := tally.Connected(offset, target); got != tally.Runs {
			b.t.Errorf("%s at +%ds connected in %d/%d runs; want all", target, offset, got, tally.Runs)
		}
	}
}

// none fails unless the target was blocked in every run at the offsets.
func (b *bench) none(tally *lab.Tally, target string, offsets ...int) {
	b.t.Helper()
	for _, offset := range offsets {
		if got := tally.Connected(offset, target); got != 0 {
			b.t.Errorf("%s at +%ds connected in %d/%d runs; want none", target, offset, got, tally.Runs)
		}
	}
}

func (b *bench) firstPacket() (control, policed *lab.Tally) {
	control = b.probe("control", "np-control", firstPacketRuns, firstPacket, "external", "pod")
	b.all(control, "external", firstPacket...)
	b.all(control, "pod", firstPacket...)
	policed = b.probe("policed", "np-policed", firstPacketRuns, firstPacket, "external", "pod")
	// The allowed pod connects from the first packet, so a blocked external
	// connection is the policy and not a pod network that isn't ready yet.
	b.all(policed, "pod", firstPacket...)
	return control, policed
}

// Holders of a node-wide packet socket, as manifests/<holder>.yaml.
const (
	tcpdump      = "tcpdump"
	packetSocket = "packet-socket"
)

// underPacketSocket runs probes while a privileged hostNetwork pod holds a
// node-wide packet socket on the worker: in np-allow, whose policy allows the
// external address, and in np-policed, whose policy denies it.
func (b *bench) underPacketSocket(holder string) (allowed, denied *lab.Tally) {
	b.kubectl(b.manifest(holder+".yaml"), "apply", "-f", "-")
	b.kubectl("", "-n", "pktsock", "rollout", "status", "daemonset/holder", "--timeout=5m")
	sockets, err := b.cluster.Talos(b.ctx, "-n", b.workerIP, "read", "/proc/net/packet")
	must(b.t, err)
	fmt.Fprintf(b.results, "worker /proc/net/packet with %s:\n%s\n", holder, sockets)
	if lab.NodeWidePacketSockets(sockets) == 0 {
		b.t.Fatalf("%s opened no node-wide packet socket on the worker", holder)
	}
	allowed = b.probe(holder+"-allowed", "np-allow", firstPacketRuns/2, firstPacket, "external", "pod")
	denied = b.probe(holder+"-denied", "np-policed", 3, firstPacket, "external", "pod")
	// Later checks need the socket closed.
	b.kubectl("", "delete", "namespace", "pktsock", "--timeout=3m")
	return allowed, denied
}

// policyShapes runs probes under the production pod-network-only policy,
// which allows every pod through a namespaceSelector, and under the same
// policy with an ipBlock of the pod CIDR instead, its earlier shape.
func (b *bench) policyShapes() (production, ipBlock *lab.Tally) {
	toPodCIDR := fmt.Sprintf(`[{"op":"replace","path":"/spec/egress","value":[{"to":[{"ipBlock":{"cidr":%q}}]}]}]`, podNetwork)
	for _, shape := range []string{"production", "ipblock"} {
		namespace := "shape-" + shape
		b.kubectl("", "create", "namespace", namespace)
		b.kubectl("", "label", "namespace", namespace, "pod-security.kubernetes.io/enforce=restricted")
		b.kubectl("", "-n", namespace, "apply", "-f", b.production.PodNetworkPolicy())
		if shape == "ipblock" {
			b.kubectl("", "-n", namespace, "patch", "networkpolicy", "pod-network-only", "--type=json", "-p", toPodCIDR)
		}
		fmt.Fprintf(b.results, "%s policy:\n%s\n", shape, b.kubectl("", "-n", namespace, "get", "networkpolicy", "pod-network-only", "-o", "jsonpath={.spec}"))
	}
	must(b.t, lab.Sleep(b.ctx, 5*time.Second))
	// Probe after ADR 4's window, so both stacks show their steady state.
	steady := []int{5}
	targets := []string{"pod", "service", "dns", "external"}
	return b.probe("production", "shape-production", shapeRuns, steady, targets...),
		b.probe("ipblock", "shape-ipblock", shapeRuns, steady, targets...)
}

// ciliumChart is production's pinned Cilium chart, or with previous set to
// "cilium-previous", the older release in assets.nix.
func ciliumChart(t *testing.T, previous string) string {
	t.Helper()
	charts, err := filepath.Glob(filepath.Join(os.Getenv("TALOS_ASSETS"), previous, "cilium-*.tgz"))
	must(t, err)
	if len(charts) != 1 {
		t.Fatalf("expected one Cilium chart in TALOS_ASSETS/%s: %v", previous, charts)
	}
	return charts[0]
}

// ciliumPatch writes a control-plane patch that installs Cilium as an inline
// manifest: production's rendered manifest, or, for another chart (see
// ciliumChart) or extra values files, that chart rendered with production's
// values followed by the extras.
func ciliumPatch(t *testing.T, ctx context.Context, p lab.Production, directory, label, chart string, extra ...string) string {
	t.Helper()
	var manifest string
	var err error
	if chart == "" && len(extra) == 0 {
		manifest, err = p.CiliumManifest()
	} else {
		var versions lab.Versions
		versions, err = p.Versions()
		must(t, err)
		manifest, err = lab.RenderCilium(ctx, lab.Exec, ciliumChart(t, chart), filepath.Join(directory, "helm"), versions.Kubernetes, p.CiliumPostRender(), append([]string{p.CiliumValues()}, extra...)...)
	}
	must(t, err)
	patch := filepath.Join(directory, "cilium-"+label+".json")
	must(t, lab.InlineManifestPatch(patch, "cilium", manifest))
	return patch
}

func baselinePatches(t *testing.T, p lab.Production, _ string) lab.Patches {
	patches, err := p.Patches(lab.Flannel)
	must(t, err)
	return patches.With(lab.Patches{All: []string{"patches/lab.yaml"}})
}

// TestNetpolBaseline measures production's stack: Talos Flannel with its
// kube-network-policies sidecar, and kube-proxy.
func TestNetpolBaseline(t *testing.T) {
	b := newBench(t, "netpol-baseline", setup{patches: baselinePatches})
	_, policed := b.firstPacket()
	// ADR 4: a new pod's connections pass until kube-network-policies learns
	// its IP, about two seconds after it starts, and are blocked afterwards.
	// This asserts that known window: some first packets reach the external
	// address, and none do three seconds in.
	if policed.Connected(0, "external") == 0 {
		t.Error("no first packet reached the external address; the ADR 4 window has closed, so update ADR 4 and this baseline")
	}
	b.none(policed, "external", 3)

	// ADR 2 says a node-wide packet socket makes kube-network-policies drop
	// new connections from policed pods that leave the node. The lab has not
	// reproduced that, with either holder, so the results are recorded only.
	for _, holder := range []string{tcpdump, packetSocket} {
		b.underPacketSocket(holder)
	}

	production, ipBlock := b.policyShapes()
	for _, shape := range []*lab.Tally{production, ipBlock} {
		b.all(shape, "pod", 5)
		b.all(shape, "service", 5)
		b.all(shape, "dns", 5)
		b.none(shape, "external", 5)
	}

	// Inbound, ADR 4's window is recorded rather than asserted: the scan
	// must reach every unpoliced server, which shows it would see the window.
	open, _ := b.inboundFirstPacket()
	b.reachedEveryServer(open)
}

// TestCilium measures Cilium replacing Flannel, kube-network-policies and kube-proxy.
func TestCilium(t *testing.T) {
	b := newBench(t, "cilium", setup{patches: func(t *testing.T, p lab.Production, runRoot string) lab.Patches {
		patches, err := p.Patches(lab.Cilium)
		must(t, err)
		return patches.With(lab.Patches{All: []string{"patches/lab.yaml"}, ControlPlane: []string{ciliumPatch(t, t.Context(), p, runRoot, "bootstrap", "")}})
	}})
	b.kubectl("", "-n", "kube-system", "rollout", "status", "daemonset/cilium", "--timeout=5m")

	_, policed := b.firstPacket()
	b.none(policed, "external", firstPacket...)

	for _, holder := range []string{tcpdump, packetSocket} {
		allowed, denied := b.underPacketSocket(holder)
		b.all(allowed, "external", firstPacket...)
		b.all(allowed, "pod", firstPacket...)
		b.none(denied, "external", firstPacket...)
		b.all(denied, "pod", firstPacket...)
	}

	production, ipBlock := b.policyShapes()
	b.all(production, "pod", 5)
	b.all(production, "service", 5)
	b.all(production, "dns", 5)
	b.none(production, "external", 5)
	// Cilium's ipBlock does not match pod IPs by default (policyCIDRMatchMode),
	// so the earlier shape blocks the pod network, including DNS, too.
	for _, target := range []string{"pod", "service", "dns", "external"} {
		b.none(ipBlock, target, 5)
	}

	open, denied := b.inboundFirstPacket()
	b.reachedEveryServer(open)
	for i, result := range denied {
		if result.accepted > 0 {
			t.Errorf("inbound run %d: a server behind default-deny ingress accepted %d connections, the first %s after it started", i+1, result.accepted, result.first)
		}
	}

	// A pod that starts while the API is unreachable must not reach a denied
	// address, with Cilium's defaults as production runs it and with a policy
	// that selects the init identity. The lab observes behaviour only: the
	// endpoint's identity during the outage cannot be read without the API.
	b.kubectl("", "-n", "np-echo", "rollout", "status", "deployment/local-echo", "--timeout=5m")
	for _, run := range []struct {
		label  string
		policy bool
	}{{"defaults", false}, {"init-policy", true}} {
		if run.policy {
			b.kubectl(initIdentityCCNP, "apply", "-f", "-")
		}
		down, after := b.apiDownPodStart(run.label)
		if after["external"] > 0 {
			t.Errorf("%s: the pod reached the external address %d times after the API came back", run.label, after["external"])
		}
		if after["local"] == 0 {
			t.Errorf("%s: the pod never reached the allowed local pod", run.label)
		}
		// The pod must have run long enough during the outage for its
		// denials to mean something: at about two seconds a check, ten
		// checks are twenty seconds.
		if down["checks"] < 10 {
			t.Errorf("%s: only %d checks while the API was down; want at least 10", run.label, down["checks"])
		}
		if down["external"] > 0 {
			t.Errorf("%s: the pod reached the external address %d times while the API was down", run.label, down["external"])
		}
	}
}
