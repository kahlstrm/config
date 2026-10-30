package cnipods

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

func (f *fake) kubectl(_ context.Context, args ...string) (string, error) {
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
			map[string]any{"metadata": map[string]any{"name": "w1"}, "spec": map[string]any{"podCIDR": "10.244.1.0/24"}},
			map[string]any{"metadata": map[string]any{"name": "w2"}, "spec": map[string]any{"podCIDR": "10.244.5.0/24"}},
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
	if len(args) > 4 && args[2] == "get" && args[3] == "pod" {
		key := args[1] + "/" + args[4]
		if f.replaced[key] {
			return "uid-new True", nil
		}
		return "uid-" + args[4], nil
	}
	if len(args) > 4 && args[2] == "get" && (args[3] == "deployment" || args[3] == "daemonset") {
		return "1 1", nil
	}
	if len(args) > 4 && args[2] == "delete" {
		f.replaced[args[1]+"/"+args[4]] = true
	}
	return "", nil
}

func gather(t *testing.T, f *fake) Plan {
	t.Helper()
	inv, err := Gather(t.Context(), f.kubectl)
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
	plan := gather(t, &fake{pods: cluster()})
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

func TestEndpointsAgreeWithSandboxAges(t *testing.T) {
	pods := cluster()
	endpoints := []string{"web/on-cilium"}
	sandboxes := gather(t, &fake{pods: pods})
	withEndpoints := gather(t, &fake{pods: pods, endpoints: endpoints})
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
	inv, err := Gather(t.Context(), f.kubectl)
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
	f := &fake{pods: cluster(), replaced: map[string]bool{}}
	err := Recreate(t.Context(), f.kubectl, gather(t, f), Options{Timeout: time.Second})
	if err == nil || !strings.Contains(err.Error(), "w3") {
		t.Fatalf("got %v, want a refusal naming w3", err)
	}
	if len(f.commands) != 0 {
		t.Errorf("ran %v", f.commands)
	}
}

func TestRecreateDeletesByOwnerAndWaitsForEachStatefulSetPod(t *testing.T) {
	pods := slices.DeleteFunc(cluster(), func(p podSpec) bool { return p.node == "w3" })
	f := &fake{pods: pods, replaced: map[string]bool{}}
	var log strings.Builder
	if err := Recreate(t.Context(), f.kubectl, gather(t, f), Options{Timeout: time.Second, Include: []string{"default/standalone"}, Log: &log}); err != nil {
		t.Fatal(err)
	}
	deletes := []string{}
	for _, command := range f.commands {
		if strings.Contains(command, " delete pod ") {
			deletes = append(deletes, strings.Fields(command)[1]+"/"+strings.Fields(command)[4])
		}
	}
	// Deployments, DaemonSets and the included pod first, then the
	// StatefulSets side by side, each highest ordinal first.
	first := []string{"alloy/alloy-x", "traefik/traefik-abc", "web/on-gateway", "default/standalone"}
	if len(deletes) != 7 || !slices.Equal(deletes[:4], first) {
		t.Fatalf("deleted %v, want %v first", deletes, first)
	}
	if rest := slices.Sorted(slices.Values(deletes[4:])); !slices.Equal(rest, []string{"harbor/harbor-database-0", "loki/loki-10", "loki/loki-2"}) {
		t.Errorf("deleted %v after the others", deletes[4:])
	}
	if slices.Index(deletes, "loki/loki-10") > slices.Index(deletes, "loki/loki-2") {
		t.Errorf("deleted loki-2 before loki-10: %v", deletes)
	}
	for _, untouched := range []string{"descheduler-1", "virt-launcher-vm", "pocket-id-sync-1"} {
		if strings.Contains(strings.Join(deletes, " "), untouched) {
			t.Errorf("deleted %s", untouched)
		}
		if untouched != "pocket-id-sync-1" && !strings.Contains(log.String(), untouched) {
			t.Errorf("did not report %s:\n%s", untouched, log.String())
		}
	}
	// loki-2 is deleted only after loki-10's replacement is Ready.
	order := strings.Join(f.commands, "\n")
	if strings.Index(order, "loki delete pod loki-2") < strings.Index(order, "loki get pod loki-10 --ignore-not-found -o jsonpath={.metadata.uid} {") {
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
