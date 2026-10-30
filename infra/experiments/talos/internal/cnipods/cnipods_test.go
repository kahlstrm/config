package cnipods

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	agentReady = time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	before     = agentReady.Add(-time.Hour)
	after      = agentReady.Add(time.Minute)
)

type podSpec struct {
	namespace, name, node, phase string
	owner                        [2]string // kind, name
	sandbox                      time.Time
	hostNetwork, mirror, deleted bool
	ip                           string
	labels                       map[string]string
	ready                        bool
}

func (p podSpec) object() map[string]any {
	meta := map[string]any{"namespace": p.namespace, "name": p.name, "uid": "uid-" + p.name, "labels": p.labels}
	if p.owner[0] != "" {
		meta["ownerReferences"] = []any{map[string]any{"kind": p.owner[0], "name": p.owner[1], "uid": "uid-" + p.owner[1], "controller": true}}
	}
	if p.mirror {
		meta["annotations"] = map[string]string{"kubernetes.io/config.mirror": "hash"}
	}
	if p.deleted {
		meta["deletionTimestamp"] = after
	}
	conditions := []any{}
	if !p.sandbox.IsZero() {
		conditions = append(conditions, map[string]any{"type": "PodReadyToStartContainers", "status": "True", "lastTransitionTime": p.sandbox})
	}
	if p.ready {
		conditions = append(conditions, map[string]any{"type": "Ready", "status": "True", "lastTransitionTime": agentReady})
	}
	return map[string]any{
		"metadata": meta,
		"spec":     map[string]any{"nodeName": p.node, "hostNetwork": p.hostNetwork},
		"status":   map[string]any{"phase": cmpOr(p.phase, "Running"), "podIP": p.ip, "conditions": conditions},
	}
}

func cmpOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func list(items ...any) string {
	data, _ := json.Marshal(map[string]any{"items": items})
	return string(data)
}

// cluster is production's mix of owners, after Cilium became ready on w1
// and w2 but not on w3.
func cluster() []podSpec {
	agent := map[string]string{"k8s-app": "cilium"}
	return []podSpec{
		{namespace: "kube-system", name: "cilium-a", node: "w1", owner: [2]string{"DaemonSet", "cilium"}, sandbox: before, hostNetwork: true, labels: agent, ready: true},
		{namespace: "kube-system", name: "cilium-b", node: "w2", owner: [2]string{"DaemonSet", "cilium"}, sandbox: before, hostNetwork: true, labels: agent, ready: true},
		{namespace: "kube-system", name: "cilium-c", node: "w3", owner: [2]string{"DaemonSet", "cilium"}, sandbox: before, hostNetwork: true, labels: agent},
		{namespace: "kube-system", name: "kube-apiserver-c1", node: "w1", owner: [2]string{"Node", "w1"}, sandbox: before, hostNetwork: true, mirror: true},
		{namespace: "lab", name: "static-w2", node: "w2", owner: [2]string{"Node", "w2"}, sandbox: before, mirror: true},
		{namespace: "traefik", name: "traefik-abc", node: "w1", owner: [2]string{"ReplicaSet", "traefik-rs"}, sandbox: before},
		{namespace: "alloy", name: "alloy-x", node: "w2", owner: [2]string{"DaemonSet", "alloy"}, sandbox: before},
		{namespace: "harbor", name: "harbor-database-0", node: "w1", owner: [2]string{"StatefulSet", "harbor-database"}, sandbox: before},
		{namespace: "loki", name: "loki-2", node: "w2", owner: [2]string{"StatefulSet", "loki"}, sandbox: before},
		{namespace: "loki", name: "loki-10", node: "w2", owner: [2]string{"StatefulSet", "loki"}, sandbox: before},
		{namespace: "kube-system", name: "descheduler-1", node: "w2", owner: [2]string{"Job", "descheduler-1"}, sandbox: before},
		{namespace: "pocket-id", name: "pocket-id-sync-1", node: "w2", owner: [2]string{"Job", "pocket-id-sync"}, sandbox: before, phase: "Succeeded"},
		{namespace: "default", name: "standalone", node: "w2", sandbox: before},
		{namespace: "kubevirt", name: "virt-launcher-vm", node: "w1", owner: [2]string{"VirtualMachineInstance", "vm"}, sandbox: before},
		{namespace: "web", name: "terminating", node: "w1", owner: [2]string{"ReplicaSet", "web-rs"}, sandbox: before, deleted: true},
		{namespace: "web", name: "starting", node: "w1", owner: [2]string{"ReplicaSet", "web-rs"}, phase: "Pending"},
		{namespace: "web", name: "on-cilium", node: "w1", owner: [2]string{"ReplicaSet", "web-rs"}, sandbox: after, ip: "10.244.1.7"},
		{namespace: "web", name: "on-gateway", node: "w2", owner: [2]string{"ReplicaSet", "web-rs"}, sandbox: after, ip: "10.244.5.1"},
		{namespace: "web", name: "on-w3", node: "w3", owner: [2]string{"ReplicaSet", "web-rs"}, sandbox: before},
	}
}

