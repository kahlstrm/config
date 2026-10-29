//go:build integration

package talos_test

import (
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

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
	controlPlanes int
	tf            lab.Terraform
	vars          map[string]any
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

// setCNI changes the cni variable for the next applies.
func (l *terraformLab) setCNI(t *testing.T, cni string) {
	l.vars["cni"] = cni
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
		summary := ""
		for _, match := range changed {
			summary += " " + match[1]
		}
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

var updated = regexp.MustCompile(`(?m)^\s*# (\S+) will be (?:updated in-place|created|destroyed|replaced)`)

// daemonSets lists kube-system's DaemonSets.
func (m *migration) daemonSets() string {
	output, _ := m.cluster.Kubectl(m.ctx, "", "-n", "kube-system", "get", "daemonsets", "-o", "jsonpath={.items[*].metadata.name}")
	return strings.TrimSpace(output)
}

// TestCiliumTerraform provisions a cluster through production's
// talos-cluster module with cni = "flannel", switches it to Cilium by
// changing cni and applying each node with Terraform, completes the cutover
// as cilium-migration measured it, then rolls back the same way.
func TestCiliumTerraform(t *testing.T) {
	// One by default: three need about 15 GiB of RAM and 12 GiB of disk.
	controlPlanes := 1
	if value := os.Getenv("TALOS_LAB_CONTROL_PLANES"); value != "" {
		_, err := fmt.Sscan(value, &controlPlanes)
		must(t, err)
	}
	l := &terraformLab{controlPlanes: controlPlanes}
	m := newMigration(t, "cilium-terraform", start{terraform: l})
	m.record("nodes: control planes %v, workers %v", m.controlPlanes, m.workers)
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
	if changes, plan, err := l.tf.Changes(m.ctx); err != nil || changes {
		t.Errorf("plan after creating the cluster has changes (%v):\n%s", err, plan)
	}

	// The cutover: each control plane, then each worker; targeting a worker
	// first would apply every control plane with it (see applyNodes). Talos
	// installs Cilium from the first control plane's config.
	l.setCNI(t, lab.Cilium)
	m.step("tf-controlplanes")
	m.applyNodes(l, "tf-controlplanes", cps...)
	m.waitCilium()
	m.record("Cilium ready on every node")

	m.step("tf-workers")
	m.applyNodes(l, "tf-workers", workers...)
	for _, daemonSet := range []string{"kube-flannel", "kube-proxy"} {
		if !m.exists("daemonset", "kube-system", daemonSet) {
			t.Errorf("applying the config removed %s", daemonSet)
		}
	}
	m.record("pods still on Flannel's network: %d", len(m.unmanaged()))

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
	m.restartUnmanaged()
	m.waitWorkloads()
	m.waitReporting()
	m.dataIntact()
	if left := m.unmanaged(); len(left) > 0 {
		t.Errorf("pods still without a CiliumEndpoint: %v", left)
	}
	m.reportSpan("tf-controlplanes", "restart-pods")

	m.step("rolling-reboot")
	m.rollingReboot()
	m.waitReporting()
	m.clean(m.leftovers("after-reboot"), flannelLeftovers...)
	m.dataIntact()

	m.step("cilium-steady")
	m.settle()
	m.healthy("cilium-steady")
	m.policyEnforced()
	if changes, plan, err := l.tf.Changes(m.ctx); err != nil || changes {
		t.Errorf("plan after the cutover has changes (%v):\n%s", err, plan)
	}

	// The rollback: the same applies with cni = "flannel".
	l.setCNI(t, lab.Flannel)
	m.step("rollback-tf-controlplanes")
	m.applyNodes(l, "rollback-tf-controlplanes", cps...)
	m.step("rollback-tf-workers")
	m.applyNodes(l, "rollback-tf-workers", workers...)
	m.eventually("Talos recreated Flannel and kube-proxy", 5*time.Minute, func() bool {
		return m.exists("daemonset", "kube-system", "kube-flannel") && m.exists("daemonset", "kube-system", "kube-proxy")
	})
	m.kubectl("", "-n", "kube-system", "rollout", "status", "daemonset/kube-flannel", "--timeout=10m")
	m.settle()

	m.step("rollback-upgrade-k8s")
	m.upgradeK8s("rollback-dry-run", "--dry-run")
	if changes := m.upgradeK8s("rollback"); !slices.Contains(changes["deleted"], "DaemonSet/kube-system/cilium") {
		t.Error("upgrade-k8s did not delete Cilium")
	}
	m.eventually("Cilium agents gone", 5*time.Minute, func() bool {
		uids, _ := m.agents()
		return len(uids) == 0
	})
	m.settle()

	m.step("rollback-reboot")
	m.rebootEach("kube-flannel")
	m.waitReporting()
	m.clean(m.leftovers("after-rollback"), ciliumLeftovers...)
	m.dataIntact()

	m.step("rollback-steady")
	m.settle()
	m.healthy("rollback-steady")
	m.refreshTargets()
	_, policed = m.firstPacket()
	m.none(policed, "external", 3)
	if changes, plan, err := l.tf.Changes(m.ctx); err != nil || changes {
		t.Errorf("plan after the rollback has changes (%v):\n%s", err, plan)
	}
}
