//go:build integration

package talos_test

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

// Objects Talos creates for Flannel, kube-network-policies and kube-proxy.
var flannelDaemonSets = []string{"DaemonSet/kube-system/kube-flannel", "DaemonSet/kube-system/kube-proxy"}

// TestCiliumMigration rehearses moving production from Flannel, its
// kube-network-policies sidecar and kube-proxy to Cilium that Talos owns
// through an inline manifest, and measures each step.
func TestCiliumMigration(t *testing.T) {
	m := newMigration(t, "cilium-migration", start{})

	m.step("worker-config")
	m.patch(m.workers, "patches/cni-none-worker.yaml")
	m.settle()
	if m.exists("daemonset", "kube-system", "cilium") || !m.exists("daemonset", "kube-system", "kube-flannel") {
		t.Error("the workers' config changed the cluster's CNI")
	}
	m.healthy("worker-config")

	m.step("cp-config")
	inline := m.renderCilium("cutover", "")
	m.patchCilium("patches/cni-none-controlplane.yaml", inline)
	m.waitCilium()
	m.record("Cilium ready on every node")
	m.settle()
	// Talos creates the missing Cilium objects as soon as the config has
	// them, and leaves Flannel and kube-proxy running.
	for _, daemonSet := range []string{"kube-flannel", "kube-proxy"} {
		if !m.exists("daemonset", "kube-system", daemonSet) {
			t.Errorf("applying the config removed %s", daemonSet)
		}
	}
	// Once Cilium's agent runs, pods that Flannel networked lose their
	// network: Cilium takes over the node's routes to the pod network. The
	// outage runs to the end of the window, but an agent can take a few
	// seconds after Ready to take the routes over, so of the 20 s settle
	// at least 10 s are down (baseline: under a second).
	if outage := m.window("cp-config")["lb"].Outage; outage < 10*time.Second {
		t.Errorf("the LoadBalancer was down for only %s after Cilium started; expected Flannel's pods to lose their network", outage)
	}
	m.record("pods still on Flannel's network: %d", m.pending())

	m.step("upgrade-k8s")
	dry := m.upgradeK8s("dry-run", "--dry-run")
	for _, daemonSet := range flannelDaemonSets {
		if !slices.Contains(dry["Pruned"], daemonSet) {
			t.Errorf("upgrade-k8s --dry-run would not prune %s", daemonSet)
		}
	}
	applied := m.upgradeK8s("cutover")
	for _, daemonSet := range flannelDaemonSets {
		if !slices.Contains(applied["deleted"], daemonSet) {
			t.Errorf("upgrade-k8s did not delete %s", daemonSet)
		}
	}

	m.step("restart-pods")
	// upgrade-k8s pruned Flannel already, so both of its links go.
	m.removeFlannelLink("cni0")
	m.removeFlannelLink("flannel1")
	m.recreatePods()
	m.waitWorkloads()
	m.waitReporting()
	m.dataIntact()
	// From the control plane's config to the pods' restart, including the
	// 20 seconds the test waits after Cilium is ready.
	m.reportSpan("cp-config", "restart-pods")
	before := m.leftovers("before-reboot")

	m.step("no-reboot")
	m.settle()
	m.healthy("no-reboot")
	m.policyEnforced()
	m.noLeaks("no-reboot")

	m.step("rolling-reboot")
	m.rollingReboot()
	m.waitReporting()
	after := m.leftovers("after-reboot")
	m.clean(after, flannelLeftovers...)
	m.dataIntact()

	m.step("steady")
	m.settle()
	m.healthy("steady")
	m.policyEnforced()
	m.noLeaks("steady")
	m.record("Flannel leftovers before the reboots, kept for comparison: %d nodes", len(before))
}

const monitorAggregation = "scenarios/cilium/monitor-aggregation.yaml"