// fake answers kubectl with the given pods and records every other command.
type fake struct {
	mu        sync.Mutex
	pods      []podSpec
	endpoints []string // namespace/name; nil means forbidden
	commands  []string
	// replaced records deleted pods; a later get returns a new UID, Ready.
	replaced map[string]bool
}

// rawDelete reads `delete --raw /api/v1/namespaces/NS/pods/NAME -f FILE` and
// returns the pod's namespace/name and the UID precondition in FILE.
func rawDelete(t testing.TB, args []string) (string, string) {
	t.Helper()
	parts := strings.Split(args[2], "/")
	data, err := os.ReadFile(args[4])
	if err != nil {
		t.Fatal(err)
	}
	var options struct{ Preconditions struct{ UID string } }
	if err := json.Unmarshal(data, &options); err != nil {
		t.Fatal(err)
	}
	return parts[4] + "/" + parts[6], options.Preconditions.UID
}

func (f *fake) kubectl(t testing.TB) Kubectl {
	return func(_ context.Context, args ...string) (string, error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		command := strings.Join(args, " ")
		switch {
		case command == "get pods -A -o json":
			items := []any{}
			for _, p := range f.pods {
				items = append(items, p.object())
			}
			return list(items...), nil
		case command == "get nodes -o json":
			return list(
				map[string]any{"metadata": map[string]any{"name": "w1"}, "status": map[string]any{"addresses": []any{map[string]any{"type": "InternalIP", "address": "10.10.10.21"}}}},
				map[string]any{"metadata": map[string]any{"name": "w2"}, "status": map[string]any{"addresses": []any{map[string]any{"type": "InternalIP", "address": "10.10.10.22"}}}},
			), nil
		case command == "get replicasets,jobs -A -o json":
			return list(
				map[string]any{"kind": "ReplicaSet", "metadata": map[string]any{"uid": "uid-traefik-rs", "ownerReferences": []any{map[string]any{"kind": "Deployment", "name": "traefik", "uid": "uid-traefik", "controller": true}}}},
				map[string]any{"kind": "ReplicaSet", "metadata": map[string]any{"uid": "uid-web-rs", "ownerReferences": []any{map[string]any{"kind": "Deployment", "name": "web", "uid": "uid-web", "controller": true}}}},
				map[string]any{"kind": "Job", "metadata": map[string]any{"uid": "uid-descheduler-1", "ownerReferences": []any{map[string]any{"kind": "CronJob", "name": "descheduler", "uid": "uid-descheduler", "controller": true}}}},
			), nil
		case strings.HasPrefix(command, "get ciliumendpoints.cilium.io"):
			if f.endpoints == nil {
				return "", errors.New("forbidden")
			}
			items := []any{}
			for _, key := range f.endpoints {
				namespace, name, _ := strings.Cut(key, "/")
				items = append(items, map[string]any{"metadata": map[string]any{"namespace": namespace, "name": name}})
			}
			return list(items...), nil
		}
		f.commands = append(f.commands, command)
		switch {
		case len(args) > 4 && args[2] == "get" && args[3] == "pod":
			if f.replaced[args[1]+"/"+args[4]] {
				return "uid-new w1 10.244.1.77 True", nil
			}
			return "uid-" + args[4] + " w1 10.244.1.5", nil
		case len(args) > 4 && args[2] == "get" && (args[3] == "deployment" || args[3] == "daemonset"):
			return "1 1", nil
		case len(args) == 5 && args[0] == "delete" && args[1] == "--raw":
			key, uid := rawDelete(t, args)
			_, name, _ := strings.Cut(key, "/")
			if f.replaced[key] || uid != "uid-"+name {
				return "", errors.New(`Error from server (Conflict): Precondition failed: UID in precondition`)
			}
			f.replaced[key] = true
		}
		return "", nil
	}
}

