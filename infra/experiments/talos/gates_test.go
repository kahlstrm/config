//go:build integration

package talos_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/cnipods"
	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

// The phase gates of the gated cutover: each waits for its condition or
// fails the test, and records how long it took. gateReady and gateAgents
// return an error instead, so a scenario can expect it to fail.

// gateReady waits until every node has a Ready Cilium agent: the gate
// before pods are recreated, which ends the outage. With Kubernetes IPAM a
// node's agent needs neither the operator nor its health checks of other
// nodes to network new pods.
func (m *migration) gateReady(timeout time.Duration) error {
	m.t.Helper()
	return m.waitAgents("Ready", timeout, m.agentsReady)
}

// gateAgents waits until every node has a Ready Cilium agent that reports
// itself healthy, including its health checks of the other nodes, and the
// operator is available.
func (m *migration) gateAgents(timeout time.Duration) error {
	m.t.Helper()
	return m.waitAgents("healthy", timeout, m.agentsHealthy)
}

func (m *migration) waitAgents(what string, timeout time.Duration, check func() error) error {
	m.t.Helper()
	started, reported := time.Now(), time.Now()
	var last error
	defer func() {
		// When each agent pod was created and became Ready, and its restarts.
		pods, _ := m.cluster.Kubectl(m.ctx, "", "-n", "kube-system", "get", "pods", "-l", "app.kubernetes.io/part-of=cilium", "-o", `jsonpath={range .items[*]}{.metadata.name} {.spec.nodeName} created={.metadata.creationTimestamp} ready={.status.conditions[?(@.type=="Ready")].lastTransitionTime} restarts={.status.containerStatuses[*].restartCount}{"\n"}{end}`)
		m.record("Cilium pods:\n%s", pods)
	}()
	for time.Since(started) < timeout {
		if last = check(); last == nil {
			m.record("gate: Cilium agents %s on every node after %s", what, time.Since(started).Round(time.Second))
			return nil
		}
		if time.Since(reported) > time.Minute {
			m.record("gate: still waiting for Cilium agents %s after %s: %v", what, time.Since(started).Round(time.Second), last)
			reported = time.Now()
		}
		if err := lab.Sleep(m.ctx, 5*time.Second); err != nil {
			return err
		}
	}
	return fmt.Errorf("Cilium agents not %s on every node after %s: %w", what, timeout, last)
}

// readyAgents returns each node's Ready agent pod, or an error naming a node
// without one.
func (m *migration) readyAgents() (map[string]string, error) {
	output, err := m.cluster.Kubectl(m.ctx, "", "-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium", "-o", `jsonpath={range .items[*]}{.metadata.name} {.spec.nodeName} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}`)
	if err != nil {
		return nil, err
	}
	agents := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		if fields := strings.Fields(line); len(fields) == 3 && fields[2] == "True" {
			agents[fields[1]] = fields[0]
		}
	}
	for _, node := range m.nodes() {
		if _, ok := agents[node]; !ok {
			return nil, fmt.Errorf("no Ready agent on %s: %q", node, output)
		}
	}
	return agents, nil
}

func (m *migration) agentsReady() error {
	_, err := m.readyAgents()
	return err
}

func (m *migration) agentsHealthy() error {
	agents, err := m.readyAgents()
	if err != nil {
		return err
	}
	for node, pod := range agents {
		status, err := m.cluster.Kubectl(m.ctx, "", "-n", "kube-system", "exec", pod, "-c", "cilium-agent", "--", "cilium-dbg", "status", "--brief")
		if err != nil || strings.TrimSpace(status) != "OK" {
			m.diagnoseEndpointSync(node, pod, status)
			return fmt.Errorf("agent on %s: %q %v", node, status, err)
		}
	}
	_, err = m.cluster.Kubectl(m.ctx, "", "-n", "kube-system", "wait", "deployment/cilium-operator", "--for=condition=Available", "--timeout=5s")
	return err
}

// gateEndpoints waits until every CiliumEndpoint is ready and records how
// many each node has.
func (m *migration) gateEndpoints() {
	m.t.Helper()
	started := time.Now()
	for {
		var endpoints struct {
			Items []struct {
				Metadata struct{ Namespace, Name string }
				Status   struct {
					State      string
					Networking struct{ Node string }
				}
			}
		}
		must(m.t, json.Unmarshal([]byte(m.kubectl("", "get", "ciliumendpoints", "-A", "-o", "json")), &endpoints))
		perNode, notReady := map[string]int{}, []string{}
		for _, e := range endpoints.Items {
			perNode[e.Status.Networking.Node]++
			if e.Status.State != "ready" {
				notReady = append(notReady, fmt.Sprintf("%s/%s=%s", e.Metadata.Namespace, e.Metadata.Name, e.Status.State))
			}
		}
		if len(notReady) == 0 {
			m.record("gate: %d CiliumEndpoints ready after %s; per node address: %v", len(endpoints.Items), time.Since(started).Round(time.Second), perNode)
			m.reconcileEndpoints()
			return
		}
		if time.Since(started) > 5*time.Minute {
			m.t.Fatalf("CiliumEndpoints not ready after 5 minutes: %v", notReady)
		}
		must(m.t, lab.Sleep(m.ctx, 5*time.Second))
	}
}