// TestCiliumUpgrade changes Talos-owned Cilium after bootstrap: first a
// values change, then a patch release, each through the inline manifest and
// `upgrade-k8s`.
func TestCiliumUpgrade(t *testing.T) {
	m := newMigration(t, "cilium-upgrade", start{cilium: true, chart: "cilium-previous"})
	current := ciliumChart(t, "")
	before, images := m.agents()
	m.record("agents before: %v", images)

	m.step("values-config")
	m.replaceCilium(m.renderCilium("values", "cilium-previous", monitorAggregation))
	m.settle()
	if got := m.ciliumConfig("monitor-aggregation"); got != "medium" {
		t.Errorf("applying the config alone changed monitor-aggregation to %q", got)
	}
	m.healthy("values-config")

	m.step("values-upgrade-k8s")
	if dry := m.upgradeK8s("values-dry-run", "--dry-run"); !slices.Contains(dry["configured"], "ConfigMap/kube-system/cilium-config") {
		t.Error("upgrade-k8s --dry-run would not change cilium-config")
	}
	m.upgradeK8s("values")
	m.waitCilium()
	m.waitWorkloads()
	if got := m.ciliumConfig("monitor-aggregation"); got != "maximum" {
		t.Errorf("monitor-aggregation is %q after upgrade-k8s", got)
	}
	// rollOutCiliumPods restarts the agents when their ConfigMap changes.
	after, _ := m.agents()
	for _, uid := range after {
		if slices.Contains(before, uid) {
			t.Errorf("agent %s kept running on the old configuration", uid)
		}
	}
	m.settle()
	m.noLeaks("values-upgrade-k8s")

	m.step("version-config")
	m.replaceCilium(m.renderCilium("version", "", monitorAggregation))
	m.settle()
	m.healthy("version-config")

	m.step("version-upgrade-k8s")
	m.upgradeK8s("version")
	m.waitCilium()
	m.waitWorkloads()
	_, images = m.agents()
	m.record("agents after: %v", images)
	for _, image := range images {
		if !strings.Contains(image, ":v"+chartVersion(current)) {
			t.Errorf("agent runs %s after the upgrade", image)
		}
	}
	m.settle()
	m.noLeaks("version-upgrade-k8s")

	m.step("steady")
	m.settle()
	m.healthy("steady")
	m.policyEnforced()
	m.dataIntact()
}

// chartVersion reads the version from a chart's file name, cilium-<version>.tgz.
func chartVersion(chart string) string {
	return strings.TrimSuffix(strings.TrimPrefix(filepath.Base(chart), "cilium-"), ".tgz")
}