// cni0 reports a residual cni0 bridge on the named nodes, with each one's
// podCIDR's first address.
func cni0(nodes ...string) CNI0 {
	addresses := map[string]string{"w1": "10.244.1.1", "w2": "10.244.5.1"}
	return func(_ context.Context, ips map[string]string) (map[string]string, error) {
		found := map[string]string{}
		for _, node := range nodes {
			if ips[node] == "" {
				return nil, fmt.Errorf("no address for %s", node)
			}
			found[node] = addresses[node]
		}
		return found, nil
	}
}

func gather(t *testing.T, f *fake, bridges CNI0) Plan {
	t.Helper()
	inv, err := Gather(t.Context(), f.kubectl(t), bridges)
	if err != nil {
		t.Fatal(err)
	}
	inv.Taken = after.Add(time.Hour)
	return Classify(inv)
}

func actions(plan Plan) map[string]string {
	found := map[string]string{}
	for _, c := range plan.Candidates {
		found[c.Key()] = fmt.Sprintf("%s %s", c.Action, c.Owner)
	}
	return found
}

func TestClassifyFollowsOwnersAndSkipsWhatItMustNotTouch(t *testing.T) {
	plan := gather(t, &fake{pods: cluster()}, cni0("w2"))
	want := map[string]string{
		"traefik/traefik-abc":       "delete Deployment/traefik",
		"alloy/alloy-x":             "delete DaemonSet/alloy",
		"harbor/harbor-database-0":  "one-at-a-time StatefulSet/harbor-database",
		"loki/loki-2":               "one-at-a-time StatefulSet/loki",
		"loki/loki-10":              "one-at-a-time StatefulSet/loki",
		"kube-system/descheduler-1": "report CronJob/descheduler",
		"default/standalone":        "report none",
		"kubevirt/virt-launcher-vm": "report VirtualMachineInstance/vm",
		"web/on-gateway":            "delete Deployment/web",
	}
	got := actions(plan)
	for key, action := range want {
		if got[key] != action {
			t.Errorf("%s: got %q, want %q", key, got[key], action)
		}
	}
	if len(got) != len(want) {
		t.Errorf("candidates %v, want %v", got, want)
	}
	reasons := map[string]string{}
	for _, s := range plan.Skipped {
		reasons[s.Key()] = s.Reason
	}
	for key, reason := range map[string]string{
		"kube-system/cilium-a":          "host network",
		"kube-system/kube-apiserver-c1": "host network",
		"lab/static-w2":                 "static pod",
		"pocket-id/pocket-id-sync-1":    "finished",
		"web/terminating":               "terminating",
		"web/starting":                  "no sandbox yet",
		"web/on-cilium":                 "sandbox newer than its node's Cilium agent",
		"web/on-w3":                     "no Ready Cilium agent on its node",
	} {
		if reasons[key] != reason {
			t.Errorf("%s skipped for %q, want %q", key, reasons[key], reason)
		}
	}
	if !slices.Equal(plan.Blocked, []string{"w3"}) {
		t.Errorf("blocked nodes %v, want [w3]", plan.Blocked)
	}
}

func TestTheGatewayExceptionEndsWithTheBridge(t *testing.T) {
	// w2 rebooted, so its cni0 is gone; a pod on the podCIDR's first address
	// is then healthy, CiliumEndpoint or not.
	for _, endpoints := range [][]string{nil, {"web/on-gateway", "web/on-cilium"}} {
		plan := gather(t, &fake{pods: cluster(), endpoints: endpoints}, cni0("w1"))
		if slices.Contains(plan.Keys(), "web/on-gateway") {
			t.Errorf("with w2's cni0 gone (endpoints %v), web/on-gateway is a candidate", endpoints)
		}
	}
}

func TestEndpointsAgreeWithSandboxAges(t *testing.T) {
	pods := cluster()
	endpoints := []string{"web/on-cilium", "web/on-gateway"}
	sandboxes := gather(t, &fake{pods: pods}, nil)
	withEndpoints := gather(t, &fake{pods: pods, endpoints: endpoints}, nil)
	if withEndpoints.Signal == sandboxes.Signal {
		t.Fatalf("both plans used %q", sandboxes.Signal)
	}
	if !slices.Equal(withEndpoints.Keys(), sandboxes.Keys()) {
		t.Errorf("CiliumEndpoints found %v, sandbox ages %v", withEndpoints.Keys(), sandboxes.Keys())
	}
}