// gateTraffic starts a fresh, unpoliced pod on every node that resolves
// cluster DNS and connects to the echo pod on the first control plane and to
// its Service, and fails unless each did so within three seconds.
func (m *migration) gateTraffic(label string) {
	m.t.Helper()
	m.refreshTargets()
	for _, node := range m.nodes() {
		tally := m.probeOn(label+"-"+node, "np-control", node, 1, []int{0, 3}, "dns", "pod", "service")
		for _, target := range []string{"dns", "pod", "service"} {
			if tally.Connected(3, target) != 1 {
				m.t.Fatalf("gate %s: a new pod on %s did not reach %s", label, node, target)
			}
		}
	}
	m.record("gate: DNS, the echo pod and its Service reachable from a new pod on every node")
}

// talosResources decodes `talosctl get ... -o json`, a stream of objects.
func talosResources(output string) ([]talosResource, error) {
	decoder := json.NewDecoder(strings.NewReader(output))
	resources := []talosResource{}
	for {
		var r talosResource
		if err := decoder.Decode(&r); errors.Is(err, io.EOF) {
			return resources, nil
		} else if err != nil {
			return nil, err
		}
		resources = append(resources, r)
	}
}

type talosResource struct {
	Node     string
	Metadata struct{ ID string }
	Spec     json.RawMessage
}

// cniManifests are Talos's manifests that the cni setting adds or removes.
var cniManifests = map[string][]string{
	lab.Cilium:  {"99-cilium"},
	lab.Flannel: {"05-flannel", "10-kube-proxy"},
}

// gateManifests waits until every control plane renders the same set of
// manifests, with the CNI's manifests identical and the other CNI's absent:
// upgrade-k8s applies and prunes from one control plane's set, and a control
// plane left behind would bring the old CNI back when it next starts.
func (m *migration) gateManifests(cni string) {
	m.t.Helper()
	started := time.Now()
	other := lab.Flannel
	if cni == lab.Flannel {
		other = lab.Cilium
	}
	for {
		problems := []string{}
		var reference string
		for _, cp := range m.controlPlanes {
			output, err := m.cluster.Talos(m.ctx, "-n", m.ips[cp], "get", "manifests", "-o", "json")
			resources, decodeErr := talosResources(output)
			if err = errors.Join(err, decodeErr); err != nil {
				problems = append(problems, fmt.Sprintf("%s: %v", cp, err))
				continue
			}
			hashes := map[string]string{}
			for _, r := range resources {
				sum := sha256.Sum256(r.Spec)
				hashes[r.Metadata.ID] = hex.EncodeToString(sum[:8])
			}
			for _, id := range cniManifests[cni] {
				if hashes[id] == "" {
					problems = append(problems, cp+" lacks "+id)
				}
			}
			for _, id := range cniManifests[other] {
				if hashes[id] != "" {
					problems = append(problems, cp+" still has "+id)
				}
			}
			ids := slices.Sorted(maps.Keys(hashes))
			summary := strings.Join(ids, " ")
			for _, id := range cniManifests[cni] {
				summary += " " + id + "=" + hashes[id]
			}
			if reference == "" {
				reference = summary
			} else if summary != reference {
				problems = append(problems, fmt.Sprintf("%s renders %s, %s renders %s", cp, summary, m.controlPlanes[0], reference))
			}
		}
		if len(problems) == 0 {
			m.record("gate: every control plane renders the %s manifests after %s: %s", cni, time.Since(started).Round(time.Second), reference)
			return
		}
		if time.Since(started) > 3*time.Minute {
			m.t.Fatalf("control planes' manifests did not converge on %s: %v", cni, problems)
		}
		must(m.t, lab.Sleep(m.ctx, 5*time.Second))
	}
}

var (
	etcdID      = regexp.MustCompile(`\b[0-9a-f]{16}\b`)
	etcdHealthy = regexp.MustCompile(`\bfalse\s+\S+\s+\S+\s*$`)
)