// TestCiliumHelmHandover hands Cilium from Talos's inline manifest to a Flux
// HelmRelease after the cutover, and checks what later `upgrade-k8s` runs do
// to it while the manifest is still in the config, after it is removed with
// and without pruning, and after removing Cilium from Talos's inventory.
func TestCiliumHelmHandover(t *testing.T) {
	m := newMigration(t, "cilium-helm-handover", start{})
	m.cutover()

	m.step("handover")
	setValues := func(files ...string) {
		combined := []string{}
		for _, file := range files {
			data, err := os.ReadFile(file)
			must(t, err)
			combined = append(combined, string(data))
		}
		// Later files override earlier ones key by key in Helm; these files
		// touch disjoint keys, so concatenating them is the same.
		m.kubectl(m.kubectl("", "-n", "kube-system", "create", "configmap", "cilium-values", "--from-literal=values.yaml="+strings.Join(combined, "\n"), "--dry-run=client", "-o", "yaml"), "apply", "-f", "-")
	}
	setValues(m.production.CiliumValues())
	m.kubectl(m.manifest("cilium-helmrelease.yaml", "${CILIUM_VERSION}", chartVersion(ciliumChart(t, ""))), "apply", "-f", "-")
	m.kubectl("", "-n", "kube-system", "wait", "helmrelease/cilium", "--for=condition=Ready", "--timeout=10m")
	m.record("HelmRelease: %s", m.kubectl("", "-n", "kube-system", "get", "helmrelease", "cilium", "-o", `jsonpath={.status.conditions[?(@.type=="Ready")].message}`))
	m.record("cilium DaemonSet managers: %s", m.kubectl("", "-n", "kube-system", "get", "daemonset", "cilium", "--show-managed-fields", "-o", `jsonpath={.metadata.managedFields[*].manager}`))
	m.waitCilium()
	m.settle()
	m.healthy("handover")

	m.step("flux-change")
	setValues(m.production.CiliumValues(), monitorAggregation)
	m.reconcile("kube-system", "cilium")
	m.eventually("Flux set monitor-aggregation", 5*time.Minute, func() bool { return m.ciliumConfig("monitor-aggregation") == "maximum" })
	m.waitCilium()
	m.settle()
	m.noLeaks("flux-change")

	m.step("inline-upgrade-k8s")
	m.upgradeK8s("inline-dry-run", "--dry-run")
	m.upgradeK8s("inline")
	if got := m.ciliumConfig("monitor-aggregation"); got != "medium" {
		t.Errorf("upgrade-k8s left Flux's monitor-aggregation %q while the inline manifest is in the config; expected Talos to revert it", got)
	}
	m.waitCilium()
	m.settle()
	m.noLeaks("inline-upgrade-k8s")

	m.step("flux-restores")
	m.reconcile("kube-system", "cilium")
	m.eventually("Flux restored monitor-aggregation", 5*time.Minute, func() bool { return m.ciliumConfig("monitor-aggregation") == "maximum" })
	m.waitCilium()
	m.settle()

	m.step("remove-inline")
	m.patchCilium("patches/remove-cilium.yaml")
	m.settle()
	if !m.exists("daemonset", "kube-system", "cilium") {
		t.Error("removing the inline manifest from the config deleted Cilium")
	}
	inventory := m.inventory()
	m.record("Cilium objects in Talos's inventory: %d", len(inventory))
	m.healthy("remove-inline")

	m.step("no-prune")
	if changes := m.upgradeK8s("no-prune", "--manifests-no-prune"); len(changes["deleted"]) > 0 {
		t.Errorf("upgrade-k8s --manifests-no-prune deleted %v", changes["deleted"])
	}
	if after := m.inventory(); len(after) != len(inventory) {
		t.Errorf("--manifests-no-prune changed the inventory from %d to %d Cilium objects", len(inventory), len(after))
	}
	m.settle()
	m.healthy("no-prune")

	m.step("prune")
	if dry := m.upgradeK8s("prune-dry-run", "--dry-run"); !slices.Contains(dry["Pruned"], "DaemonSet/kube-system/cilium") {
		t.Error("upgrade-k8s --dry-run would not prune the Cilium DaemonSet")
	}
	pruned := m.upgradeK8s("prune")
	if !slices.Contains(pruned["deleted"], "DaemonSet/kube-system/cilium") {
		t.Fatal("upgrade-k8s did not delete the Cilium DaemonSet")
	}
	m.eventually("Cilium agents gone", 5*time.Minute, func() bool { uids, _ := m.agents(); return len(uids) == 0 })
	m.settle()
	m.report("prune")
	m.newPodStarts("while Cilium is pruned", m.workers[0], 60*time.Second)

	m.step("flux-recreates")
	m.reconcile("kube-system", "cilium")
	m.eventually("Flux recreated the Cilium DaemonSet", 5*time.Minute, func() bool { return m.exists("daemonset", "kube-system", "cilium") })
	m.waitCilium()
	m.waitWorkloads()
	m.waitReporting()
	m.record("Cilium objects in Talos's inventory after the prune: %d", len(m.inventory()))
	if changes := m.upgradeK8s("after-prune"); len(changes["deleted"]) > 0 {
		t.Errorf("upgrade-k8s still deletes %v", changes["deleted"])
	}

	// Talos takes Cilium back when the inline manifest returns; removing its
	// entries from the inventory before the next upgrade-k8s hands it over
	// without a prune.
	m.step("readd-inline")
	m.patchCilium(m.renderCilium("readd", ""))
	m.upgradeK8s("readd")
	m.waitCilium()
	m.eventually("Talos took Cilium back into its inventory", 3*time.Minute, func() bool { return len(m.inventory()) > 0 })
	m.record("Cilium objects in Talos's inventory after re-adding: %d", len(m.inventory()))
	m.reconcile("kube-system", "cilium")
	m.eventually("Flux restored monitor-aggregation", 5*time.Minute, func() bool { return m.ciliumConfig("monitor-aggregation") == "maximum" })
	m.waitCilium()

	m.step("inventory-edit")
	m.patchCilium("patches/remove-cilium.yaml")
	keys := m.inventory()
	remove := []string{}
	for _, key := range keys {
		remove = append(remove, fmt.Sprintf(`{"op":"remove","path":"/data/%s"}`, key))
	}
	m.kubectl("", "-n", "kube-system", "patch", "configmap", "talos-bootstrap-manifests-inventory", "--type=json", "-p", "["+strings.Join(remove, ",")+"]")
	m.record("removed %d Cilium objects from Talos's inventory", len(keys))
	if dry := m.upgradeK8s("inventory-dry-run", "--dry-run"); len(dry["Pruned"]) > 0 {
		t.Errorf("after removing Cilium from the inventory, upgrade-k8s would still prune %v", dry["Pruned"])
	}
	if changes := m.upgradeK8s("inventory"); len(changes["deleted"]) > 0 {
		t.Errorf("after removing Cilium from the inventory, upgrade-k8s deleted %v", changes["deleted"])
		m.reconcile("kube-system", "cilium")
		m.waitCilium()
		m.waitWorkloads()
	}
	m.settle()
	m.healthy("inventory-edit")

	m.step("steady")
	m.settle()
	m.healthy("steady")
	m.policyEnforced()
	m.dataIntact()
}