func TestPodsJustStartedOnCiliumAreRecheckedNotRecreated(t *testing.T) {
	pods := []podSpec{
		{namespace: "kube-system", name: "cilium-a", node: "w1", sandbox: before, hostNetwork: true, labels: map[string]string{"k8s-app": "cilium"}, ready: true},
		{namespace: "web", name: "new", node: "w1", owner: [2]string{"ReplicaSet", "web-rs"}, sandbox: after},
	}
	f := &fake{pods: pods, endpoints: []string{}}
	inv, err := Gather(t.Context(), f.kubectl(t), nil)
	if err != nil {
		t.Fatal(err)
	}
	inv.Taken = after.Add(Grace / 2)
	if plan := Classify(inv); len(plan.Candidates) != 0 {
		t.Errorf("a pod without its CiliumEndpoint yet is a candidate: %v", plan.Keys())
	}
	inv.Taken = after.Add(2 * Grace)
	if plan := Classify(inv); !slices.Equal(plan.Keys(), []string{"web/new"}) {
		t.Errorf("a pod still without a CiliumEndpoint after the grace is not a candidate: %v", plan.Keys())
	}
}

func TestRecreateRefusesWhileANodeHasNoAgent(t *testing.T) {
	f := &fake{pods: cluster(), endpoints: []string{}, replaced: map[string]bool{}}
	err := Recreate(t.Context(), f.kubectl(t), gather(t, f, nil), Options{Timeout: time.Second})
	if err == nil || !strings.Contains(err.Error(), "w3") {
		t.Fatalf("got %v, want a refusal naming w3", err)
	}
	if len(f.commands) != 0 {
		t.Errorf("ran %v", f.commands)
	}
}

func TestRecreateRefusesWithoutEndpointAccess(t *testing.T) {
	pods := slices.DeleteFunc(cluster(), func(p podSpec) bool { return p.node == "w3" })
	f := &fake{pods: pods, replaced: map[string]bool{}}
	err := Recreate(t.Context(), f.kubectl(t), gather(t, f, nil), Options{Timeout: time.Second})
	if err == nil || !strings.Contains(err.Error(), "CiliumEndpoints") {
		t.Fatalf("got %v, want a refusal without CiliumEndpoint access", err)
	}
	if len(f.commands) != 0 {
		t.Errorf("ran %v", f.commands)
	}
}

func deletes(commands []string) []string {
	found := []string{}
	for _, command := range commands {
		if fields := strings.Fields(command); len(fields) == 5 && fields[0] == "delete" && fields[1] == "--raw" {
			parts := strings.Split(fields[2], "/")
			found = append(found, parts[4]+"/"+parts[6])
		}
	}
	return found
}

func TestRecreateDeletesByOwnerAndWaitsForEachStatefulSetPod(t *testing.T) {
	pods := slices.DeleteFunc(cluster(), func(p podSpec) bool { return p.node == "w3" })
	f := &fake{pods: pods, endpoints: []string{"web/on-cilium", "web/on-gateway"}, replaced: map[string]bool{}}
	var log strings.Builder
	if err := Recreate(t.Context(), f.kubectl(t), gather(t, f, cni0("w2")), Options{Timeout: time.Second, Include: []string{"default/standalone"}, Log: &log}); err != nil {
		t.Fatal(err)
	}
	deleted := deletes(f.commands)
	// Deployments, DaemonSets and the included pod first, then the
	// StatefulSets side by side, each highest ordinal first.
	first := []string{"alloy/alloy-x", "traefik/traefik-abc", "web/on-gateway", "default/standalone"}
	if len(deleted) != 7 || !slices.Equal(deleted[:4], first) {
		t.Fatalf("deleted %v, want %v first", deleted, first)
	}
	if rest := slices.Sorted(slices.Values(deleted[4:])); !slices.Equal(rest, []string{"harbor/harbor-database-0", "loki/loki-10", "loki/loki-2"}) {
		t.Errorf("deleted %v after the others", deleted[4:])
	}
	if slices.Index(deleted, "loki/loki-10") > slices.Index(deleted, "loki/loki-2") {
		t.Errorf("deleted loki-2 before loki-10: %v", deleted)
	}
	for _, untouched := range []string{"descheduler-1", "virt-launcher-vm", "pocket-id-sync-1"} {
		if strings.Contains(strings.Join(deleted, " "), untouched) {
			t.Errorf("deleted %s", untouched)
		}
		if untouched != "pocket-id-sync-1" && !strings.Contains(log.String(), untouched) {
			t.Errorf("did not report %s:\n%s", untouched, log.String())
		}
	}
	// loki-2 is deleted only after loki-10's replacement is Ready.
	order := strings.Join(f.commands, "\n")
	if strings.Index(order, "pods/loki-2 -f") < strings.Index(order, "-n loki get pod loki-10 ") {
		t.Errorf("loki-2 deleted before waiting for loki-10:\n%s", order)
	}
	for _, rollout := range []string{"-n alloy get daemonset alloy", "-n traefik get deployment traefik"} {
		if !slices.ContainsFunc(f.commands, func(c string) bool { return strings.HasPrefix(c, rollout) }) {
			t.Errorf("did not wait for %s", rollout)
		}
	}
}

