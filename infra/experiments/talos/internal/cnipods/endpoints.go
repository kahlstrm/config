package cnipods

import (
	"context"
	"fmt"
	"slices"
	"strings"
)

// EndpointReport joins CiliumEndpoints to the pods that should have one:
// running, not on the host network and not terminating. Health and other
// endpoints without such a pod are listed apart, so they never make a
// node's counts look complete.
type EndpointReport struct {
	// Nodes counts, per node, the selected pods and their ready endpoints
	// on that node.
	Nodes map[string]NodeEndpoints
	// Missing lists selected pods without an endpoint; Allowed those of
	// them the caller expects, such as report-only pods left alone.
	Missing, Allowed []string
	// NotReady lists pods whose endpoint is not ready, with its state.
	NotReady []string
	// Misplaced lists pods whose endpoint is on another node.
	Misplaced []string
	// Health lists Cilium's own health endpoints (kube-system/cilium-health-*).
	Health []string
	// Stale lists other endpoints without a selected pod.
	Stale []string
}

// NodeEndpoints is one node's pods and ready endpoints.
type NodeEndpoints struct{ Pods, Ready int }

// Problems lists what fails the reconciliation: missing endpoints not
// allowed, endpoints not ready or on the wrong node, stale endpoints, and
// nodes whose counts differ.
func (r EndpointReport) Problems() []string {
	problems := []string{}
	for _, key := range r.Missing {
		problems = append(problems, "no CiliumEndpoint for "+key)
	}
	for _, line := range r.NotReady {
		problems = append(problems, "endpoint not ready: "+line)
	}
	for _, line := range r.Misplaced {
		problems = append(problems, "endpoint on another node: "+line)
	}
	for _, key := range r.Stale {
		problems = append(problems, "endpoint without a running pod: "+key)
	}
	for _, node := range slicesSortedKeys(r.Nodes) {
		if n := r.Nodes[node]; n.Pods != n.Ready {
			problems = append(problems, fmt.Sprintf("node %s: %d pods, %d ready endpoints", node, n.Pods, n.Ready))
		}
	}
	return problems
}

func (r EndpointReport) String() string {
	var b strings.Builder
	b.WriteString("node pods ready-endpoints\n")
	for _, node := range slicesSortedKeys(r.Nodes) {
		fmt.Fprintf(&b, "%s %d %d\n", node, r.Nodes[node].Pods, r.Nodes[node].Ready)
	}
	for _, section := range []struct {
		title string
		lines []string
	}{{"allowed without an endpoint", r.Allowed}, {"health endpoints", r.Health}} {
		for _, line := range section.lines {
			fmt.Fprintf(&b, "%s: %s\n", section.title, line)
		}
	}
	for _, problem := range r.Problems() {
		fmt.Fprintf(&b, "PROBLEM: %s\n", problem)
	}
	return b.String()
}

// Endpoints reads pods, nodes and CiliumEndpoints and joins them. allowed
// lists pod keys, namespace/pod, expected to lack an endpoint.
func Endpoints(ctx context.Context, k Kubectl, allowed []string) (EndpointReport, error) {
	report := EndpointReport{Nodes: map[string]NodeEndpoints{}}
	var nodes struct {
		Items []struct {
			Metadata meta `json:"metadata"`
			Status   struct {
				Addresses []struct{ Type, Address string } `json:"addresses"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := get(ctx, k, &nodes, "get", "nodes", "-o", "json"); err != nil {
		return report, err
	}
	nodeOf := map[string]string{}
	for _, node := range nodes.Items {
		for _, address := range node.Status.Addresses {
			if address.Type == "InternalIP" {
				nodeOf[address.Address] = node.Metadata.Name
			}
		}
	}
	var pods podList
	if err := get(ctx, k, &pods, "get", "pods", "-A", "-o", "json"); err != nil {
		return report, err
	}
	selected := map[string]string{} // pod key -> node
	for _, pod := range pods.Items {
		if pod.Spec.HostNetwork || pod.Status.Phase != "Running" || pod.Metadata.DeletionTimestamp != nil {
			continue
		}
		selected[pod.Metadata.Namespace+"/"+pod.Metadata.Name] = pod.Spec.NodeName
	}
	var endpoints struct {
		Items []struct {
			Metadata meta `json:"metadata"`
			Status   struct {
				State      string `json:"state"`
				Networking struct {
					Node string `json:"node"`
				} `json:"networking"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := get(ctx, k, &endpoints, "get", "ciliumendpoints.cilium.io", "-A", "-o", "json"); err != nil {
		return report, fmt.Errorf("reading CiliumEndpoints, which needs a cluster administrator: %w", err)
	}
	found := map[string]bool{}
	for _, e := range endpoints.Items {
		key := e.Metadata.Namespace + "/" + e.Metadata.Name
		node, ok := selected[key]
		switch {
		case !ok && e.Metadata.Namespace == "kube-system" && strings.HasPrefix(e.Metadata.Name, "cilium-health-"):
			report.Health = append(report.Health, key+" "+e.Status.State)
		case !ok:
			report.Stale = append(report.Stale, key)
		case nodeOf[e.Status.Networking.Node] != node:
			found[key] = true
			report.Misplaced = append(report.Misplaced, fmt.Sprintf("%s pod on %s, endpoint on %s", key, node, e.Status.Networking.Node))
		case e.Status.State != "ready":
			found[key] = true
			report.NotReady = append(report.NotReady, key+" "+e.Status.State)
		default:
			found[key] = true
			n := report.Nodes[node]
			n.Ready++
			report.Nodes[node] = n
		}
	}
	for key, node := range selected {
		n := report.Nodes[node]
		n.Pods++
		report.Nodes[node] = n
		switch {
		case found[key]:
		case slices.Contains(allowed, key):
			report.Allowed = append(report.Allowed, key)
			// An allowed pod counts on neither side.
			n.Pods--
			report.Nodes[node] = n
		default:
			report.Missing = append(report.Missing, key)
		}
	}
	for _, list := range [][]string{report.Missing, report.Allowed, report.NotReady, report.Misplaced, report.Health, report.Stale} {
		slices.Sort(list)
	}
	return report, nil
}