// newPodStarts records whether a fresh pod on node gets a network within timeout.
func (m *migration) newPodStarts(label, node string, timeout time.Duration) bool {
	m.t.Helper()
	name := fmt.Sprintf("start-%d", time.Now().UnixNano()%1_000_000)
	p := lab.Probe{Name: name, Namespace: "mig-control", Node: node, Image: m.image, Offsets: []int{0}, Targets: []lab.Target{{Name: "external", Host: externalIP, Port: 80}}}
	manifest, err := p.Manifest()
	must(m.t, err)
	m.kubectl(manifest, "create", "-f", "-")
	_, err = m.cluster.Kubectl(m.ctx, "", "-n", "mig-control", "wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/"+name, "--timeout="+timeout.String())
	events, _ := m.cluster.Kubectl(m.ctx, "", "-n", "mig-control", "get", "events", "--field-selector", "involvedObject.name="+name, "-o", `jsonpath={range .items[*]}{.reason}: {.message}{"\n"}{end}`)
	m.record("new pod on %s %s: started=%t\n%s", node, label, err == nil, strings.TrimSpace(events))
	m.kubectl("", "-n", "mig-control", "delete", "pod", name, "--wait=false")
	return err == nil
}

// TestCiliumL2 measures LoadBalancer failover after the cutover, first with
// MetalLB's L2 mode, then with Cilium's LB IPAM and L2 announcements, on a
// graceful reboot and on a frozen VM.
func TestCiliumL2(t *testing.T) {
	m := newMigration(t, "cilium-l2", start{})
	m.cutover()
	failover := func(prefix string) {
		m.step(prefix + "-reboot")
		m.reboot(m.holder())
		m.waitReporting()
		m.report(prefix + "-reboot")
		m.holder()

		m.step(prefix + "-freeze")
		m.freeze(m.holder(), 60*time.Second)
		m.waitReporting()
		m.report(prefix + "-freeze")
		m.holder()
		m.dataIntact()
	}

	m.step("metallb")
	m.settle()
	m.healthy("metallb")
	failover("metallb")

	m.step("cilium-l2-config")
	m.replaceCilium(m.renderCilium("l2", "", "scenarios/cilium-l2/values.yaml"))
	m.upgradeK8s("l2")
	m.waitCilium()
	m.waitWorkloads()
	m.settle()
	m.healthy("cilium-l2-config")

	m.step("switch")
	before := *m.lb.Load()
	m.kubectl("", "-n", "metallb-system", "delete", "helmrelease", "metallb", "--timeout=5m")
	m.eventually("MetalLB uninstalled", 5*time.Minute, func() bool { return !m.exists("daemonset", "metallb-system", "metallb-speaker") })
	start, stop, _ := strings.Cut(labPool, "-")
	m.kubectl(m.manifest("cilium-l2.yaml", "${POOL_START}", start, "${POOL_STOP}", stop), "apply", "-f", "-")
	m.eventually("Cilium assigned an address", 5*time.Minute, func() bool {
		ip, _ := m.cluster.Kubectl(m.ctx, "", "-n", "mig-app", "get", "service", "web", "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}")
		return ip != ""
	})
	m.setLB()
	if after := *m.lb.Load(); after != before {
		m.record("the Service's address changed from %s to %s", before, after)
	}
	m.waitReporting()
	m.report("switch")
	failover("cilium-l2")

	m.step("steady")
	m.settle()
	m.healthy("steady")
}