func TestUnreadyListsWorkloadsAndRunningJobs(t *testing.T) {
	k := func(context.Context, ...string) (string, error) {
		return list(
			map[string]any{"kind": "Deployment", "metadata": map[string]any{"namespace": "a", "name": "ok"}, "spec": map[string]any{"replicas": 2}, "status": map[string]any{"readyReplicas": 2, "updatedReplicas": 2}},
			map[string]any{"kind": "Deployment", "metadata": map[string]any{"namespace": "a", "name": "down"}, "spec": map[string]any{"replicas": 1}, "status": map[string]any{}},
			map[string]any{"kind": "StatefulSet", "metadata": map[string]any{"namespace": "harbor", "name": "db"}, "spec": map[string]any{"replicas": 1}, "status": map[string]any{"readyReplicas": 0, "updatedReplicas": 1}},
			map[string]any{"kind": "DaemonSet", "metadata": map[string]any{"namespace": "kube-system", "name": "cilium"}, "status": map[string]any{"desiredNumberScheduled": 5, "numberReady": 5, "updatedNumberScheduled": 5}},
			map[string]any{"kind": "Job", "metadata": map[string]any{"namespace": "j", "name": "done"}, "status": map[string]any{"succeeded": 1, "conditions": []any{map[string]any{"type": "Complete", "status": "True"}}}},
			map[string]any{"kind": "Job", "metadata": map[string]any{"namespace": "j", "name": "running"}, "status": map[string]any{"active": 1}},
		), nil
	}
	workloads, jobs, err := Unready(t.Context(), k)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(workloads, []string{"Deployment/a/down ready 0/1", "StatefulSet/harbor/db ready 0/1"}) {
		t.Errorf("workloads %v", workloads)
	}
	if !slices.Equal(jobs, []string{"Job/j/running active 1 failed 0"}) {
		t.Errorf("jobs %v", jobs)
	}
}

// gatewayNamespace holds two Deployments and a StatefulSet whose pods all
// sit on a node's cni0 address: a's and b's ReplicaSets' pods and db-0 on
// w1's, db-1's replacement on w2's.
type gatewayNamespace struct {
	t       *testing.T
	mu      sync.Mutex
	deleted []string // namespace/name UID
	pods    map[string]podSpec
	uids    map[string]string
}

func newGatewayNamespace(t *testing.T) *gatewayNamespace {
	g := &gatewayNamespace{t: t, pods: map[string]podSpec{}, uids: map[string]string{}}
	for _, p := range []podSpec{
		{name: "a-1", node: "w1", ip: "10.244.1.1", owner: [2]string{"ReplicaSet", "a-rs"}},
		{name: "a-2", node: "w2", ip: "10.244.5.8", owner: [2]string{"ReplicaSet", "a-rs"}},
		{name: "b-1", node: "w1", ip: "10.244.1.1", owner: [2]string{"ReplicaSet", "b-rs"}},
		{name: "db-0", node: "w1", ip: "10.244.1.1", owner: [2]string{"StatefulSet", "db"}},
		{name: "db-1", node: "w2", ip: "10.244.5.1", owner: [2]string{"StatefulSet", "db"}},
	} {
		p.namespace, p.sandbox, p.ready = "web", after, false
		g.pods[p.name], g.uids[p.name] = p, "uid-"+p.name
	}
	return g
}