// gateEtcd waits until every control plane's etcd member is up, without
// errors, and agrees on one leader, which it returns by hostname.
func (m *migration) gateEtcd() string {
	m.t.Helper()
	started := time.Now()
	ips := []string{}
	for _, cp := range m.controlPlanes {
		ips = append(ips, m.ips[cp])
	}
	for {
		leader, err := m.etcdLeader(ips)
		if err == nil {
			m.record("gate: etcd has %d healthy members, leader %s, after %s", len(ips), leader, time.Since(started).Round(time.Second))
			return leader
		}
		if time.Since(started) > 10*time.Minute {
			m.t.Fatalf("etcd not healthy after 10 minutes: %v", err)
		}
		must(m.t, lab.Sleep(m.ctx, 5*time.Second))
	}
}

func (m *migration) etcdLeader(ips []string) (string, error) {
	nodes := strings.Join(ips, ",")
	status, err := m.cluster.Talos(m.ctx, "-n", nodes, "etcd", "status")
	if err != nil {
		return "", err
	}
	members, err := m.cluster.Talos(m.ctx, "-n", ips[0], "etcd", "members")
	if err != nil {
		return "", err
	}
	hostnames := map[string]string{}
	for _, line := range strings.Split(members, "\n")[1:] {
		if fields := strings.Fields(line); len(fields) > 2 && etcdID.MatchString(fields[1]) {
			hostnames[fields[1]] = fields[2]
		}
	}
	if len(hostnames) != len(ips) {
		return "", fmt.Errorf("etcd members: %s", members)
	}
	leaders := map[string]bool{}
	rows := 0
	for _, line := range strings.Split(status, "\n")[1:] {
		ids := etcdID.FindAllString(line, -1)
		if len(ids) < 2 {
			continue
		}
		rows++
		if !etcdHealthy.MatchString(line) {
			return "", fmt.Errorf("unhealthy member: %s", line)
		}
		leaders[ids[1]] = true
	}
	if rows != len(ips) || len(leaders) != 1 {
		return "", fmt.Errorf("etcd status: %s", status)
	}
	for id := range leaders {
		if hostname, ok := hostnames[id]; ok {
			return strings.Split(hostname, ".")[0], nil
		}
	}
	return "", fmt.Errorf("leader is no member: %s", status)
}

// vipHolder is the control plane that holds the API VIP.
func (m *migration) vipHolder() string {
	m.t.Helper()
	ips := []string{}
	for _, cp := range m.controlPlanes {
		ips = append(ips, m.ips[cp])
	}
	for range 60 {
		output, err := m.cluster.Talos(m.ctx, "-n", strings.Join(ips, ","), "get", "addresses", "-o", "json")
		resources, decodeErr := talosResources(output)
		if errors.Join(err, decodeErr) == nil {
			for _, r := range resources {
				var spec struct{ Address string }
				if json.Unmarshal(r.Spec, &spec) == nil && spec.Address == labVIP+"/32" {
					for _, cp := range m.controlPlanes {
						if m.ips[cp] == r.Node {
							return cp
						}
					}
				}
			}
		}
		must(m.t, lab.Sleep(m.ctx, 5*time.Second))
	}
	m.t.Fatalf("no control plane holds %s", labVIP)
	return ""
}

// rebootGated reboots a node as the runbook does: a control plane only while
// all etcd members are healthy, so two stay up, and the next node only once
// etcd, the node, its Cilium agent and every workload are back.
func (m *migration) rebootGated(node string) {
	m.t.Helper()
	controlPlane := slices.Contains(m.controlPlanes, node)
	if controlPlane {
		m.gateEtcd()
	}
	m.reboot(node)
	if controlPlane {
		m.gateEtcd()
	}
}

// rebootAll reboots the API VIP's holder and the etcd leader in
// separate steps, moving etcd leadership off the VIP holder first if one
// node has both, then the rest, then each worker.
func (m *migration) rebootAll(prefix string) {
	m.t.Helper()
	rebooted := map[string]bool{}
	reboot := func(role, node string) {
		m.step(fmt.Sprintf("%s-%s-%s", prefix, role, node))
		m.rebootGated(node)
		rebooted[node] = true
	}
	if len(m.controlPlanes) > 1 {
		holder, leader := m.vipHolder(), m.gateEtcd()
		if holder == leader {
			m.forfeit(leader)
		}
		reboot("vip-holder", holder)
		holder, leader = m.vipHolder(), m.gateEtcd()
		if holder == leader {
			m.forfeit(leader)
			leader = m.gateEtcd()
		}
		m.record("VIP on %s, etcd leader %s", holder, leader)
		reboot("etcd-leader", leader)
	}
	for _, node := range m.nodes() {
		if !rebooted[node] {
			reboot("reboot", node)
		}
	}
}

