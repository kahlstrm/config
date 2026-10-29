//go:build integration

package talos_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

const (
	storageSerial = "TALOSLABSTORAGE"
	sinkPort      = 18080
	knownData     = "written-before-the-migration"
	// Production's MetalLB pool, and the lab's in its place.
	productionPool = "10.10.10.80-10.10.10.99"
	labPool        = "10.5.0.200-10.5.0.220"
	// The production pod-network-only policy, rewritten as Cilium needs.
	namespaceSelectorRewrite = `[{"op":"replace","path":"/spec/egress","value":[{"to":[{"namespaceSelector":{}}]}]}]`
)

// migration is a cluster with production's platform pieces that a CNI
// change disrupts: MetalLB in L2 mode with a LoadBalancer Service, OpenEBS
// local storage holding known data, Flux, and the netpol canary's policy. A
// monitor watches the API, the LoadBalancer address and probers in every
// worker throughout.
type migration struct {
	*bench
	monitor      *lab.Monitor
	controlPlane string
	workers      []string
	ips          map[string]string
	lb           atomic.Pointer[string]
}

// start is the stack a migration scenario starts from.
type start struct {
	// cilium bootstraps Cilium with production's values instead of
	// production's Flannel stack.
	cilium bool
	// chart selects another chart for a bootstrapped Cilium; see ciliumChart.
	chart string
	// metallb is a merge patch for production's MetalLB HelmRelease.
	metallb string
	// drops marks a starting stack that is expected to drop policed pods'
	// allowed traffic (ADR 2), so the baseline is not asserted healthy.
	drops bool
}

func newMigration(t *testing.T, scenario string, from start) *migration {
	b := newBench(t, scenario, setup{workers: 2, storage: true, timeout: 100 * time.Minute, patches: func(t *testing.T, p lab.Production, runRoot string) lab.Patches {
		flux, err := p.FluxBootstrap()
		must(t, err)
		fluxPatch := filepath.Join(runRoot, "flux-patch.json")
		must(t, os.WriteFile(fluxPatch, flux, 0600))
		volume, err := p.UserVolume("local-storage", storageSerial)
		must(t, err)
		volumePatch := filepath.Join(runRoot, "user-volume.yaml")
		must(t, os.WriteFile(volumePatch, volume, 0600))
		extra := lab.Patches{All: []string{"patches/lab.yaml"}, ControlPlane: []string{fluxPatch}, Worker: []string{volumePatch}}
		cni := lab.Flannel
		if from.cilium {
			cni = lab.Cilium
			extra = extra.With(lab.Patches{ControlPlane: []string{ciliumPatch(t, t.Context(), p, runRoot, "bootstrap", from.chart)}})
		}
		patches, err := p.Patches(cni)
		must(t, err)
		return patches.With(extra)
	}})
	m := &migration{bench: b, ips: map[string]string{}}
	m.discover()
	m.platform(from)
	m.watch()
	if !from.drops {
		m.healthy("baseline")
	}
	return m
}

func (m *migration) discover() {
	names := strings.Fields(m.kubectl("", "get", "nodes", "-o", "jsonpath={.items[*].metadata.name}"))
	slices.Sort(names)
	for _, name := range names {
		m.ips[name] = m.kubectl("", "get", "node", name, "-o", `jsonpath={.status.addresses[?(@.type=="InternalIP")].address}`)
		if strings.Contains(name, "controlplane") {
			m.controlPlane = name
		} else {
			m.workers = append(m.workers, name)
		}
	}
	if m.controlPlane == "" || len(m.workers) != 2 {
		m.t.Fatalf("unexpected nodes %v", names)
	}
}

func (m *migration) nodes() []string { return append([]string{m.controlPlane}, m.workers...) }

func (m *migration) record(format string, args ...any) {
	m.t.Helper()
	line := fmt.Sprintf(format, args...)
	fmt.Fprintln(m.results, line)
	m.t.Log(line)
}