func (g *gatewayNamespace) kubectl(_ context.Context, args ...string) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	command := strings.Join(args, " ")
	switch {
	case command == "-n web get pods -o json":
		items := []any{}
		for _, name := range slicesSortedKeys(g.pods) {
			items = append(items, g.pods[name].object())
		}
		return list(items...), nil
	case command == "-n web get replicasets -o json":
		return list(
			map[string]any{"metadata": map[string]any{"uid": "uid-a-rs", "ownerReferences": []any{map[string]any{"kind": "Deployment", "name": "a", "uid": "uid-a", "controller": true}}}},
			map[string]any{"metadata": map[string]any{"uid": "uid-b-rs", "ownerReferences": []any{map[string]any{"kind": "Deployment", "name": "b", "uid": "uid-b", "controller": true}}}},
		), nil
	case strings.HasPrefix(command, "-n web get deployment a "):
		if _, ok := g.pods["a-1"]; ok {
			return "2 1", nil
		}
		return "2 2", nil
	case strings.HasPrefix(command, "-n web get pod db-1 "):
		p := g.pods["db-1"]
		return fmt.Sprintf("%s %s %s %v", g.uids["db-1"], p.node, p.ip, map[bool]string{true: "True", false: "False"}[p.ready]), nil
	case len(args) == 5 && args[0] == "delete" && args[1] == "--raw":
		key, uid := rawDelete(g.t, args)
		_, name, _ := strings.Cut(key, "/")
		if g.uids[name] != uid {
			return "", errors.New("Error from server (Conflict): Precondition failed")
		}
		g.deleted = append(g.deleted, key+" "+uid)
		if name == "db-1" {
			// The StatefulSet recreates it elsewhere, and it becomes Ready.
			g.uids[name] = "uid-db-1-again"
			g.pods[name] = podSpec{namespace: "web", name: "db-1", node: "w2", ip: "10.244.5.20", owner: [2]string{"StatefulSet", "db"}, ready: true}
		} else {
			delete(g.pods, name)
		}
	}
	return "", nil
}

func TestGatewayRecoveryTouchesOnlyTheAwaitedOwner(t *testing.T) {
	gateways := map[string]string{"w1": "10.244.1.1", "w2": "10.244.5.1"}
	g := newGatewayNamespace(t)
	if err := waitOwnerReady(t.Context(), g.kubectl, "web", Owner{Kind: "Deployment", Name: "a", UID: "uid-a"}, gateways, io.Discard, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(g.deleted, []string{"web/a-1 uid-a-1"}) {
		t.Errorf("waiting for Deployment a deleted %v, want only a-1, by its UID", g.deleted)
	}

	// db-1's replacement landed on w2's cni0 address; db-0 on w1's is the
	// next ordinal's business, not this wait's.
	g = newGatewayNamespace(t)
	old := Pod{Namespace: "web", Name: "db-1", UID: "uid-db-1-before"}
	if err := waitReplaced(t.Context(), g.kubectl, old, true, gateways, io.Discard, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(g.deleted, []string{"web/db-1 uid-db-1"}) {
		t.Errorf("waiting for db-1 deleted %v, want only db-1's replacement, by its UID", g.deleted)
	}
}

func TestTalosCNI0FindsResidualBridges(t *testing.T) {
	output := `{"node":"10.10.10.21","metadata":{"id":"cni0/10.244.1.1/24"},"spec":{"address":"10.244.1.1/24","family":"inet4","linkName":"cni0"}}
{"node":"10.10.10.21","metadata":{"id":"cni0/fe80::1/64"},"spec":{"address":"fe80::1/64","family":"inet6","linkName":"cni0"}}
{"node":"10.10.10.21","metadata":{"id":"flannel.1/10.244.1.0/32"},"spec":{"address":"10.244.1.0/32","family":"inet4","linkName":"flannel.1"}}
{"node":"10.10.10.22","metadata":{"id":"eth0/10.10.10.22/24"},"spec":{"address":"10.10.10.22/24","family":"inet4","linkName":"eth0"}}
`
	var asked []string
	lookup := TalosCNI0(func(_ context.Context, args ...string) (string, error) {
		asked = args
		return output, nil
	})
	found, err := lookup(t.Context(), map[string]string{"w1": "10.10.10.21", "w2": "10.10.10.22"})
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 1 || found["w1"] != "10.244.1.1" {
		t.Errorf("found %v, want only w1's 10.244.1.1", found)
	}
	if strings.Join(asked, " ") != "-n 10.10.10.21,10.10.10.22 get addresses -o json" {
		t.Errorf("ran talosctl %v", asked)
	}
}
