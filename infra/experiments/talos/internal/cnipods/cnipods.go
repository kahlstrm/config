// Package cnipods finds the pods a switch to Cilium left on the previous pod
// network and recreates them through their owners, one StatefulSet pod at a
// time. It reads the cluster through kubectl, so the Talos lab and production
// run the same code; see cmd/cni-pods.
package cnipods

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Kubectl runs kubectl with args against one cluster and returns its stdout.
type Kubectl func(ctx context.Context, args ...string) (string, error)

// Action is what Recreate does with a candidate pod.
type Action string

const (
	// Delete lets the pod's Deployment, ReplicaSet or DaemonSet replace it.
	// Deletes ignore PodDisruptionBudgets: the pods have no network already,
	// and a single-replica budget would block an eviction forever.
	Delete Action = "delete"
	// Sequential deletes a StatefulSet's pods one at a time, highest ordinal
	// first, and waits for each replacement to be Ready.
	Sequential Action = "one-at-a-time"
	// Report leaves the pod alone: standalone pods have nothing to recreate
	// them, a Job's pod would run its side effects again, and other owners,
	// such as KubeVirt's virtual machines, need their operator's procedure.
	Report Action = "report"
)

// Owner is the controller that recreates a pod: a ReplicaSet's Deployment
// and a Job's CronJob replace the immediate owner.
type Owner struct {
	Kind, Name, UID string
}

func (o Owner) String() string {
	if o.Kind == "" {
		return "none"
	}
	return o.Kind + "/" + o.Name
}

// Pod is what the plan needs to know about one pod.
type Pod struct {
	Namespace, Name, UID, Node, Phase, IP string
	HostNetwork, Mirror, Terminating      bool
	Owner                                 Owner
	// Sandbox is when the pod's current sandbox, and so its network, was
	// created: the PodReadyToStartContainers condition's transition. Zero
	// until the pod has a sandbox.
	Sandbox time.Time
	Ready   bool
}

func (p Pod) Key() string { return p.Namespace + "/" + p.Name }

// Inventory is the cluster state the plan is made from.
type Inventory struct {
	Taken time.Time
	Pods  []Pod
	// Agents is when each node's Cilium agent became Ready; nodes without a
	// Ready agent are absent.
	Agents map[string]time.Time
	// Gateways is each node's Flannel gateway address, the first of its
	// podCIDR.
	Gateways map[string]string
	// Endpoints holds the namespace/name of every CiliumEndpoint, or is nil
	// when they cannot be listed, as with the agent environment's read-only
	// RBAC, which has no cilium.io access.
	Endpoints map[string]bool
}

// Candidate is a pod still on the previous network.
type Candidate struct {
	Pod
	Action Action
	Reason string
}

// Reasons a pod is a candidate.
const (
	OnPrevious = "on the previous network"
	// Flannel's cni0 bridge keeps its podCIDR's first address until the node
	// reboots, while Cilium's Kubernetes IPAM hands that address to a pod,
	// which then cannot be reached.
	OnGateway = "holds the address of Flannel's cni0"
)

// Skip is a pod the plan leaves alone, and why.
type Skip struct {
	Pod
	Reason string
}

// Plan is the classification of every pod.
type Plan struct {
	Candidates []Candidate
	Skipped    []Skip
	// Blocked lists nodes that run pod-network pods but have no Ready Cilium
	// agent; nothing on them can be recreated yet.
	Blocked []string
	// Signal says how candidates were found: CiliumEndpoints, or sandboxes
	// older than the node's agent.
	Signal string
}

// Grace is how long a pod networked by Cilium may lack its CiliumEndpoint
// before it counts as unmanaged.
const Grace = 30 * time.Second