func (m *migration) platform(from start) {
	p := m.production
	// The Flux Operator installs Flux, and its CRDs, after the cluster is up.
	m.eventually("FluxInstance exists", 10*time.Minute, func() bool { return m.exists("fluxinstance", "flux-system", "flux") })
	m.kubectl("", "-n", "flux-system", "wait", "fluxinstance/flux", "--for=condition=Ready", "--timeout=10m")
	m.kubectl("", "apply",
		"-f", p.Kubernetes("infrastructure", "controllers", "openebs.yaml"),
		"-f", p.Kubernetes("infrastructure", "controllers", "metallb.yaml"),
		"-f", p.Kubernetes("infrastructure", "configs", "local-storage.yaml"))
	if from.metallb != "" {
		m.kubectl("", "-n", "metallb-system", "patch", "helmrelease", "metallb", "--type=merge", "-p", from.metallb)
	}
	m.kubectl("", "wait", "helmrelease", "--all", "-A", "--for=condition=Ready", "--timeout=10m")
	pool, err := os.ReadFile(p.Kubernetes("infrastructure", "configs", "metallb-pool.yaml"))
	must(m.t, err)
	if !strings.Contains(string(pool), productionPool) {
		m.t.Fatalf("production MetalLB pool is no longer %s; update the lab", productionPool)
	}
	m.kubectl(strings.ReplaceAll(string(pool), productionPool, labPool), "apply", "-f", "-")

	sink := []string{"${PROBE_IMAGE}", m.image, "${SINK_IP}", lab.HostIP, "${SINK_PORT}", strconv.Itoa(sinkPort), "${EXTERNAL_IP}", externalIP}
	m.kubectl(m.manifest("migration.yaml", sink...), "apply", "-f", "-")
	m.kubectl("", "-n", "mig-policed", "apply", "-f", p.PodNetworkPolicy())
	m.kubectl("", "-n", "mig-policed", "patch", "networkpolicy", "pod-network-only", "--type=json", "-p", namespaceSelectorRewrite)
	for _, namespace := range []string{"mig-control", "mig-policed"} {
		m.kubectl(m.manifest("prober.yaml", append(sink, "${NAMESPACE}", namespace)...), "apply", "-f", "-")
	}
	m.kubectl(m.manifest("node-shell.yaml"), "apply", "-f", "-")
	m.waitWorkloads()
	m.kubectl("", "-n", "mig-app", "wait", "service/web", "--for=jsonpath={.status.loadBalancer.ingress[0].ip}", "--timeout=3m")
	m.setLB()
	m.kubectl("", "-n", "mig-app", "exec", "deploy/data", "--", "sh", "-c", "echo "+knownData+" > /data/known")
	m.dataIntact()
}

func (m *migration) setLB() {
	ip := m.kubectl("", "-n", "mig-app", "get", "service", "web", "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}")
	m.lb.Store(&ip)
	m.record("LoadBalancer address: %s", ip)
}

// watch starts the monitor: the host's report sink for the probers, and
// checks of the API every second and of the LoadBalancer address every
// 250 ms. It prints the per-step table when the test ends.
func (m *migration) watch() {
	samples, err := os.Create(m.cluster.Path("samples.txt"))
	must(m.t, err)
	m.monitor = lab.NewMonitor(samples)
	m.monitor.Blocked = func(signal string) bool {
		return strings.HasPrefix(signal, "mig-policed/") && strings.HasSuffix(signal, "/external")
	}
	listener, err := net.Listen("tcp", net.JoinHostPort(lab.HostIP, strconv.Itoa(sinkPort)))
	must(m.t, err)
	server := &http.Server{Handler: m.monitor, ReadHeaderTimeout: 5 * time.Second}
	go server.Serve(listener)
	ctx, cancel := context.WithCancel(m.ctx)
	client := &http.Client{Timeout: time.Second}
	go m.monitor.Poll(ctx, "api", time.Second, func(ctx context.Context) bool {
		_, err := m.cluster.Kubectl(ctx, "", "get", "--raw", "/readyz", "--request-timeout=2s")
		return err == nil
	})
	go m.monitor.Poll(ctx, "lb", 250*time.Millisecond, func(ctx context.Context) bool {
		request, err := http.NewRequestWithContext(ctx, "GET", "http://"+*m.lb.Load()+"/", nil)
		if err != nil {
			return false
		}
		response, err := client.Do(request)
		if err != nil {
			return false
		}
		response.Body.Close()
		return response.StatusCode == http.StatusOK
	})
	m.t.Cleanup(func() {
		cancel()
		server.Close()
		m.monitor.End()
		table := m.monitor.Table()
		fmt.Fprintf(m.results, "\n%s\n", table)
		m.t.Log("\n" + table)
		samples.Close()
	})
	m.step("baseline")
	m.settle()
}