// TestCiliumRollback rolls back to Flannel, kube-network-policies and
// kube-proxy twice: from the middle of the cutover, after upgrade-k8s but
// before any pod moved, and after the whole cutover.
func TestCiliumRollback(t *testing.T) {
	m := newMigration(t, "cilium-rollback", start{})

	m.step("partial-cutover")
	m.patch(m.workers, "patches/cni-none-worker.yaml")
	m.patchCilium("patches/cni-none-controlplane.yaml", m.renderCilium("cutover", ""))
	m.waitCilium()
	m.upgradeK8s("cutover")
	m.record("pods still on Flannel's network: %d", m.pending())
	m.rollback("mid-migration", true)

	m.cutover()
	m.step("migrated")
	m.settle()
	m.healthy("migrated")
	m.rollback("completed", false)
}

// rollback restores production's config, prunes Cilium with upgrade-k8s and
// reboots every node. With tryRestart, it first restarts the pods without
// rebooting to see whether that is enough.
func (m *migration) rollback(label string, tryRestart bool) {
	m.t.Helper()
	m.step(label + "-config")
	m.patch(m.workers, "patches/flannel-worker.yaml")
	m.patchCilium("patches/flannel-controlplane.yaml", "patches/remove-cilium.yaml")
	m.eventually("Talos recreated Flannel and kube-proxy", 5*time.Minute, func() bool {
		return m.exists("daemonset", "kube-system", "kube-flannel") && m.exists("daemonset", "kube-system", "kube-proxy")
	})

	m.step(label + "-upgrade-k8s")
	if changes := m.upgradeK8s(label); !slices.Contains(changes["deleted"], "DaemonSet/kube-system/cilium") {
		m.t.Error("upgrade-k8s did not prune Cilium")
	}
	m.eventually("Cilium agents gone", 5*time.Minute, func() bool { uids, _ := m.agents(); return len(uids) == 0 })
	m.kubectl("", "-n", "kube-system", "rollout", "status", "daemonset/kube-flannel", "--timeout=5m")
	m.settle()
	m.report(label + "-upgrade-k8s")

	if tryRestart {
		m.step(label + "-restart-pods")
		m.leftovers(label + "-before-reboot")
		started := m.newPodStarts("after the rollback, before a reboot", m.workers[0], 90*time.Second)
		m.record("a new pod starts before the reboots: %t", started)
		m.report(label + "-restart-pods")
	}

	m.step(label + "-reboot")
	m.rebootEach("kube-flannel")
	m.waitReporting()
	m.clean(m.leftovers(label+"-after-reboot"), ciliumLeftovers...)
	m.dataIntact()

	m.step(label + "-steady")
	m.settle()
	m.report(label + "-steady")
	for _, signal := range m.allowed(m.window(label + "-steady")) {
		if outage := m.window(label + "-steady")[signal].Outage; outage > 3*time.Second {
			m.t.Errorf("%s after the rollback: %s down for %s", label, signal, outage)
		}
	}
	// kube-network-policies enforces again, with ADR 4's window for new pods.
	m.refreshTargets()
	_, policed := m.firstPacket()
	m.none(policed, "external", 3)
}

