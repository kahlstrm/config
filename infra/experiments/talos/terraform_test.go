//go:build integration

package talos_test

import (
	"context"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/cnipods"
	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

const (
	terraformFixture = "scenarios/cilium-terraform/terraform"
	// The lab's API VIP, outside the provisioner's node addresses and
	// MetalLB's pool.
	labVIP = "10.5.0.10"
)

// terraformLab provisions empty QEMU nodes through production's
// talos-cluster module with the fixture in terraformFixture.
type terraformLab struct {
	controlPlanes      int
	controlPlaneMemory string
	tf                 lab.Terraform
	vars               map[string]any
	// IP by hostname, as the module knows the nodes.
	cps, workers map[string]string
}

func (l *terraformLab) provision(b *bench) {
	t := b.t
	cps, workers := b.cluster.NodeIPs()
	l.cps, l.workers = map[string]string{}, map[string]string{}
	for i, ip := range cps {
		l.cps[fmt.Sprintf("c%d", i+1)] = ip
	}
	for i, ip := range workers {
		l.workers[fmt.Sprintf("w%d", i+1)] = ip
	}
	// Nodes boot into maintenance mode, where they accept an unauthenticated
	// config, as new production nodes do.
	for _, ip := range slices.Concat(cps, workers) {
		started := time.Now()
		for {
			_, err := b.cluster.Run(b.ctx, lab.Cmd{Name: b.cluster.Talosctl(), Args: []string{"-n", ip, "-e", ip, "get", "disks", "--insecure"}, Env: b.cluster.ClientEnv()})
			if err == nil {
				break
			}
			if time.Since(started) > 10*time.Minute {
				t.Fatalf("%s not in maintenance mode after 10 minutes: %v", ip, err)
			}
			must(t, lab.Sleep(b.ctx, 5*time.Second))
		}
	}
	read := func(files []string) []string {
		contents := []string{}
		for _, file := range files {
			data, err := os.ReadFile(file)
			must(t, err)
			contents = append(contents, string(data))
		}
		return contents
	}
	source, err := filepath.Abs(terraformFixture)
	must(t, err)
	l.tf = lab.Terraform{Dir: source, Data: b.cluster.Path("terraform"), Run: lab.Exec}
	l.vars = map[string]any{
		"cni":                  lab.Flannel,
		"cilium_manifest":      "",
		"talos_config_version": b.cluster.Contract,
		"control_planes":       l.cps,
		"workers":              l.workers,
		"vip":                  labVIP,
		"storage_serial":       storageSerial,
		"lab_patches": map[string][]string{
			"controlplane": read(slices.Concat(b.cluster.Patches.All, b.cluster.Patches.ControlPlane)),
			"worker":       read(slices.Concat(b.cluster.Patches.All, b.cluster.Patches.Worker)),
		},
	}
	must(t, l.tf.Init(b.ctx))
	must(t, l.tf.SetVars(l.vars))
	started := time.Now()
	_, err = l.tf.Apply(b.ctx, "create")
	must(t, err)
	fmt.Fprintf(b.results, "terraform apply created the cluster in %s\n", time.Since(started).Round(time.Second))
	for name, path := range map[string]string{"talosconfig": b.cluster.Talosconfig(), "kubeconfig": b.cluster.Kubeconfig()} {
		value, err := l.tf.Output(b.ctx, name)
		must(t, err)
		must(t, os.WriteFile(path, []byte(value), 0600))
	}
	// The module's talosconfig names the control planes by hostname, which
	// production's DNS resolves and the lab's does not.
	_, err = b.cluster.Talos(b.ctx, append([]string{"config", "endpoint"}, cps...)...)
	must(t, err)
	// Nodes register with the API only once their kubelets start.
	for started := time.Now(); ; {
		output, err := b.cluster.Kubectl(b.ctx, "", "get", "nodes", "-o", "name")
		if err == nil && len(strings.Fields(output)) == len(cps)+len(workers) {
			break
		}
		if time.Since(started) > 15*time.Minute {
			t.Fatalf("nodes not registered after 15 minutes: %q %v", output, err)
		}
		must(t, lab.Sleep(b.ctx, 5*time.Second))
	}
	b.kubectl("", "wait", "--for=condition=Ready", "nodes", "--all", "--timeout=15m")
}

// setCNI changes the cni variable for the next applies, and the Cilium
// manifest from production's to another, unless manifest is empty.
func (l *terraformLab) setCNI(t *testing.T, cni, manifest string) {
	l.vars["cni"], l.vars["cilium_manifest"] = cni, manifest
	must(t, l.tf.SetVars(l.vars))
}

// bootIDs returns each node's boot ID, or "" for a node that does not answer.
func (m *migration) bootIDs() map[string]string {
	ids := map[string]string{}
	for _, node := range m.nodes() {
		id, _ := m.cluster.Talos(m.ctx, "-n", m.ips[node], "read", "/proc/sys/kernel/random/boot_id")
		ids[node] = strings.TrimSpace(id)
	}
	return ids
}

// applyNodes applies the Terraform configuration to one node at a time, as
// production's runbook does, and records how long each apply took and which
// nodes rebooted by the end of the step. It fails if an apply changes
// another node: a worker's talos_machine depends, through the kubeconfig and
// the bootstrap, on every control plane's, so targeting a worker also
// applies pending control-plane changes.
func (m *migration) applyNodes(l *terraformLab, step string, nodes ...string) {
	m.t.Helper()
	before := m.bootIDs()
	for _, node := range nodes {
		role := "worker"
		if _, ok := l.cps[node]; ok {
			role = "controlplane"
		}
		started := time.Now()
		output, err := l.tf.Apply(m.ctx, step+"-"+node, lab.NodeAddress("module.cluster", role, node))
		must(m.t, err)
		changed := updated.FindAllStringSubmatch(output, -1)
		summary := changedSummary(output)
		m.record("terraform apply %s took %s; changed:%s; DaemonSets: %s", node, time.Since(started).Round(time.Second), summary, m.daemonSets())
		if len(changed) != 1 || changed[0][1] != lab.NodeAddress("module.cluster", role, node) {
			m.t.Errorf("applying %s changed%s", node, summary)
		}
	}
	m.settle()
	after := m.bootIDs()
	rebooted := []string{}
	for _, node := range m.nodes() {
		if before[node] != after[node] {
			rebooted = append(rebooted, node)
		}
	}
	m.record("%s: nodes rebooted: %v", step, rebooted)
}

// changedSummary lists the resources a Terraform apply changed.
func changedSummary(output string) string {
	summary := ""
	for _, match := range updated.FindAllStringSubmatch(output, -1) {
		summary += " " + match[1]
	}
	return summary
}

var updated = regexp.MustCompile(`(?m)^\s*# (\S+) will be (?:updated in-place|created|destroyed|replaced)`)

// daemonSets lists kube-system's DaemonSets.
func (m *migration) daemonSets() string {
	output, _ := m.cluster.Kubectl(m.ctx, "", "-n", "kube-system", "get", "daemonsets", "-o", "jsonpath={.items[*].metadata.name}")
	return strings.TrimSpace(output)
}

// newTerraformLab sizes the Terraform scenarios' cluster: production's three
// control planes by default, at 2 GiB each so that they and two 3 GiB
// workers fit a 16 GiB CI runner.
func newTerraformLab(t *testing.T) *terraformLab {
	l := &terraformLab{controlPlanes: 3, controlPlaneMemory: "2GiB"}
	if value := os.Getenv("TALOS_LAB_CONTROL_PLANES"); value != "" {
		_, err := fmt.Sscan(value, &l.controlPlanes)
		must(t, err)
	}
	if value := os.Getenv("TALOS_LAB_CONTROL_PLANE_MEMORY"); value != "" {
		l.controlPlaneMemory = value
	}
	return l
}

// noChanges fails unless a plan of the whole configuration is empty.
func (m *migration) noChanges(l *terraformLab, when string) {
	m.t.Helper()
	if changes, plan, err := l.tf.Changes(m.ctx); err != nil || changes {
		m.t.Errorf("plan %s has changes (%v):\n%s", when, err, plan)
	}
}

// TestCiliumTerraform provisions a cluster like production, three control
// planes behind the API VIP and two workers, through production's
// talos-cluster module with cni = "flannel". It switches it to Cilium with
// the gated runbook, one Terraform apply per node with a gate after each
// phase, reboots the VIP holder and the etcd leader separately, then rolls
// back the same way.
func TestCiliumTerraform(t *testing.T) {
	l := newTerraformLab(t)
	m := newMigration(t, "cilium-terraform", start{terraform: l})
	m.record("nodes: control planes %v, workers %v", m.controlPlanes, m.workers)
	m.memory("flannel")
	cps, workers := slices.Sorted(maps.Keys(l.cps)), slices.Sorted(maps.Keys(l.workers))

	// Production's stack, as netpol-baseline measures it.
	m.step("flannel-probes")
	_, policed := m.firstPacket()
	if policed.Connected(0, "external") == 0 {
		t.Error("no first packet reached the external address; the ADR 4 window has closed")
	}
	m.none(policed, "external", 3)
	ipBlock, namespaceSelector := m.policyShapes()
	for _, shape := range []*lab.Tally{ipBlock, namespaceSelector} {
		m.all(shape, "pod", 5)
		m.all(shape, "service", 5)
		m.all(shape, "dns", 5)
		m.none(shape, "external", 5)
	}
	m.noChanges(l, "after creating the cluster")

	// Gate 0: etcd healthy and every control plane on Flannel.
	m.gateEtcd()
	m.gateManifests(lab.Flannel)

	// The first control plane's config makes Talos install Cilium on every
	// node at once; from the moment each agent runs, the pods Flannel
	// networked on its node have no network until they are recreated.
	l.setCNI(t, lab.Cilium, "")
	m.step("tf-first-controlplane")
	m.applyNodes(l, "tf-first-controlplane", cps[0])
	must(t, m.gateReady(10*time.Minute))
	m.record("pods on Flannel's network: %d", m.pending())

	// Gate 1 passed: recreate at once, as nothing else restores traffic,
	// then wait for the agents' own health checks.
	m.step("recreate-pods")
	if plan := m.recreatePods(); len(plan.Of(cnipods.Sequential)) != 2 {
		t.Errorf("recreated %v one at a time; want the StatefulSet's two pods", plan.Of(cnipods.Sequential))
	}
	must(t, m.gateAgents(10*time.Minute))
	m.gateEndpoints()
	m.gateTraffic("recreated")
	m.waitReporting()
	m.dataIntact()
	m.reportSpan("tf-first-controlplane", "recreate-pods")

	// The other control planes and the workers apply live; upgrade-k8s
	// prunes only after every control plane renders the same Cilium manifest.
	m.step("tf-other-nodes")
	m.applyNodes(l, "tf-other-nodes", slices.Concat(cps[1:], workers)...)
	m.gateManifests(lab.Cilium)
	for _, daemonSet := range []string{"kube-flannel", "kube-proxy"} {
		if !m.exists("daemonset", "kube-system", daemonSet) {
			t.Errorf("applying the config removed %s", daemonSet)
		}
	}

	m.step("upgrade-k8s")
	m.gateEtcd()
	dry := m.gatedUpgradeK8s("dry-run", "--dry-run")
	for _, daemonSet := range flannelDaemonSets {
		if !slices.Contains(dry["Pruned"], daemonSet) {
			t.Errorf("upgrade-k8s --dry-run would not prune %s", daemonSet)
		}
	}
	if pruned := slices.DeleteFunc(slices.Clone(dry["Pruned"]), func(object string) bool {
		return !strings.Contains(object, "cilium") && !strings.Contains(object, "hubble")
	}); len(pruned) > 0 {
		t.Errorf("upgrade-k8s --dry-run would prune Cilium objects: %v", pruned)
	}
	applied := m.gatedUpgradeK8s("cutover")
	for _, daemonSet := range flannelDaemonSets {
		if !slices.Contains(applied["deleted"], daemonSet) {
			t.Errorf("upgrade-k8s did not delete %s", daemonSet)
		}
	}
	must(t, m.gateAgents(5*time.Minute))
	if plan := m.recreatePods(); len(plan.Candidates) > 0 {
		t.Errorf("pods left on Flannel's network after the recreation: %v", plan.Keys())
	}
	m.gateTraffic("pruned")

	m.rebootAll("cutover")
	m.waitReporting()
	m.clean(m.leftovers("after-reboot"), flannelLeftovers...)
	m.dataIntact()

	m.step("cilium-steady")
	m.settle()
	m.healthy("cilium-steady")
	m.policyEnforced()
	m.memory("cilium")
	m.noChanges(l, "after the cutover")

	m.rollbackTerraform(l, "rollback", cps, workers, true)
}

// TestCiliumTerraformAbort rehearses the runbook's abort after the first
// control plane's apply, on the same cluster as cilium-terraform: with
// agents that fail before they touch a node's network; with agents that take
// over four nodes while the fifth keeps failing after its agent started; and
// with production's Cilium on every node and the rollback applied while the
// Kubernetes API is down.
func TestCiliumTerraformAbort(t *testing.T) {
	l := newTerraformLab(t)
	m := newMigration(t, "cilium-terraform-abort", start{terraform: l})
	m.record("nodes: control planes %v, workers %v", m.controlPlanes, m.workers)
	cps := slices.Sorted(maps.Keys(l.cps))
	m.gateEtcd()

	// Agents that look for the API where KubePrism does not listen fail in
	// their first init container, before they touch a node's network.
	values := m.cluster.Path("cilium-broken-values.yaml")
	must(t, os.WriteFile(values, []byte("k8sServicePort: 7446\n"), 0600))
	versions, err := m.production.Versions()
	must(t, err)
	broken, err := lab.RenderCilium(m.ctx, lab.Exec, ciliumChart(t, ""), m.cluster.Path("helm"), versions.Kubernetes, m.production.CiliumValues(), values)
	must(t, err)
	l.setCNI(t, lab.Cilium, broken)
	m.step("broken-first-controlplane")
	m.applyNodes(l, "broken-first-controlplane", cps[0])
	if err := m.gateReady(4 * time.Minute); err == nil {
		t.Fatal("Cilium that cannot reach the API passed the agent gate")
	} else {
		m.record("gate 1 failed as expected: %v", err)
	}
	// Five nodes pulling Cilium's images and restarting its init containers
	// on a 4-CPU runner delayed the API by up to 11 s and pods' checks by up
	// to 4.5 s; an agent that took over a node's network would cut its pods
	// off until they were recreated, for minutes.
	m.healthyWithin("broken-first-controlplane", 30*time.Second)
	m.rollbackTerraform(l, "broken-rollback", cps[:1], nil, false)

	// Production's Cilium, whose agent on the last worker keeps dying once it
	// has started: the other nodes are taken over, that one partly.
	failing := m.workers[len(m.workers)-1]
	l.setCNI(t, lab.Cilium, "")
	m.step("mixed-first-controlplane")
	m.applyNodes(l, "mixed-first-controlplane", cps[0])
	m.eventually("the agent on "+failing+" started", 10*time.Minute, func() bool { return m.agentStarted(failing) })
	stop := m.killAgent(failing)
	err = m.gateReady(4 * time.Minute)
	if err == nil {
		t.Fatalf("the ready gate passed while the agent on %s kept dying", failing)
	}
	m.record("gate 1 failed as expected: %v", err)
	m.record("node taints with the agent failing on %s:\n%s", failing, m.taints())
	m.report("mixed-first-controlplane")
	stop()
	m.rollbackTerraform(l, "mixed-rollback", cps[:1], nil, true)

	// Production's Cilium, abandoned after gate 1 while the API is down: the
	// rollback's apply goes through the first control plane's Talos API, which
	// needs no Kubernetes API, with the other control planes frozen so etcd
	// has no quorum. The rest waits for the API.
	m.step("partial-first-controlplane")
	l.setCNI(t, lab.Cilium, "")
	m.applyNodes(l, "partial-first-controlplane", cps[0])
	must(t, m.gateReady(10*time.Minute))
	m.record("pods on Flannel's network: %d", m.pending())
	m.settle()
	m.report("partial-first-controlplane")
	m.rollbackTerraformAPIDown(l, "partial-rollback", cps)
}

// agentStarted reports whether the node's Cilium agent container runs,
// whatever its readiness: its init containers have set the node up.
func (m *migration) agentStarted(node string) bool {
	output, _ := m.cluster.Kubectl(m.ctx, "", "-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium", "--field-selector", "spec.nodeName="+node, "-o", `jsonpath={.items[0].status.containerStatuses[?(@.name=="cilium-agent")].state.running.startedAt}`)
	return strings.TrimSpace(output) != ""
}

// killAgent kills the node's Cilium agent every second through the node
// shell until the returned stop is called.
func (m *migration) killAgent(node string) (stop func()) {
	m.t.Helper()
	shell := m.kubectl("", "-n", "node-shell", "get", "pod", "-o", "name", "--field-selector", "spec.nodeName="+node)
	ctx, cancel := context.WithCancel(m.ctx)
	done := make(chan struct{})
	kills := 0
	go func() {
		defer close(done)
		for ctx.Err() == nil {
			if _, err := m.cluster.Kubectl(ctx, "", "-n", "node-shell", "exec", shell, "--", "pkill", "-9", "-x", "cilium-agent"); err == nil {
				kills++
			}
			_ = lab.Sleep(ctx, time.Second)
		}
	}()
	m.record("killing the Cilium agent on %s every second", node)
	return func() {
		cancel()
		<-done
		m.record("stopped killing the agent on %s after %d kills", node, kills)
	}
}

// rollbackTerraformAPIDown is rollbackTerraform with its first apply made
// while every control plane but the first is frozen, so the Kubernetes API
// is down, as the runbook's rollback must work then too.
func (m *migration) rollbackTerraformAPIDown(l *terraformLab, prefix string, cps []string) {
	m.t.Helper()
	m.step(prefix + "-api-down")
	// QEMU knows the VMs by the provisioner's names, in the order of their
	// addresses, which is the order of the sorted hostnames.
	vms := []string{}
	for i := range cps[1:] {
		vms = append(vms, fmt.Sprintf("%s-controlplane-%d", m.cluster.Name, i+2))
	}
	for _, vm := range vms {
		must(m.t, m.cluster.Freeze(m.ctx, vm, false))
	}
	m.record("froze %v (%v)", cps[1:], vms)
	resume := func() {
		for _, vm := range vms {
			if err := m.cluster.Freeze(context.Background(), vm, true); err != nil {
				m.t.Error(err)
			}
		}
	}
	defer resume()
	m.eventually("the Kubernetes API is down", 3*time.Minute, func() bool {
		_, err := m.cluster.Kubectl(m.ctx, "", "get", "--raw", "/readyz", "--request-timeout=3s")
		return err != nil
	})
	l.setCNI(m.t, lab.Flannel, "")
	started := time.Now()
	output, err := l.tf.Apply(m.ctx, prefix+"-api-down-"+cps[0], lab.NodeAddress("module.cluster", "controlplane", cps[0]))
	must(m.t, err)
	m.record("terraform apply %s with the API down took %s; changed:%s", cps[0], time.Since(started).Round(time.Second), changedSummary(output))
	resume()
	m.eventually("the Kubernetes API is back", 10*time.Minute, func() bool {
		_, err := m.cluster.Kubectl(m.ctx, "", "get", "--raw", "/readyz", "--request-timeout=3s")
		return err == nil
	})
	m.gateEtcd()
	// The config is applied already; the rest is rollbackTerraform's, whose
	// apply of the same config changes nothing.
	m.rollbackTerraform(l, prefix, nil, nil, true)
}

// rollbackTerraform applies cni = "flannel" to the given nodes, which must be
// every node already switched, control planes first, waits until every
// control plane renders Flannel again and Talos has recreated Flannel and
// kube-proxy, prunes Cilium with upgrade-k8s, then reboots each node with the
// etcd gate, or, without reboot, checks that new pods start without one.
func (m *migration) rollbackTerraform(l *terraformLab, prefix string, cps, workers []string, reboot bool) {
	m.t.Helper()
	l.setCNI(m.t, lab.Flannel, "")
	m.step(prefix + "-config")
	m.applyNodes(l, prefix+"-config", slices.Concat(cps, workers)...)
	m.gateManifests(lab.Flannel)
	m.eventually("Flannel and kube-proxy exist", 5*time.Minute, func() bool {
		return m.exists("daemonset", "kube-system", "kube-flannel") && m.exists("daemonset", "kube-system", "kube-proxy")
	})
	m.kubectl("", "-n", "kube-system", "rollout", "status", "daemonset/kube-flannel", "--timeout=10m")

	m.step(prefix + "-upgrade-k8s")
	m.gateEtcd()
	dry := m.gatedUpgradeK8s(prefix+"-dry-run", "--dry-run")
	if !slices.Contains(dry["Pruned"], "DaemonSet/kube-system/cilium") {
		m.t.Errorf("upgrade-k8s --dry-run would not prune Cilium: %v", dry["Pruned"])
	}
	for _, daemonSet := range flannelDaemonSets {
		if slices.Contains(dry["Pruned"], daemonSet) {
			m.t.Errorf("upgrade-k8s --dry-run would prune %s", daemonSet)
		}
	}
	if changes := m.gatedUpgradeK8s(prefix); !slices.Contains(changes["deleted"], "DaemonSet/kube-system/cilium") {
		m.t.Error("upgrade-k8s did not delete Cilium")
	}
	m.eventually("Cilium agents gone", 5*time.Minute, func() bool {
		uids, _ := m.agents()
		return len(uids) == 0
	})
	// Cilium's operator taints nodes whose agent is not ready
	// (set-cilium-node-taints), and nothing removes the taint once Cilium is
	// gone, so no new pod would be scheduled there.
	taints := m.taints()
	m.record("node taints after pruning Cilium:\n%s", taints)
	for _, line := range strings.Split(taints, "\n") {
		if node, rest, _ := strings.Cut(line, " "); strings.Contains(rest, ciliumTaint) {
			m.kubectl("", "taint", "nodes", node, ciliumTaint+"-")
			m.record("removed Cilium's taint from %s", node)
		}
	}
	if taints := m.taints(); strings.Contains(taints, ciliumTaint) {
		m.t.Errorf("Cilium's taint is still on a node:\n%s", taints)
	}
	m.settle()
	m.report(prefix + "-upgrade-k8s")

	if reboot {
		m.step(prefix + "-reboot")
		for _, node := range m.nodes() {
			if slices.Contains(m.controlPlanes, node) {
				m.gateEtcd()
			}
			started := time.Now()
			m.rebootNode(node)
			m.kubectl("", "wait", "--for=condition=Ready", "node/"+node, "--timeout=10m")
			m.kubectl("", "-n", "kube-system", "rollout", "status", "daemonset/kube-flannel", "--timeout=10m")
			if slices.Contains(m.controlPlanes, node) {
				m.gateEtcd()
			}
			m.record("rebooted %s in %s", node, time.Since(started).Round(time.Second))
		}
		if cleaned := m.removeCiliumCNIConfig(prefix); len(cleaned) > 0 {
			m.record("%s: removed Cilium's CNI config that survived the reboot on %v", prefix, cleaned)
		}
		m.waitWorkloads()
		m.waitReporting()
		m.clean(m.leftovers(prefix+"-after-reboot"), ciliumLeftovers...)
	} else {
		m.step(prefix + "-no-reboot")
		m.leftovers(prefix + "-no-reboot")
		for _, node := range m.workers {
			if !m.newPodStarts("after the rollback, without a reboot", node, 90*time.Second) {
				m.t.Errorf("a new pod on %s does not start after the rollback without a reboot", node)
			}
		}
	}
	m.dataIntact()

	m.step(prefix + "-steady")
	m.settle()
	m.healthy(prefix + "-steady")
	m.refreshTargets()
	_, policed := m.firstPacket()
	m.none(policed, "external", 3)
	m.noChanges(l, "after "+prefix)
}

// removeCiliumCNIConfig removes Cilium's CNI config from every node that
// still has it after its reboot, and restores Flannel's that Cilium renamed.
// A Cilium agent removes its config when it stops cleanly; one that was
// killed leaves it, sorted before Flannel's, so the kubelet keeps calling
// Cilium's plugin, which fails without an agent, and no new pod starts on the
// node. It returns the nodes it cleaned.
func (m *migration) removeCiliumCNIConfig(label string) []string {
	m.t.Helper()
	cleaned := []string{}
	for node, found := range m.leftovers(label + "-rebooted") {
		if !regexp.MustCompile(`cni-configs: .*cilium`).MatchString(found) {
			continue
		}
		shell := m.kubectl("", "-n", "node-shell", "get", "pod", "-o", "name", "--field-selector", "spec.nodeName="+node)
		after := m.kubectl("", "-n", "node-shell", "exec", shell, "--", "sh", "-c", removeCiliumCNI)
		m.record("%s kept Cilium's CNI config after its reboot; now: %s", node, after)
		cleaned = append(cleaned, node)
	}
	slices.Sort(cleaned)
	return cleaned
}

// removeCiliumCNI deletes Cilium's CNI configs on a node and moves back the
// ones Cilium renamed to *.cilium_bak.
const removeCiliumCNI = `cd /host/etc/cni/net.d && for f in *cilium*; do
  case "$f" in
    *.cilium_bak) mv "$f" "${f%.cilium_bak}" ;;
    *) rm -f "$f" ;;
  esac
done; ls | tr '\n' ' '`

// ciliumTaint is the taint Cilium's operator puts on a node whose agent is
// not ready (agent-not-ready-taint-key).
const ciliumTaint = "node.cilium.io/agent-not-ready"

// taints lists every node's taints.
func (m *migration) taints() string {
	m.t.Helper()
	return m.kubectl("", "get", "nodes", "-o", `jsonpath={range .items[*]}{.metadata.name} {.spec.taints}{"\n"}{end}`)
}