func (m *migration) step(name string) {
	m.t.Helper()
	m.monitor.Step(name)
	m.record("== %s %s", time.Now().Format(time.TimeOnly), name)
}

// settle lets the monitor take 20 seconds of samples.
func (m *migration) settle() { must(m.t, lab.Sleep(m.ctx, 20*time.Second)) }

func (m *migration) window(step string) map[string]lab.Stat {
	m.t.Helper()
	stats, _, err := m.monitor.Window(step)
	must(m.t, err)
	return stats
}

// allowed are the signals that should always succeed: everything but the
// policed probers' external connections.
func (m *migration) allowed(stats map[string]lab.Stat) []string {
	signals := []string{}
	for signal := range stats {
		if !m.monitor.Blocked(signal) {
			signals = append(signals, signal)
		}
	}
	slices.Sort(signals)
	return signals
}

// healthy fails unless, in the step so far, every allowed signal succeeded at
// least every three seconds and no policed prober reached the external address.
func (m *migration) healthy(step string) {
	m.t.Helper()
	stats := m.window(step)
	if len(stats) < 2+2*2*4 {
		m.t.Errorf("%s: only %d signals reported: %v", step, len(stats), stats)
	}
	for _, signal := range m.allowed(stats) {
		if stats[signal].Outage > 3*time.Second {
			m.t.Errorf("%s: %s was down for %s", step, signal, stats[signal].Outage)
		}
	}
	m.noLeaks(step)
}

func (m *migration) noLeaks(step string) {
	m.t.Helper()
	for signal, stat := range m.window(step) {
		if m.monitor.Blocked(signal) && stat.OK > 0 {
			m.t.Errorf("%s: a policed prober reached the external address %d times (%s)", step, stat.OK, signal)
		}
	}
}

// maxOutage is the longest outage of an allowed signal in the step.
func (m *migration) maxOutage(step string, prefix string) time.Duration {
	stats := m.window(step)
	longest := time.Duration(0)
	for _, signal := range m.allowed(stats) {
		if strings.HasPrefix(signal, prefix) {
			longest = max(longest, stats[signal].Outage)
		}
	}
	return longest
}

func (m *migration) talos(args ...string) string {
	m.t.Helper()
	output, err := m.cluster.Talos(m.ctx, args...)
	must(m.t, err)
	return output
}

// patch applies machine config patches to nodes, one at a time.
func (m *migration) patch(nodes []string, files ...string) {
	m.t.Helper()
	for _, node := range nodes {
		args := []string{"-n", m.ips[node], "patch", "machineconfig"}
		for _, file := range files {
			path, err := filepath.Abs(file)
			must(m.t, err)
			args = append(args, "--patch", "@"+path)
		}
		m.talos(args...)
		m.record("patched %s with %s", node, strings.Join(files, ", "))
	}
}

// upgradeK8s runs `talosctl upgrade-k8s` to the running version, keeps its
// output and returns what it did to the manifests.
func (m *migration) upgradeK8s(label string, args ...string) map[string][]string {
	m.t.Helper()
	changes, err := m.tryUpgradeK8s(label, args...)
	must(m.t, err)
	return changes
}

func (m *migration) tryUpgradeK8s(label string, args ...string) (map[string][]string, error) {
	m.t.Helper()
	started := time.Now()
	output, err := m.cluster.Talos(m.ctx, append([]string{"-n", m.ips[m.controlPlane], "upgrade-k8s", "--to", m.cluster.Versions.Kubernetes}, args...)...)
	log := m.cluster.Path("upgrade-k8s-" + label + ".log")
	if err := errors.Join(os.WriteFile(log, []byte(output), 0600), err); err != nil {
		return nil, err
	}
	changes := lab.ManifestChanges(output)
	summary := []string{}
	for _, action := range []string{"Pruned", "deleted", "created", "configured"} {
		if objects := changes[action]; len(objects) > 0 {
			summary = append(summary, fmt.Sprintf("%s (%d): %s", action, len(objects), strings.Join(objects, " ")))
		}
	}
	m.record("upgrade-k8s %s %v took %s; %d unchanged\n  %s", label, args, time.Since(started).Round(time.Second), len(changes["unchanged"]), strings.Join(summary, "\n  "))
	return changes, nil
}

