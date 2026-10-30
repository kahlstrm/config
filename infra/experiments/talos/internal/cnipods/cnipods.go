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
	"os"
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
	// Gateways holds, for each node whose Flannel cni0 bridge is still up,
	// that bridge's address; see OnGateway.
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
	// which then cannot be reached. Only nodes whose cni0 is confirmed still
	// up count, so the exception ends with the bridge.
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
	// Gateways is the inventory's Gateways.
	Gateways map[string]string
}

// How a plan found its candidates.
const (
	SignalEndpoints = "no CiliumEndpoint"
	SignalSandbox   = "sandbox older than the node's Cilium agent"
)

// Grace is how long a pod networked by Cilium may lack its CiliumEndpoint
// before it counts as unmanaged.
const Grace = 30 * time.Second

// Classify sorts pods into candidates and skipped pods. A candidate is a
// running or starting pod-network pod whose sandbox predates its node's
// Cilium agent, or, when CiliumEndpoints are readable, that has none.
func Classify(inv Inventory) Plan {
	plan := Plan{Signal: SignalSandbox, Gateways: inv.Gateways}
	if inv.Endpoints != nil {
		plan.Signal = SignalEndpoints
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
	for _, node := range slicesSortedKeys(p.Gateways) {
		fmt.Fprintf(&b, "  cni0 still up on %s with %s\n", node, p.Gateways[node])
	}
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

// CNI0 returns, by node name, the IPv4 address of each node's Flannel cni0
// bridge that is still up, given each node's InternalIP by name.
type CNI0 func(ctx context.Context, nodes map[string]string) (map[string]string, error)

// TalosCNI0 finds cni0 bridges through Talos's read-only address resources,
// with talosctl run by talos (an os:reader talosconfig suffices).
func TalosCNI0(talos func(ctx context.Context, args ...string) (string, error)) CNI0 {
	return func(ctx context.Context, nodes map[string]string) (map[string]string, error) {
		ips, names := []string{}, map[string]string{}
		for name, ip := range nodes {
			ips, names[ip] = append(ips, ip), name
		}
		slices.Sort(ips)
		output, err := talos(ctx, "-n", strings.Join(ips, ","), "get", "addresses", "-o", "json")
		if err != nil {
			return nil, err
		}
		found := map[string]string{}
		decoder := json.NewDecoder(strings.NewReader(output))
		for {
			var r struct {
				Node string `json:"node"`
				Spec struct {
					Address  string `json:"address"`
					Family   string `json:"family"`
					LinkName string `json:"linkName"`
				} `json:"spec"`
			}
			if err := decoder.Decode(&r); errors.Is(err, io.EOF) {
				return found, nil
			} else if err != nil {
				return nil, err
			}
			if prefix, err := netip.ParsePrefix(r.Spec.Address); err == nil && r.Spec.LinkName == "cni0" && r.Spec.Family == "inet4" && names[r.Node] != "" {
				found[names[r.Node]] = prefix.Addr().String()
			}
		}
	}
}

// Gather reads the inventory: every pod, the ReplicaSets and Jobs that own
// them, the Cilium agents, the cni0 bridges cni0 finds (none if nil) and,
// if readable, the CiliumEndpoints.
func Gather(ctx context.Context, k Kubectl, cni0 CNI0) (Inventory, error) {
	inv := Inventory{Taken: time.Now(), Agents: map[string]time.Time{}, Gateways: map[string]string{}}
	if cni0 != nil {
		var nodes struct {
			Items []struct {
				Metadata meta `json:"metadata"`
				Status   struct {
					Addresses []struct{ Type, Address string } `json:"addresses"`
				} `json:"status"`
			} `json:"items"`
		}
		if err := get(ctx, k, &nodes, "get", "nodes", "-o", "json"); err != nil {
			return inv, err
		}
		ips := map[string]string{}
		for _, node := range nodes.Items {
			for _, address := range node.Status.Addresses {
				if address.Type == "InternalIP" {
					ips[node.Metadata.Name] = address.Address
				}
			}
		}
		gateways, err := cni0(ctx, ips)
		if err != nil {
			return inv, fmt.Errorf("finding cni0 bridges: %w", err)
		}
		inv.Gateways = gateways
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
	output, err := retry(ctx, k, args...)
	if err != nil {
		return err
	}
	return json.Unmarshal([]byte(output), into)
}

// transient matches errors of an API server that is briefly unavailable, as
// it is while the control planes' Cilium agents start, rather than answers
// such as Forbidden or NotFound.
var transient = regexp.MustCompile(`(?i)connection refused|was refused|connection reset|i/o timeout|TLS handshake timeout|unexpected EOF|ServiceUnavailable|the server is currently unable|etcdserver|context deadline exceeded|Client\.Timeout|TooManyRequests|http2: client connection lost`)

// retryFor bounds how long retry keeps trying through transient errors, and
// retryEvery spaces its attempts.
var retryFor, retryEvery = 5 * time.Minute, 5 * time.Second

// retry runs kubectl again, every retryEvery for up to retryFor, while it
// fails with a transient error.
func retry(ctx context.Context, k Kubectl, args ...string) (string, error) {
	deadline := time.Now().Add(retryFor)
	for {
		output, err := k(ctx, args...)
		if err == nil || !transient.MatchString(err.Error()) || time.Now().After(deadline) {
			return output, err
		}
		select {
		case <-ctx.Done():
			return output, errors.Join(err, ctx.Err())
		case <-time.After(retryEvery):
		}
	}
}

// Options control Recreate.
type Options struct {
	// Include lists namespace/name of report-only pods to delete anyway,
	// after checking that their owner tolerates it.
	Include []string
	// Timeout bounds each wait for a replacement or an owner.
	Timeout time.Duration
	Log     io.Writer
	// CNI0 finds nodes whose Flannel cni0 bridge is still up; nil for none.
	CNI0 CNI0
}

// Recreate deletes the plan's candidates so their owners replace them on the
// new network: Deployment and DaemonSet pods all at once, then every
// StatefulSet side by side, each one pod at a time with each replacement
// Ready before the next.
// It then waits for every owner it touched. Report-only pods are listed and
// left alone unless included. It refuses to start while any node lacks a
// Ready Cilium agent, and without CiliumEndpoint access: sandbox ages are
// for diagnosis only, as an agent that restarted makes them over-report.
func Recreate(ctx context.Context, k Kubectl, plan Plan, opts Options) error {
	log := logOf(opts)
	timeout := cmp.Or(opts.Timeout, 10*time.Minute)
	if plan.Signal != SignalEndpoints {
		return errors.New("recreating pods needs read access to CiliumEndpoints; run it as a cluster administrator (plan and verify work without)")
	}
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
				if errs[i] = waitReplaced(ctx, k, c.Pod, true, plan.Gateways, log, timeout); errs[i] != nil {
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
	gone := time.Now()
	for _, c := range parallel {
		if err := waitReplaced(ctx, k, c.Pod, false, nil, log, timeout); err != nil {
			return err
		}
	}
	fmt.Fprintf(log, "every deleted pod gone %s after the StatefulSets\n", time.Since(gone).Round(time.Second))
	waited := map[Owner]bool{}
	for _, c := range parallel {
		if waited[c.Owner] || (c.Owner.Kind != "Deployment" && c.Owner.Kind != "DaemonSet" && c.Owner.Kind != "ReplicaSet") {
			continue
		}
		waited[c.Owner] = true
		started := time.Now()
		if err := waitOwnerReady(ctx, k, c.Namespace, c.Owner, plan.Gateways, log, timeout); err != nil {
			return err
		}
		fmt.Fprintf(log, "%s/%s ready after %s\n", c.Namespace, c.Owner, time.Since(started).Round(time.Second))
	}
	return nil
}

// waitOwnerReady waits until a Deployment, bare ReplicaSet or DaemonSet has
// as many Ready pods as it wants and none of its pods holds its node's cni0
// address: Ready need not mean reachable, as with an exec readiness probe.
// Unlike `kubectl rollout status`, it does not give up on a Deployment that
// exceeded its progress deadline while its pods had no network. It deletes
// the owner's colliding pods again, three times at most, and fails if one
// still collides after that. On timeout, the error lists the namespace's
// pods.
func waitOwnerReady(ctx context.Context, k Kubectl, namespace string, owner Owner, gateways map[string]string, log io.Writer, timeout time.Duration) error {
	fields := "{.spec.replicas} {.status.readyReplicas}"
	if owner.Kind == "DaemonSet" {
		fields = "{.status.desiredNumberScheduled} {.status.numberReady}"
	}
	deadline, retries := time.Now().Add(timeout), 3
	for {
		clear := true
		if len(gateways) > 0 {
			deleted, colliding, err := ownedOffGateways(ctx, k, namespace, owner, gateways, log, retries)
			retries -= deleted
			if err == nil && colliding > deleted && retries == 0 {
				return fmt.Errorf("%s/%s: a pod still holds its node's cni0 address after three recreations", namespace, owner)
			}
			clear = err == nil && colliding == 0
		}
		output, err := k(ctx, "-n", namespace, "get", strings.ToLower(owner.Kind), owner.Name, "-o", "jsonpath="+fields)
		if err == nil && clear {
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

// deletePod deletes exactly this pod: the API server refuses the delete if
// the name now belongs to another pod, such as a StatefulSet's replacement.
// A pod already gone or replaced is not an error.
func deletePod(ctx context.Context, k Kubectl, pod Pod) error {
	options, err := os.CreateTemp("", "cni-pods-delete-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(options.Name())
	body := fmt.Sprintf(`{"kind":"DeleteOptions","apiVersion":"v1","preconditions":{"uid":%q}}`, pod.UID)
	if _, err := options.WriteString(body); err != nil {
		return errors.Join(err, options.Close())
	}
	if err := options.Close(); err != nil {
		return err
	}
	_, err = retry(ctx, k, "delete", "--raw", "/api/v1/namespaces/"+pod.Namespace+"/pods/"+pod.Name, "-f", options.Name())
	if err != nil && staleDelete.MatchString(err.Error()) {
		return nil
	}
	return err
}

// staleDelete matches a delete of a pod that is gone or whose name another
// pod now has (the UID precondition failed).
var staleDelete = regexp.MustCompile(`(?i)not ?found|precondition failed|conflict`)

// ownedOffGateways finds the owner's own pods that hold their node's cni0
// address and deletes up to limit of them. It returns how many it deleted and
// how many it found. A Deployment owns pods through its ReplicaSets.
func ownedOffGateways(ctx context.Context, k Kubectl, namespace string, owner Owner, gateways map[string]string, log io.Writer, limit int) (deleted, colliding int, err error) {
	var pods podList
	if err := get(ctx, k, &pods, "-n", namespace, "get", "pods", "-o", "json"); err != nil {
		return 0, 0, err
	}
	controllers := map[string]bool{owner.UID: true}
	if owner.Kind == "Deployment" {
		var sets ownerList
		if err := get(ctx, k, &sets, "-n", namespace, "get", "replicasets", "-o", "json"); err != nil {
			return 0, 0, err
		}
		for _, set := range sets.Items {
			if set.Metadata.controller().UID == owner.UID {
				controllers[set.Metadata.UID] = true
			}
		}
	}
	for _, item := range pods.Items {
		ip := gateways[item.Spec.NodeName]
		if ip == "" || item.Status.PodIP != ip || !controllers[item.Metadata.controller().UID] || item.Metadata.DeletionTimestamp != nil {
			continue
		}
		colliding++
		if deleted == limit {
			continue
		}
		pod := Pod{Namespace: namespace, Name: item.Metadata.Name, UID: item.Metadata.UID}
		if deletePod(ctx, k, pod) == nil {
			fmt.Fprintf(log, "deleted %s again: it got %s's cni0 address %s\n", pod.Key(), item.Spec.NodeName, ip)
			deleted++
		}
	}
	return deleted, colliding, nil
}

// waitReplaced waits until the pod's UID is gone and, with ready, until a pod
// of the same name is Ready again, as a StatefulSet recreates it. A
// replacement that holds its node's cni0 address is not accepted, Ready or
// not: it is deleted again, that replacement only, so the StatefulSet's order
// holds, and after three recreations the wait fails.
func waitReplaced(ctx context.Context, k Kubectl, pod Pod, ready bool, gateways map[string]string, log io.Writer, timeout time.Duration) error {
	deadline, retries := time.Now().Add(timeout), 3
	for {
		output, err := k(ctx, "-n", pod.Namespace, "get", "pod", pod.Name, "--ignore-not-found", "-o", `jsonpath={.metadata.uid} {.spec.nodeName} {.status.podIP} {.status.conditions[?(@.type=="Ready")].status}`)
		if err == nil {
			fields := strings.Fields(output)
			gone := len(fields) == 0 || fields[0] != pod.UID
			colliding := ready && gone && len(fields) >= 3 && gateways[fields[1]] != "" && fields[2] == gateways[fields[1]]
			switch {
			case colliding && retries == 0:
				return fmt.Errorf("%s still holds %s's cni0 address %s after three recreations", pod.Key(), fields[1], fields[2])
			case colliding:
				replacement := Pod{Namespace: pod.Namespace, Name: pod.Name, UID: fields[0]}
				if deletePod(ctx, k, replacement) == nil {
					fmt.Fprintf(log, "deleted %s again: it got %s's cni0 address %s\n", pod.Key(), fields[1], fields[2])
					retries--
				}
			case gone && (!ready || len(fields) == 4 && fields[3] == "True"):
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

// Unready lists Deployments, bare ReplicaSets, StatefulSets and DaemonSets
// with fewer Ready pods than they want, and Jobs that are still running or
// have failed pods.
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
	if err := get(ctx, k, &list, "get", "deployments,replicasets,statefulsets,daemonsets,jobs", "-A", "-o", "json"); err != nil {
		return nil, nil, err
	}
	for _, item := range list.Items {
		name := item.Kind + "/" + item.Metadata.Namespace + "/" + item.Metadata.Name
		s := item.Status
		switch item.Kind {
		case "ReplicaSet", "Deployment", "StatefulSet":
			// A Deployment's ReplicaSets count through the Deployment.
			if item.Kind == "ReplicaSet" && item.Metadata.controller().Kind != "" {
				continue
			}
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
	inv, err := Gather(ctx, k, opts.CNI0)
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
		if inv, err = Gather(ctx, k, opts.CNI0); err != nil {
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
	started, reported := time.Now(), time.Now()
	deadline := started.Add(timeout)
	for {
		inv, err := Gather(ctx, k, opts.CNI0)
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
		if time.Since(reported) > time.Minute {
			fmt.Fprintf(logOf(opts), "after %s still waiting: on the previous network %v, nodes without a Ready agent %v, rechecks %t, not ready %v\n", time.Since(started).Round(time.Second), left, plan.Blocked, rechecks, workloads)
			reported = time.Now()
		}
		select {
		case <-ctx.Done():
			return plan, ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
}

// CiliumTaint is the taint Cilium's operator puts on a node whose agent is
// not ready; nothing removes it once Cilium is gone.
const CiliumTaint = "node.cilium.io/agent-not-ready"

// FlannelProblems lists what still stands between the cluster and Flannel
// after a rollback: kube-flannel or kube-proxy not Ready on every node, a
// Cilium pod left, a node with Cilium's taint, and Deployments, bare
// ReplicaSets, StatefulSets or DaemonSets with fewer Ready pods than they
// want. It also returns Jobs that are running or failed.
func FlannelProblems(ctx context.Context, k Kubectl) (problems, jobs []string, err error) {
	var nodes struct {
		Items []struct {
			Metadata meta `json:"metadata"`
			Spec     struct {
				Taints []struct{ Key, Effect string } `json:"taints"`
			} `json:"spec"`
		} `json:"items"`
	}
	if err := get(ctx, k, &nodes, "get", "nodes", "-o", "json"); err != nil {
		return nil, nil, err
	}
	for _, node := range nodes.Items {
		for _, taint := range node.Spec.Taints {
			if taint.Key == CiliumTaint {
				problems = append(problems, fmt.Sprintf("node %s has %s:%s", node.Metadata.Name, taint.Key, taint.Effect))
			}
		}
	}
	var sets struct {
		Items []struct {
			Metadata meta `json:"metadata"`
			Status   struct {
				DesiredNumberScheduled, NumberReady int
			} `json:"status"`
		} `json:"items"`
	}
	if err := get(ctx, k, &sets, "-n", "kube-system", "get", "daemonsets", "-o", "json"); err != nil {
		return nil, nil, err
	}
	ready := map[string][2]int{}
	for _, set := range sets.Items {
		ready[set.Metadata.Name] = [2]int{set.Status.NumberReady, set.Status.DesiredNumberScheduled}
	}
	for _, name := range []string{"kube-flannel", "kube-proxy"} {
		counts, ok := ready[name]
		switch {
		case !ok:
			problems = append(problems, "DaemonSet kube-system/"+name+" missing")
		case counts[0] != len(nodes.Items) || counts[1] != len(nodes.Items):
			problems = append(problems, fmt.Sprintf("DaemonSet kube-system/%s ready %d/%d on %d nodes", name, counts[0], counts[1], len(nodes.Items)))
		}
	}
	var pods podList
	if err := get(ctx, k, &pods, "get", "pods", "-A", "-l", "app.kubernetes.io/part-of=cilium", "-o", "json"); err != nil {
		return nil, nil, err
	}
	for _, pod := range pods.Items {
		problems = append(problems, "Cilium pod "+pod.Metadata.Namespace+"/"+pod.Metadata.Name+" still exists")
	}
	workloads, jobs, err := Unready(ctx, k)
	if err != nil {
		return nil, nil, err
	}
	return append(problems, workloads...), jobs, nil
}

// VerifyFlannel waits until FlannelProblems finds nothing, logging what it
// waits for every minute, and lists the Jobs to check. It needs only
// read access.
func VerifyFlannel(ctx context.Context, k Kubectl, opts Options) error {
	timeout := cmp.Or(opts.Timeout, 10*time.Minute)
	started, reported := time.Now(), time.Now()
	for {
		problems, jobs, err := FlannelProblems(ctx, k)
		if err != nil {
			return err
		}
		if len(problems) == 0 {
			fmt.Fprintf(logOf(opts), "verified on Flannel: kube-flannel and kube-proxy Ready on every node, nothing of Cilium left, every workload ready\n")
			for _, job := range jobs {
				fmt.Fprintf(logOf(opts), "job to check: %s\n", job)
			}
			return nil
		}
		if time.Since(started) > timeout {
			return fmt.Errorf("not back on Flannel after %s: %s", timeout, strings.Join(problems, "; "))
		}
		if time.Since(reported) > time.Minute {
			fmt.Fprintf(logOf(opts), "after %s still waiting: %s\n", time.Since(started).Round(time.Second), strings.Join(problems, "; "))
			reported = time.Now()
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
}