// Classify sorts pods into candidates and skipped pods. A candidate is a
// running or starting pod-network pod whose sandbox predates its node's
// Cilium agent, or, when CiliumEndpoints are readable, that has none.
func Classify(inv Inventory) Plan {
	plan := Plan{Signal: "sandbox older than the node's Cilium agent"}
	if inv.Endpoints != nil {
		plan.Signal = "no CiliumEndpoint"
	}
	blocked := map[string]bool{}
	for _, pod := range inv.Pods {
		skip := func(reason string) { plan.Skipped = append(plan.Skipped, Skip{pod, reason}) }
		agentReady, agent := inv.Agents[pod.Node]
		switch {
		case pod.HostNetwork:
			skip("host network")
		case pod.Mirror:
			skip("static pod")
		case pod.Terminating:
			skip("terminating")
		case pod.Phase == "Succeeded" || pod.Phase == "Failed":
			skip("finished")
		case pod.Sandbox.IsZero():
			skip("no sandbox yet")
		case !agent:
			blocked[pod.Node] = true
			skip("no Ready Cilium agent on its node")
		case pod.IP != "" && pod.IP == inv.Gateways[pod.Node]:
			plan.Candidates = append(plan.Candidates, Candidate{pod, action(pod.Owner), OnGateway})
		case inv.Endpoints != nil && inv.Endpoints[pod.Key()]:
			skip("has a CiliumEndpoint")
		case inv.Endpoints != nil && pod.Sandbox.After(agentReady) && inv.Taken.Sub(pod.Sandbox) < Grace:
			skip("started on Cilium moments ago; recheck")
		case inv.Endpoints == nil && pod.Sandbox.After(agentReady):
			skip("sandbox newer than its node's Cilium agent")
		default:
			plan.Candidates = append(plan.Candidates, Candidate{pod, action(pod.Owner), OnPrevious})
		}
	}
	for node := range blocked {
		plan.Blocked = append(plan.Blocked, node)
	}
	slices.Sort(plan.Blocked)
	slices.SortFunc(plan.Candidates, func(a, b Candidate) int { return strings.Compare(a.Key(), b.Key()) })
	slices.SortFunc(plan.Skipped, func(a, b Skip) int { return strings.Compare(a.Key(), b.Key()) })
	return plan
}

func action(owner Owner) Action {
	switch owner.Kind {
	case "Deployment", "ReplicaSet", "DaemonSet":
		return Delete
	case "StatefulSet":
		return Sequential
	default:
		return Report
	}
}

// Of returns the candidates with the given action.
func (p Plan) Of(a Action) []Candidate {
	return slices.DeleteFunc(slices.Clone(p.Candidates), func(c Candidate) bool { return c.Action != a })
}

// Keys returns the candidates' namespace/name.
func (p Plan) Keys() []string {
	keys := []string{}
	for _, c := range p.Candidates {
		keys = append(keys, c.Key())
	}
	return keys
}

func (p Plan) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%d pods on the previous network (%s)", len(p.Candidates), p.Signal)
	if len(p.Blocked) > 0 {
		fmt.Fprintf(&b, "; nodes without a Ready Cilium agent: %s", strings.Join(p.Blocked, " "))
	}
	b.WriteString("\n")
	for _, c := range p.Candidates {
		fmt.Fprintf(&b, "  %-14s %-60s %-5s %-8s owner %s; %s\n", c.Action, c.Key(), c.Node, c.Phase, c.Owner, c.Reason)
	}
	reasons := map[string]int{}
	for _, s := range p.Skipped {
		reasons[s.Reason]++
	}
	for _, reason := range slicesSortedKeys(reasons) {
		fmt.Fprintf(&b, "  skipped %d: %s\n", reasons[reason], reason)
	}
	return b.String()
}

func slicesSortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	return keys
}

type meta struct {
	Namespace         string            `json:"namespace"`
	Name              string            `json:"name"`
	UID               string            `json:"uid"`
	DeletionTimestamp *time.Time        `json:"deletionTimestamp"`
	Annotations       map[string]string `json:"annotations"`
	Labels            map[string]string `json:"labels"`
	OwnerReferences   []struct {
		Kind       string `json:"kind"`
		Name       string `json:"name"`
		UID        string `json:"uid"`
		Controller bool   `json:"controller"`
	} `json:"ownerReferences"`
}