func (m *migration) exists(kind, namespace, name string) bool {
	_, err := m.cluster.Kubectl(m.ctx, "", "-n", namespace, "get", kind, name)
	return err == nil
}

func (m *migration) waitCilium() {
	m.t.Helper()
	m.eventually("Cilium DaemonSet exists", 5*time.Minute, func() bool { return m.exists("daemonset", "kube-system", "cilium") })
	m.kubectl("", "-n", "kube-system", "rollout", "status", "daemonset/cilium", "--timeout=10m")
	m.kubectl("", "-n", "kube-system", "rollout", "status", "deployment/cilium-operator", "--timeout=10m")
}

// waitWorkloads waits until every Deployment and DaemonSet has its pods ready.
func (m *migration) waitWorkloads() {
	m.t.Helper()
	deadline := time.Now().Add(10 * time.Minute)
	for {
		output, err := m.cluster.Kubectl(m.ctx, "", "get", "deployments,daemonsets", "-A", "-o", `jsonpath={range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name}{"\n"}{end}`)
		if err == nil {
			for _, line := range strings.Fields(output) {
				parts := strings.Split(line, "/")
				_, err = m.cluster.Kubectl(m.ctx, "", "-n", parts[1], "rollout", "status", strings.ToLower(parts[0])+"/"+parts[2], "--timeout="+time.Until(deadline).Round(time.Second).String())
				if err != nil {
					break
				}
			}
		}
		if err == nil {
			return
		}
		if time.Now().After(deadline) {
			m.t.Fatalf("workloads not ready: %v\n%s", err, m.kubectl("", "get", "pods", "-A", "-o", "wide"))
		}
		must(m.t, lab.Sleep(m.ctx, 5*time.Second))
	}
}

// waitReporting waits until, for five seconds, every signal but the policed
// probers' external checks has succeeded at least every three seconds.
func (m *migration) waitReporting() {
	m.t.Helper()
	started := time.Now()
	for time.Since(started) < 10*time.Minute {
		must(m.t, lab.Sleep(m.ctx, 5*time.Second))
		stats := m.monitor.Recent(5 * time.Second)
		up := 0
		for _, signal := range m.allowed(stats) {
			if stats[signal].Outage < 3*time.Second {
				up++
			}
		}
		// The API, the LoadBalancer, and three allowed targets for each of
		// two namespaces on two workers.
		if up == len(m.allowed(stats)) && up >= 2+2*2*3 {
			m.record("every signal up again after %s", time.Since(started).Round(time.Second))
			return
		}
	}
	m.t.Fatalf("signals still down after 10 minutes:\n%s", m.monitor.Table())
}

// unmanaged lists running non-hostNetwork pods without a CiliumEndpoint:
// pods still on Flannel's network.
func (m *migration) unmanaged() [][2]string {
	m.t.Helper()
	var pods, endpoints struct {
		Items []struct {
			Metadata struct{ Namespace, Name string }
			Spec     struct{ HostNetwork bool }
			Status   struct{ Phase string }
		}
	}
	must(m.t, json.Unmarshal([]byte(m.kubectl("", "get", "pods", "-A", "-o", "json")), &pods))
	must(m.t, json.Unmarshal([]byte(m.kubectl("", "get", "ciliumendpoints", "-A", "-o", "json")), &endpoints))
	managed := map[[2]string]bool{}
	for _, e := range endpoints.Items {
		managed[[2]string{e.Metadata.Namespace, e.Metadata.Name}] = true
	}
	found := [][2]string{}
	for _, p := range pods.Items {
		key := [2]string{p.Metadata.Namespace, p.Metadata.Name}
		if !p.Spec.HostNetwork && (p.Status.Phase == "Running" || p.Status.Phase == "Pending") && !managed[key] {
			found = append(found, key)
		}
	}
	return found
}