// TestCiliumFailures checks the cutover with a worker rebooting in the
// middle, then what happens to traffic and policy while a node's Cilium
// agent is removed or keeps being killed.
func TestCiliumFailures(t *testing.T) {
	m := newMigration(t, "cilium-failures", start{})
	rebooting := m.workers[1]

	m.step("cutover-with-reboot")
	m.patch(m.workers, "patches/cni-none-worker.yaml")
	m.patchCilium("patches/cni-none-controlplane.yaml", m.renderCilium("cutover", ""))
	// The worker goes down while Talos creates Cilium and upgrade-k8s runs.
	m.talos("-n", m.ips[rebooting], "reboot", "--wait=false")
	m.record("reboot of %s requested", rebooting)
	if _, err := m.tryUpgradeK8s("cutover"); err != nil {
		m.record("upgrade-k8s failed while %s rebooted: %v", rebooting, err)
		m.kubectl("", "wait", "--for=condition=Ready", "node/"+rebooting, "--timeout=10m")
		m.upgradeK8s("cutover-retry")
	}
	m.kubectl("", "wait", "--for=condition=Ready", "node/"+rebooting, "--timeout=10m")
	m.waitCilium()
	m.recreatePods()
	m.waitWorkloads()
	m.waitReporting()
	m.dataIntact()
	m.step("converged")
	m.settle()
	m.healthy("converged")

	node := m.workers[0]
	m.step("agent-removed")
	m.kubectl("", "-n", "kube-system", "patch", "daemonset", "cilium", "--type=merge", "-p",
		`{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"NotIn","values":["`+node+`"]}]}]}}}}}}}`)
	m.eventually("agent gone from "+node, 5*time.Minute, func() bool {
		output := m.kubectl("", "-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium", "--field-selector", "spec.nodeName="+node, "-o", "name")
		return output == ""
	})
	m.settle()
	m.settle()
	m.report("agent-removed")
	m.noLeaks("agent-removed")
	m.newPodStarts("without its agent", node, 60*time.Second)

	m.step("agent-restored")
	// Talos applies its manifests server-side, so upgrade-k8s leaves fields
	// that another manager added, such as this affinity, in place.
	m.upgradeK8s("restore")
	agent := func() bool {
		return m.kubectl("", "-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium", "--field-selector", "spec.nodeName="+node, "-o", "name") != ""
	}
	must(t, lab.Sleep(m.ctx, 30*time.Second))
	m.record("agent back on %s after upgrade-k8s: %t", node, agent())
	m.kubectl("", "-n", "kube-system", "patch", "daemonset", "cilium", "--type=json", "-p", `[{"op":"remove","path":"/spec/template/spec/affinity/nodeAffinity"}]`)
	m.eventually("agent back on "+node, 5*time.Minute, agent)
	m.waitCilium()
	m.waitWorkloads()
	m.waitReporting()

	m.step("agent-killed")
	shell := m.kubectl("", "-n", "node-shell", "get", "pod", "-o", "name", "--field-selector", "spec.nodeName="+node)
	m.kubectl("", "-n", "node-shell", "exec", shell, "--", "sh", "-c", "for i in $(seq 60); do pkill -9 -x cilium-agent; sleep 1; done")
	m.report("agent-killed")
	m.noLeaks("agent-killed")
	m.record("agent on %s restarted %s times", node, m.kubectl("", "-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium", "--field-selector", "spec.nodeName="+node, "-o", "jsonpath={.items[0].status.containerStatuses[0].restartCount}"))

	m.step("agent-recovers")
	// The kubelet backs off restarting the agent; until it runs, no pod on the
	// node gets a network.
	m.eventually("a new pod starts on "+node, 10*time.Minute, func() bool {
		return m.newPodStarts("after the agent was killed", node, 30*time.Second)
	})
	m.waitCilium()
	m.waitWorkloads()
	m.waitReporting()
	m.settle()
	m.healthy("agent-recovers")
	m.policyEnforced()
}