// forfeit moves etcd leadership off a control plane.
func (m *migration) forfeit(node string) {
	m.t.Helper()
	m.talos("-n", m.ips[node], "etcd", "forfeit-leadership")
	m.eventually("etcd leadership moved off "+node, 2*time.Minute, func() bool {
		leader, err := m.etcdLeader([]string{m.ips[m.controlPlanes[0]], m.ips[m.controlPlanes[1]], m.ips[m.controlPlanes[2]]})
		return err == nil && leader != node
	})
}

// recreatePods runs the cni-pods procedure (cmd/cni-pods), after checking
// that its two ways of finding pods on the previous network agree, and
// returns its first plan.
func (m *migration) recreatePods() cnipods.Plan {
	m.t.Helper()
	k := func(ctx context.Context, args ...string) (string, error) { return m.cluster.Kubectl(ctx, "", args...) }
	inv, err := cnipods.Gather(m.ctx, k, m.cni0())
	must(m.t, err)
	byEndpoints := cnipods.Classify(inv)
	inv.Endpoints = nil
	bySandbox := cnipods.Classify(inv)
	// Sandbox ages may find more: an agent that restarted moves its Ready
	// time on. Recreating such a pod again is harmless; missing one is not.
	for _, key := range byEndpoints.Keys() {
		if !slices.Contains(bySandbox.Keys(), key) {
			m.t.Errorf("%s has no CiliumEndpoint, but its sandbox is newer than its node's agent", key)
		}
	}
	if len(bySandbox.Keys()) != len(byEndpoints.Keys()) {
		m.record("pods without a CiliumEndpoint %v, pods with sandboxes older than their node's agent %v", byEndpoints.Keys(), bySandbox.Keys())
	}
	var log strings.Builder
	started := time.Now()
	first, last, err := cnipods.Run(m.ctx, k, cnipods.Options{Timeout: 10 * time.Minute, Log: &log, CNI0: m.cni0()})
	m.record("cni-pods recreate took %s:\n%s", time.Since(started).Round(time.Second), log.String())
	must(m.t, err)
	if reported := first.Of(cnipods.Report); len(reported) > 0 {
		m.record("left for a decision: %v", reported)
	}
	if len(last.Candidates) > len(first.Of(cnipods.Report)) {
		m.t.Errorf("still on the previous network: %v", last.Keys())
	}
	return first
}

// cni0 finds residual cni0 bridges through the lab's talosctl, as
// production's cni-pods does through the operator's.
func (m *migration) cni0() cnipods.CNI0 {
	return cnipods.TalosCNI0(func(ctx context.Context, args ...string) (string, error) { return m.cluster.Talos(ctx, args...) })
}

// pending counts pods on the previous network, as cni-pods finds them.
func (m *migration) pending() int {
	m.t.Helper()
	inv, err := cnipods.Gather(m.ctx, func(ctx context.Context, args ...string) (string, error) { return m.cluster.Kubectl(ctx, "", args...) }, m.cni0())
	must(m.t, err)
	return len(cnipods.Classify(inv).Candidates)
}

// gatedUpgradeK8s runs upgrade-k8s once every node is Ready and etcd is
// healthy, and again, up to three times, if it fails: on a loaded host it
// has failed on an etcd request timeout mid-prune and on a kubelet health
// check. It is idempotent, so a retry finishes what the last run left; the
// returned changes merge every attempt's.
func (m *migration) gatedUpgradeK8s(label string, args ...string) map[string][]string {
	m.t.Helper()
	merged := map[string][]string{}
	for attempt := 1; ; attempt++ {
		m.kubectl("", "wait", "--for=condition=Ready", "nodes", "--all", "--timeout=10m")
		m.gateEtcd()
		changes, err := m.tryUpgradeK8s(fmt.Sprintf("%s-%d", label, attempt), args...)
		for action, objects := range changes {
			merged[action] = append(merged[action], objects...)
		}
		if err == nil {
			return merged
		}
		m.record("upgrade-k8s %s attempt %d failed: %v", label, attempt, err)
		if attempt == 3 {
			m.t.Fatalf("upgrade-k8s %s failed three times: %v", label, err)
		}
		must(m.t, lab.Sleep(m.ctx, 30*time.Second))
	}
}

// memory records each node's memory use.
func (m *migration) memory(label string) {
	m.t.Helper()
	ips := []string{}
	for _, node := range m.nodes() {
		ips = append(ips, m.ips[node])
	}
	output, err := m.cluster.Talos(m.ctx, "-n", strings.Join(ips, ","), "memory")
	m.record("memory %s (MiB):\n%s%v", label, output, err)
}