func (m meta) controller() Owner {
	for _, ref := range m.OwnerReferences {
		if ref.Controller {
			return Owner{ref.Kind, ref.Name, ref.UID}
		}
	}
	return Owner{}
}

type condition struct {
	Type               string    `json:"type"`
	Status             string    `json:"status"`
	LastTransitionTime time.Time `json:"lastTransitionTime"`
}

func since(conditions []condition, kind string) (time.Time, bool) {
	for _, c := range conditions {
		if c.Type == kind && c.Status == "True" {
			return c.LastTransitionTime, true
		}
	}
	return time.Time{}, false
}

type podList struct {
	Items []struct {
		Metadata meta `json:"metadata"`
		Spec     struct {
			NodeName    string `json:"nodeName"`
			HostNetwork bool   `json:"hostNetwork"`
		} `json:"spec"`
		Status struct {
			Phase      string      `json:"phase"`
			PodIP      string      `json:"podIP"`
			Conditions []condition `json:"conditions"`
		} `json:"status"`
	} `json:"items"`
}

type ownerList struct {
	Items []struct {
		Kind     string `json:"kind"`
		Metadata meta   `json:"metadata"`
	} `json:"items"`
}

// agentSelector matches Cilium's agent pods, as the chart labels them.
const agentSelector = "k8s-app=cilium"

// Gather reads the inventory: every pod, the ReplicaSets and Jobs that own
// them, the Cilium agents and, if readable, the CiliumEndpoints.
func Gather(ctx context.Context, k Kubectl) (Inventory, error) {
	inv := Inventory{Taken: time.Now(), Agents: map[string]time.Time{}, Gateways: map[string]string{}}
	var nodes struct {
		Items []struct {
			Metadata meta `json:"metadata"`
			Spec     struct {
				PodCIDR string `json:"podCIDR"`
			} `json:"spec"`
		} `json:"items"`
	}
	if err := get(ctx, k, &nodes, "get", "nodes", "-o", "json"); err != nil {
		return inv, err
	}
	for _, node := range nodes.Items {
		if prefix, err := netip.ParsePrefix(node.Spec.PodCIDR); err == nil {
			inv.Gateways[node.Metadata.Name] = prefix.Masked().Addr().Next().String()
		}
	}
	var pods podList
	var owners ownerList
	if err := get(ctx, k, &pods, "get", "pods", "-A", "-o", "json"); err != nil {
		return inv, err
	}
	if err := get(ctx, k, &owners, "get", "replicasets,jobs", "-A", "-o", "json"); err != nil {
		return inv, err
	}
	parents := map[string]Owner{}
	for _, item := range owners.Items {
		if parent := item.Metadata.controller(); parent.Kind != "" {
			parents[item.Metadata.UID] = parent
		}
	}
	for _, item := range pods.Items {
		m := item.Metadata
		owner := m.controller()
		// A ReplicaSet's Deployment or a Job's CronJob decides what replaces it.
		if parent, ok := parents[owner.UID]; ok && (owner.Kind == "ReplicaSet" || owner.Kind == "Job") {
			owner = parent
		}
		sandbox, _ := since(item.Status.Conditions, "PodReadyToStartContainers")
		_, ready := since(item.Status.Conditions, "Ready")
		pod := Pod{
			Namespace: m.Namespace, Name: m.Name, UID: m.UID, Node: item.Spec.NodeName, Phase: item.Status.Phase, IP: item.Status.PodIP,
			HostNetwork: item.Spec.HostNetwork, Mirror: m.Annotations["kubernetes.io/config.mirror"] != "",
			Terminating: m.DeletionTimestamp != nil, Owner: owner, Sandbox: sandbox, Ready: ready,
		}
		inv.Pods = append(inv.Pods, pod)
		if m.Namespace == "kube-system" && m.Labels["k8s-app"] == "cilium" && ready && !pod.Terminating {
			at, _ := since(item.Status.Conditions, "Ready")
			inv.Agents[pod.Node] = at
		}
	}
	var endpoints struct {
		Items []struct {
			Metadata meta `json:"metadata"`
		} `json:"items"`
	}
	if err := get(ctx, k, &endpoints, "get", "ciliumendpoints.cilium.io", "-A", "-o", "json"); err == nil {
		inv.Endpoints = map[string]bool{}
		for _, e := range endpoints.Items {
			inv.Endpoints[e.Metadata.Namespace+"/"+e.Metadata.Name] = true
		}
	}
	return inv, nil
}