// restartUnmanaged deletes the pods still on Flannel's network so their
// controllers recreate them on Cilium's.
func (m *migration) restartUnmanaged() {
	m.t.Helper()
	pods := m.unmanaged()
	names := []string{}
	for _, pod := range pods {
		m.kubectl("", "-n", pod[0], "delete", "pod", pod[1], "--wait=false")
		names = append(names, pod[0]+"/"+pod[1])
	}
	m.record("restarted %d pods: %s", len(names), strings.Join(names, " "))
}

// reboot reboots a node and waits for it and every workload to be ready.
func (m *migration) reboot(node string) {
	m.t.Helper()
	started := time.Now()
	m.talos("-n", m.ips[node], "reboot", "--wait", "--timeout", "10m")
	m.kubectl("", "wait", "--for=condition=Ready", "node/"+node, "--timeout=10m")
	m.waitWorkloads()
	m.record("rebooted %s in %s", node, time.Since(started).Round(time.Second))
}

// rollingReboot reboots the control plane, then each worker, waiting for
// every workload between nodes as production's runbook does.
func (m *migration) rollingReboot() {
	m.t.Helper()
	for _, node := range m.nodes() {
		m.reboot(node)
	}
}

// rebootEach reboots the control plane, then each worker, waiting between
// nodes only for the node and the CNI's DaemonSet: after a rollback, pods
// whose network Cilium had set up recover only when their own node reboots.
func (m *migration) rebootEach(daemonSet string) {
	m.t.Helper()
	for _, node := range m.nodes() {
		started := time.Now()
		m.talos("-n", m.ips[node], "reboot", "--wait", "--timeout", "10m")
		m.kubectl("", "wait", "--for=condition=Ready", "node/"+node, "--timeout=10m")
		m.kubectl("", "-n", "kube-system", "rollout", "status", "daemonset/"+daemonSet, "--timeout=10m")
		m.record("rebooted %s in %s", node, time.Since(started).Round(time.Second))
	}
	m.waitWorkloads()
}

// leftovers records what each node still has of Flannel, kube-proxy,
// kube-network-policies and Cilium.
func (m *migration) leftovers(label string) map[string]string {
	m.t.Helper()
	m.kubectl("", "-n", "node-shell", "rollout", "status", "daemonset/shell", "--timeout=5m")
	found := map[string]string{}
	for _, node := range m.nodes() {
		pod := m.kubectl("", "-n", "node-shell", "get", "pod", "-o", "name", "--field-selector", "spec.nodeName="+node)
		found[node] = m.kubectl("", "-n", "node-shell", "exec", pod, "--", "sh", "-c", leftoverScript)
		m.record("leftovers %s on %s:\n%s", label, node, found[node])
	}
	return found
}

// leftoverScript prints one line per kind of CNI state on a node.
const leftoverScript = `
echo "links: $(ip -br link | awk '{sub("@.*", "", $1); print $1}' | grep -E '^(cni0|flannel|cilium|kube-ipvs)' | sort | tr '\n' ' ')"
echo "pod-links: veth=$(ip -br link | grep -c '^veth') lxc=$(ip -br link | grep -c '^lxc')"
echo "cni-configs: $(ls /host/etc/cni/net.d | tr '\n' ' ')"
echo "nft-tables: $(nft list tables | awk '{print $2 "/" $3}' | grep -vE '^(ip|ip6)/(filter|nat|mangle|raw)$|^inet/talos$' | sort | tr '\n' ' ')"
echo "routes: flannel=$(ip route | grep -cE 'cni0|flannel') cilium=$(ip route | grep -c cilium)"
`

// clean fails unless a node has nothing of the given stacks left.
func (m *migration) clean(found map[string]string, patterns ...string) {
	m.t.Helper()
	for node, output := range found {
		for _, pattern := range patterns {
			if regexp.MustCompile(pattern).MatchString(output) {
				m.t.Errorf("%s still has %s:\n%s", node, pattern, output)
			}
		}
	}
}