// TestNetpolFRR runs production's stack with MetalLB's FRR mode, which ADR 2
// blames for dropped traffic from policed pods, and asserts that drop; then
// it moves the cluster to Cilium with FRR still running and asserts that the
// drop is gone.
func TestNetpolFRR(t *testing.T) {
	m := newMigration(t, "netpol-frr", start{metallb: `{"spec":{"values":{"speaker":{"frr":{"enabled":true}}}}}`, drops: true})
	m.frrSockets()

	// The policed probers report to the host through allowed egress that
	// leaves the node, so ADR 2's drop silences them.
	m.step("flannel-frr")
	m.settle()
	m.settle()
	m.settle()
	m.report("flannel-frr")
	for signal, stat := range m.window("flannel-frr") {
		if strings.HasPrefix(signal, "mig-policed/") && stat.OK > 0 {
			t.Errorf("%s reported %d times; ADR 2's drop did not happen, so update ADR 2 and this scenario", signal, stat.OK)
		}
	}
	m.refreshTargets()
	allowed := m.probe("frr-allowed", "np-allow", firstPacketRuns/2, firstPacket, "external", "pod")
	m.probe("frr-denied", "np-policed", 3, firstPacket, "external", "pod")
	// Allowed connections pass only in ADR 4's window, before the policy applies.
	m.none(allowed, "external", 3)
	m.none(allowed, "pod", 3)

	m.cutover()
	m.frrSockets()
	m.step("cilium-frr")
	m.settle()
	m.healthy("cilium-frr")
	m.refreshTargets()
	allowed = m.probe("cilium-frr-allowed", "np-allow", firstPacketRuns/2, firstPacket, "external", "pod")
	denied := m.probe("cilium-frr-denied", "np-policed", 3, firstPacket, "external", "pod")
	m.all(allowed, "external", firstPacket...)
	m.all(allowed, "pod", firstPacket...)
	m.none(denied, "external", firstPacket...)
	m.all(denied, "pod", firstPacket...)
}

// frrSockets records the workers' packet sockets and FRR daemons, and fails
// unless FRR holds a node-wide packet socket.
func (m *migration) frrSockets() {
	m.t.Helper()
	sockets := 0
	for _, node := range m.workers {
		table := m.talos("-n", m.ips[node], "read", "/proc/net/packet")
		sockets += lab.NodeWidePacketSockets(table)
		m.record("%s /proc/net/packet with MetalLB FRR:\n%s", node, table)
	}
	shell := m.kubectl("", "-n", "node-shell", "get", "pod", "-o", "name", "--field-selector", "spec.nodeName="+m.workers[0])
	m.record("FRR daemons on %s:\n%s", m.workers[0], m.kubectl("", "-n", "node-shell", "exec", shell, "--", "sh", "-c", "ps -eo pid,args | grep -E 'bfdd|bgpd|zebra|watchfrr' | grep -v grep || true"))
	if sockets == 0 {
		m.t.Fatal("MetalLB's FRR mode opened no node-wide packet socket on the workers")
	}
}