// reconcileEndpoints runs production's `cni-pods endpoints`, which joins
// CiliumEndpoints to the running pod-network pods, until it finds no
// problem: endpoints of deleted pods can linger for a moment.
func (m *migration) reconcileEndpoints() {
	m.t.Helper()
	k := func(ctx context.Context, args ...string) (string, error) { return m.cluster.Kubectl(ctx, "", args...) }
	started := time.Now()
	for {
		report, err := cnipods.Endpoints(m.ctx, k, nil)
		must(m.t, err)
		if len(report.Problems()) == 0 || time.Since(started) > 2*time.Minute {
			m.record("cni-pods endpoints after %s:\n%s", time.Since(started).Round(time.Second), report)
			if problems := report.Problems(); len(problems) > 0 {
				m.t.Errorf("cni-pods endpoints: %v", problems)
			}
			return
		}
		must(m.t, lab.Sleep(m.ctx, 5*time.Second))
	}
}

var endpointSyncError = regexp.MustCompile(`controller sync-to-k8s-ciliumendpoint \((\d+)\)`)

// diagnoseEndpointSync records, once per endpoint, what a failing
// sync-to-k8s-ciliumendpoint controller is about: the endpoint's pod, that
// pod's UID and hostIP, the CiliumEndpoint of the same name it cannot take
// over, and the agent's log lines about the pod.
func (m *migration) diagnoseEndpointSync(node, agent, status string) {
	match := endpointSyncError.FindStringSubmatch(status)
	if match == nil {
		return
	}
	// Once when first seen, and once more four minutes later, to show
	// whether it heals.
	key := node + "/" + match[1]
	if m.diagnosed == nil {
		m.diagnosed = map[string]time.Time{}
	}
	first, seen := m.diagnosed[key]
	switch {
	case !seen:
		m.diagnosed[key] = time.Now()
	case !first.IsZero() && time.Since(first) > 4*time.Minute:
		m.diagnosed[key] = time.Time{}
	default:
		return
	}
	run := func(args ...string) string {
		out, err := m.cluster.Kubectl(m.ctx, "", args...)
		if err != nil {
			return fmt.Sprintf("%s (%v)", strings.TrimSpace(out), err)
		}
		return strings.TrimSpace(out)
	}
	var endpoints []struct {
		Status struct {
			State       string `json:"state"`
			Identifiers struct {
				Namespace   string `json:"k8s-namespace"`
				Pod         string `json:"k8s-pod-name"`
				ContainerID string `json:"container-id"`
			} `json:"external-identifiers"`
		} `json:"status"`
	}
	raw := run("-n", "kube-system", "exec", agent, "-c", "cilium-agent", "--", "cilium-dbg", "endpoint", "get", match[1], "-o", "json")
	namespace, name, ep := "", "", raw
	if json.Unmarshal([]byte(raw), &endpoints) == nil && len(endpoints) == 1 {
		id := endpoints[0].Status.Identifiers
		namespace, name = id.Namespace, id.Pod
		ep = fmt.Sprintf("%s/%s state=%s container=%s", namespace, name, endpoints[0].Status.State, id.ContainerID)
	}
	report := []string{"endpoint " + match[1] + " on " + node + ": " + ep}
	if namespace != "" && name != "" {
		report = append(report,
			"pod: "+run("-n", namespace, "get", "pod", name, "-o", `jsonpath=uid={.metadata.uid} created={.metadata.creationTimestamp} node={.spec.nodeName} hostIP={.status.hostIP} podIP={.status.podIP} phase={.status.phase} deleting={.metadata.deletionTimestamp} owner={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}`),
			"ciliumendpoint: "+run("-n", namespace, "get", "ciliumendpoint", name, "-o", `jsonpath=uid={.metadata.uid} created={.metadata.creationTimestamp} owner={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}/{.metadata.ownerReferences[0].uid} node={.status.networking.node} id={.status.id} state={.status.state} deleting={.metadata.deletionTimestamp}`),
			"agent log:\n"+grepLines(run("-n", "kube-system", "logs", agent, "-c", "cilium-agent", "--since=30m"), name, 30),
		)
	}
	m.record("endpoint sync diagnosis:\n%s", strings.Join(report, "\n"))
}

// grepLines returns the last max lines of text that contain s.
func grepLines(text, s string, max int) string {
	found := []string{}
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, s) {
			found = append(found, line)
		}
	}
	if len(found) > max {
		found = found[len(found)-max:]
	}
	return strings.Join(found, "\n")
}