// Leftover patterns of each stack.
var (
	flannelLeftovers = []string{`links: .*(cni0|flannel)`, `nft-tables: .*(flannel|kube-proxy|kube-network-policies)`, `cni-configs: .*flannel`, `routes: flannel=[1-9]`}
	ciliumLeftovers  = []string{`links: .*cilium`, `cni-configs: .*cilium`, `routes: .*cilium=[1-9]`, `pod-links: .*lxc=[1-9]`}
)

// dataIntact fails unless the local volume still holds the known data.
func (m *migration) dataIntact() {
	m.t.Helper()
	for range 60 {
		output, err := m.cluster.Kubectl(m.ctx, "", "-n", "mig-app", "exec", "deploy/data", "--", "cat", "/data/known")
		if err == nil {
			if strings.TrimSpace(output) != knownData {
				m.t.Fatalf("local volume holds %q, want %q", output, knownData)
			}
			return
		}
		must(m.t, lab.Sleep(m.ctx, 5*time.Second))
	}
	m.t.Fatal("could not read the local volume for 5 minutes")
}

// renderCilium writes an inline manifest patch with production's Cilium, or
// another chart or extra values; see ciliumPatch.
func (m *migration) renderCilium(label, chart string, extra ...string) string {
	m.t.Helper()
	return ciliumPatch(m.t, m.ctx, m.production, m.cluster.Directory, label, chart, extra...)
}

// policyEnforced runs fresh probes, as the existing scenarios do, and fails
// unless Cilium blocks the policed pods' external connections from the first
// packet while their allowed connections pass.
func (m *migration) policyEnforced() {
	m.t.Helper()
	m.refreshTargets()
	_, policed := m.firstPacket()
	m.none(policed, "external", firstPacket...)
}

// replaceCilium swaps the control plane's Cilium inline manifest for another.
// Talos appends inline manifests from a patch rather than merging them by
// name, so the old one is deleted in the same apply. Terraform regenerates
// the whole config and needs no such step.
func (m *migration) replaceCilium(patch string) {
	m.t.Helper()
	m.patchCilium("patches/remove-cilium.yaml", patch)
}

// patchCilium patches the control plane with files that change its Cilium
// inline manifest, and waits until Talos has rendered the change.
// `upgrade-k8s` reads the rendered manifests, so one started right after a
// patch can still apply or prune the previous ones.
func (m *migration) patchCilium(files ...string) {
	m.t.Helper()
	before := m.manifestVersion("cilium")
	m.patch([]string{m.controlPlane}, files...)
	m.eventually("Talos rendered the Cilium manifest change", 2*time.Minute, func() bool { return m.manifestVersion("cilium") != before })
}

// manifestVersion is the version of Talos's rendered inline manifest, or
// "absent".
func (m *migration) manifestVersion(name string) string {
	output, err := m.cluster.Talos(m.ctx, "-n", m.ips[m.controlPlane], "get", "manifests", "99-"+name, "-o", "json")
	if err != nil {
		return "absent"
	}
	var manifest struct{ Metadata struct{ Version any } }
	if err := json.Unmarshal([]byte(output), &manifest); err != nil {
		return "unreadable"
	}
	return fmt.Sprint(manifest.Metadata.Version)
}

// agents returns the Cilium agent pods' UIDs and images.
func (m *migration) agents() (uids, images []string) {
	m.t.Helper()
	output := m.kubectl("", "-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium", "-o", `jsonpath={range .items[*]}{.metadata.uid} {.spec.containers[0].image}{"\n"}{end}`)
	for _, line := range strings.Split(output, "\n") {
		if fields := strings.Fields(line); len(fields) == 2 {
			uids, images = append(uids, fields[0]), append(images, fields[1])
		}
	}
	return uids, images
}

func (m *migration) ciliumConfig(key string) string {
	m.t.Helper()
	return m.kubectl("", "-n", "kube-system", "get", "configmap", "cilium-config", "-o", "jsonpath={.data."+key+"}")
}