func get(ctx context.Context, k Kubectl, into any, args ...string) error {
	output, err := k(ctx, args...)
	if err != nil {
		return err
	}
	return json.Unmarshal([]byte(output), into)
}

// Options control Recreate.
type Options struct {
	// Include lists namespace/name of report-only pods to delete anyway,
	// after checking that their owner tolerates it.
	Include []string
	// Timeout bounds each wait for a replacement or an owner.
	Timeout time.Duration
	Log     io.Writer
}

// Recreate deletes the plan's candidates so their owners replace them on the
// new network: Deployment and DaemonSet pods all at once, then every
// StatefulSet side by side, each one pod at a time with each replacement
// Ready before the next.
// It then waits for every owner it touched. Report-only pods are listed and
// left alone unless included. It refuses to start while any node lacks a
// Ready Cilium agent.
func Recreate(ctx context.Context, k Kubectl, plan Plan, opts Options) error {
	log := logOf(opts)
	timeout := cmp.Or(opts.Timeout, 10*time.Minute)
	if len(plan.Blocked) > 0 {
		return fmt.Errorf("nodes without a Ready Cilium agent: %s", strings.Join(plan.Blocked, " "))
	}
	parallel, sequential := plan.Of(Delete), plan.Of(Sequential)
	for _, c := range plan.Of(Report) {
		if slices.Contains(opts.Include, c.Key()) {
			fmt.Fprintf(log, "including %s (owner %s) as asked\n", c.Key(), c.Owner)
			parallel = append(parallel, c)
			continue
		}
		fmt.Fprintf(log, "left alone: %s on %s, owner %s; recreate it by hand if it needs the network\n", c.Key(), c.Node, c.Owner)
	}
	for _, c := range parallel {
		if err := deletePod(ctx, k, c.Pod); err != nil {
			return err
		}
		fmt.Fprintf(log, "deleted %s (owner %s)\n", c.Key(), c.Owner)
	}
	// StatefulSets go side by side, each one pod at a time.
	sets := byOwner(sequential)
	errs := make([]error, len(sets))
	var wg sync.WaitGroup
	var mu sync.Mutex
	for i, set := range sets {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for _, c := range set {
				started := time.Now()
				if errs[i] = deletePod(ctx, k, c.Pod); errs[i] != nil {
					return
				}
				if errs[i] = waitReplaced(ctx, k, c.Pod, true, timeout); errs[i] != nil {
					return
				}
				mu.Lock()
				fmt.Fprintf(log, "recreated %s (owner %s), Ready after %s\n", c.Key(), c.Owner, time.Since(started).Round(time.Second))
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if err := errors.Join(errs...); err != nil {
		return err
	}
	for _, c := range parallel {
		if err := waitReplaced(ctx, k, c.Pod, false, timeout); err != nil {
			return err
		}
	}
	waited := map[Owner]bool{}
	for _, c := range parallel {
		if waited[c.Owner] || (c.Owner.Kind != "Deployment" && c.Owner.Kind != "DaemonSet") {
			continue
		}
		waited[c.Owner] = true
		started := time.Now()
		if err := waitOwnerReady(ctx, k, c.Namespace, c.Owner, timeout); err != nil {
			return err
		}
		fmt.Fprintf(log, "%s/%s ready after %s\n", c.Namespace, c.Owner, time.Since(started).Round(time.Second))
	}
	return nil
}

// waitOwnerReady waits until a Deployment or DaemonSet has as many Ready pods
// as it wants. Unlike `kubectl rollout status`, it does not give up on a
// Deployment that exceeded its progress deadline while its pods had no
// network. On timeout, the error lists the namespace's pods.
func waitOwnerReady(ctx context.Context, k Kubectl, namespace string, owner Owner, timeout time.Duration) error {
	fields := "{.spec.replicas} {.status.readyReplicas}"
	if owner.Kind == "DaemonSet" {
		fields = "{.status.desiredNumberScheduled} {.status.numberReady}"
	}
	deadline := time.Now().Add(timeout)
	for {
		output, err := k(ctx, "-n", namespace, "get", strings.ToLower(owner.Kind), owner.Name, "-o", "jsonpath="+fields)
		if err == nil {
			counts := strings.Fields(output)
			if len(counts) == 2 && counts[0] == counts[1] {
				return nil
			}
		}
		if time.Now().After(deadline) {
			pods, _ := k(ctx, "-n", namespace, "get", "pods", "-o", "wide")
			return fmt.Errorf("%s/%s not ready after %s (want, ready: %q %v); pods:\n%s", namespace, owner, timeout, output, err, pods)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

// deletePod deletes the pod unless it is already gone or replaced by a pod
// of the same name, as a StatefulSet's would be.
func deletePod(ctx context.Context, k Kubectl, pod Pod) error {
	uid, err := k(ctx, "-n", pod.Namespace, "get", "pod", pod.Name, "--ignore-not-found", "-o", "jsonpath={.metadata.uid}")
	if err != nil || strings.TrimSpace(uid) != pod.UID {
		return err
	}
	_, err = k(ctx, "-n", pod.Namespace, "delete", "pod", pod.Name, "--wait=false", "--ignore-not-found")
	return err
}

// waitReplaced waits until the pod's UID is gone and, with ready, until a pod
// of the same name is Ready again, as a StatefulSet recreates it.
func waitReplaced(ctx context.Context, k Kubectl, pod Pod, ready bool, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		output, err := k(ctx, "-n", pod.Namespace, "get", "pod", pod.Name, "--ignore-not-found", "-o", `jsonpath={.metadata.uid} {.status.conditions[?(@.type=="Ready")].status}`)
		if err == nil {
			fields := strings.Fields(output)
			gone := len(fields) == 0 || fields[0] != pod.UID
			if gone && (!ready || len(fields) == 2 && fields[1] == "True") {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s not replaced%s after %s: %q %v", pod.Key(), map[bool]string{true: " and Ready"}[ready], timeout, output, err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

var ordinal = regexp.MustCompile(`-(\d+)$`)

// byOwner groups StatefulSet candidates by owner, highest ordinal first, as
// a StatefulSet's own rolling update goes.
func byOwner(candidates []Candidate) [][]Candidate {
	groups := map[string][]Candidate{}
	for _, c := range candidates {
		key := c.Namespace + "/" + c.Owner.Name
		groups[key] = append(groups[key], c)
	}
	sets := [][]Candidate{}
	for _, key := range slicesSortedKeys(groups) {
		set := groups[key]
		slices.SortFunc(set, func(a, b Candidate) int { return cmp.Compare(index(b.Name), index(a.Name)) })
		sets = append(sets, set)
	}
	return sets
}

func index(name string) int {
	match := ordinal.FindStringSubmatch(name)
	if match == nil {
		return -1
	}
	n, _ := strconv.Atoi(match[1])
	return n
}

// Unready lists Deployments, StatefulSets and DaemonSets with fewer Ready
// pods than they want, and Jobs that are still running or have failed pods.
func Unready(ctx context.Context, k Kubectl) (workloads, jobs []string, err error) {
	var list struct {
		Items []struct {
			Kind     string `json:"kind"`
			Metadata meta   `json:"metadata"`
			Spec     struct {
				Replicas *int `json:"replicas"`
			} `json:"spec"`
			Status struct {
				ReadyReplicas, DesiredNumberScheduled, NumberReady int
				Active, Failed                                     int
				Conditions                                         []condition
			} `json:"status"`
		} `json:"items"`
	}
	if err := get(ctx, k, &list, "get", "deployments,statefulsets,daemonsets,jobs", "-A", "-o", "json"); err != nil {
		return nil, nil, err
	}
	for _, item := range list.Items {
		name := item.Kind + "/" + item.Metadata.Namespace + "/" + item.Metadata.Name
		s := item.Status
		switch item.Kind {
		case "Deployment", "StatefulSet":
			want := 1
			if item.Spec.Replicas != nil {
				want = *item.Spec.Replicas
			}
			if s.ReadyReplicas < want {
				workloads = append(workloads, fmt.Sprintf("%s ready %d/%d", name, s.ReadyReplicas, want))
			}
		case "DaemonSet":
			if s.NumberReady < s.DesiredNumberScheduled {
				workloads = append(workloads, fmt.Sprintf("%s ready %d/%d", name, s.NumberReady, s.DesiredNumberScheduled))
			}
		case "Job":
			if _, done := since(s.Conditions, "Complete"); done {
				continue
			}
			if s.Active > 0 || s.Failed > 0 {
				jobs = append(jobs, fmt.Sprintf("%s active %d failed %d", name, s.Active, s.Failed))
			}
		}
	}
	return workloads, jobs, nil
}

// Run is the whole procedure: plan, recreate, then Verify. It returns the
// first plan and the last check's.
func Run(ctx context.Context, k Kubectl, opts Options) (first, last Plan, err error) {
	inv, err := Gather(ctx, k)
	if err != nil {
		return first, last, err
	}
	first = Classify(inv)
	plan := first
	// A replacement can be given a node's Flannel gateway address again, so
	// recreate until no pod but report-only ones is left, three rounds at
	// most.
	for round := 1; ; round++ {
		fmt.Fprintf(logOf(opts), "round %d: %s", round, plan)
		if err := Recreate(ctx, k, plan, opts); err != nil {
			return first, last, err
		}
		if inv, err = Gather(ctx, k); err != nil {
			return first, last, err
		}
		plan = Classify(inv)
		if round == 3 || !slices.ContainsFunc(plan.Candidates, func(c Candidate) bool { return c.Action != Report }) {
			break
		}
	}
	last, err = Verify(ctx, k, opts)
	return first, last, err
}

func logOf(opts Options) io.Writer {
	if opts.Log == nil {
		return io.Discard
	}
	return opts.Log
}

// Verify waits until no pod but report-only ones is on the previous network,
// every node has a Ready Cilium agent, and every Deployment, StatefulSet and
// DaemonSet is ready. It lists Jobs that are running or failed, and returns
// the last check's plan.
func Verify(ctx context.Context, k Kubectl, opts Options) (Plan, error) {
	timeout := cmp.Or(opts.Timeout, 10*time.Minute)
	deadline := time.Now().Add(timeout)
	for {
		inv, err := Gather(ctx, k)
		if err != nil {
			return Plan{}, err
		}
		plan := Classify(inv)
		left := []string{}
		for _, c := range plan.Candidates {
			if c.Action != Report || slices.Contains(opts.Include, c.Key()) {
				left = append(left, c.Key())
			}
		}
		rechecks := slices.ContainsFunc(plan.Skipped, func(s Skip) bool { return strings.HasSuffix(s.Reason, "recheck") })
		workloads, jobs, err := Unready(ctx, k)
		if err != nil {
			return plan, err
		}
		if len(left) == 0 && !rechecks && len(workloads) == 0 && len(plan.Blocked) == 0 {
			fmt.Fprintf(logOf(opts), "verified: no recreatable pod on the previous network, every workload ready\n")
			for _, job := range jobs {
				fmt.Fprintf(logOf(opts), "job to check: %s\n", job)
			}
			return plan, nil
		}
		if time.Now().After(deadline) {
			return plan, fmt.Errorf("after %s: on the previous network %v, nodes without a Ready agent %v, not ready %v", timeout, left, plan.Blocked, workloads)
		}
		select {
		case <-ctx.Done():
			return plan, ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
}