// inventory lists the Cilium objects in Talos's manifest inventory, which
// `upgrade-k8s` prunes once they are no longer in the machine config.
func (m *migration) inventory() []string {
	m.t.Helper()
	var inventory struct{ Data map[string]string }
	must(m.t, json.Unmarshal([]byte(m.kubectl("", "-n", "kube-system", "get", "configmap", "talos-bootstrap-manifests-inventory", "-o", "json")), &inventory))
	keys := []string{}
	for key := range inventory.Data {
		if regexp.MustCompile(`cilium|hubble`).MatchString(key) {
			keys = append(keys, key)
		}
	}
	slices.Sort(keys)
	return keys
}

// reconcile asks Flux to reconcile a HelmRelease now.
func (m *migration) reconcile(namespace, name string) {
	m.t.Helper()
	m.kubectl("", "-n", namespace, "annotate", "helmrelease", name, "--overwrite", "reconcile.fluxcd.io/requestedAt="+time.Now().Format(time.RFC3339Nano))
}

// eventually polls check every two seconds until it holds, and fails after timeout.
func (m *migration) eventually(what string, timeout time.Duration, check func() bool) time.Duration {
	m.t.Helper()
	started := time.Now()
	for !check() {
		if time.Since(started) > timeout {
			m.t.Fatalf("%s: not after %s", what, timeout)
		}
		must(m.t, lab.Sleep(m.ctx, 2*time.Second))
	}
	took := time.Since(started).Round(time.Second)
	m.record("%s after %s", what, took)
	return took
}

// holder is the node that answers ARP for the LoadBalancer address.
func (m *migration) holder() string {
	m.t.Helper()
	// Refresh the host's neighbour entry.
	client := &http.Client{Timeout: time.Second}
	if response, err := client.Get("http://" + *m.lb.Load() + "/"); err == nil {
		response.Body.Close()
	}
	node, err := m.cluster.Holder(m.ctx, *m.lb.Load(), m.nodes())
	must(m.t, err)
	m.record("%s announces %s", node, *m.lb.Load())
	return node
}

// freeze stops a node's VM for d, as a power loss or a hang would silence it,
// then lets it run again and waits for it and every workload to be ready.
func (m *migration) freeze(node string, d time.Duration) {
	m.t.Helper()
	must(m.t, m.cluster.Freeze(m.ctx, node, false))
	m.record("froze %s for %s", node, d)
	err := lab.Sleep(m.ctx, d)
	must(m.t, errors.Join(err, m.cluster.Freeze(context.Background(), node, true)))
	m.kubectl("", "wait", "--for=condition=Ready", "node/"+node, "--timeout=10m")
	m.waitWorkloads()
	m.record("%s back", node)
}

// report records a step's outages without asserting them.
func (m *migration) report(step string) {
	m.t.Helper()
	m.reportSpan(step, step)
}

// reportSpan records the outages from the start of one step to the end of
// another without asserting them.
func (m *migration) reportSpan(first, last string) {
	m.t.Helper()
	stats, err := m.monitor.Span(first, last)
	must(m.t, err)
	step := first
	if last != first {
		step = first + " to " + last
	}
	lines := []string{}
	for _, signal := range slices.Sorted(maps.Keys(stats)) {
		stat := stats[signal]
		lines = append(lines, fmt.Sprintf("  %-34s ok=%d failed=%d longest-outage=%s", signal, stat.OK, stat.Failed, stat.Outage.Round(100*time.Millisecond)))
	}
	m.record("%s:\n%s", step, strings.Join(lines, "\n"))
}

// cutover moves the cluster from Flannel to Talos-owned Cilium with the
// sequence the cilium-migration scenario found to work: config to the
// workers, then the control plane, which makes Talos install Cilium at once;
// upgrade-k8s to prune Flannel and kube-proxy; restart the pods left on
// Flannel's network; then reboot each node to clear Flannel's leftovers.
func (m *migration) cutover(values ...string) {
	m.t.Helper()
	m.step("cutover")
	m.patch(m.workers, "patches/cni-none-worker.yaml")
	m.patchCilium("patches/cni-none-controlplane.yaml", m.renderCilium("cutover", "", values...))
	m.waitCilium()
	m.upgradeK8s("cutover")
	m.restartUnmanaged()
	m.waitWorkloads()
	m.waitReporting()
	m.step("cutover-reboot")
	m.rollingReboot()
	m.waitReporting()
	m.dataIntact()
}
