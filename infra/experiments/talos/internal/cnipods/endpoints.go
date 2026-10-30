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
	Misplaced            []string
	Ownership, Addresses []string
	ReadyUIDs            map[string]bool
	Endpoints            []endpoint
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
	for _, line := range append(slices.Clone(r.Ownership), r.Addresses...) {
		problems = append(problems, line)
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
	report := EndpointReport{Nodes: map[string]NodeEndpoints{}, ReadyUIDs: map[string]bool{}}
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
	selected := map[string]selectedPod{}
	for _, pod := range pods.Items {
		if pod.Spec.HostNetwork || pod.Status.Phase != "Running" || pod.Metadata.DeletionTimestamp != nil {
			continue
		}
		ips := []string{}
		for _, ip := range pod.Status.PodIPs {
			ips = append(ips, ip.IP)
		}
		if len(ips) == 0 && pod.Status.PodIP != "" {
			ips = append(ips, pod.Status.PodIP)
		}
		selected[pod.Metadata.Namespace+"/"+pod.Metadata.Name] = selectedPod{pod.Metadata.UID, pod.Spec.NodeName, pod.Status.HostIP, ips}
	}
	var endpoints endpointList
	if err := get(ctx, k, &endpoints, "get", "ciliumendpoints.cilium.io", "-A", "-o", "json"); err != nil {
		return report, fmt.Errorf("reading CiliumEndpoints, which needs a cluster administrator: %w", err)
	}
	report.Endpoints = endpoints.Items
	found := map[string]bool{}
	for _, e := range endpoints.Items {
		key := e.Metadata.Namespace + "/" + e.Metadata.Name
		pod, ok := selected[key]
		node := pod.Node
		switch {
		case !ok && e.Metadata.Namespace == "kube-system" && strings.HasPrefix(e.Metadata.Name, "cilium-health-"):
			report.Health = append(report.Health, key+" "+e.Status.State)
		case !ok:
			report.Stale = append(report.Stale, key)
		case !e.ownedBy(pod.UID):
			report.Ownership = append(report.Ownership, "stale endpoint ownership: "+e.evidence())
		case nodeOf[e.Status.Networking.Node] != node:
			found[key] = true
			report.Misplaced = append(report.Misplaced, fmt.Sprintf("%s pod on %s, endpoint on %s", key, node, e.Status.Networking.Node))
		case !e.addressesMatch(pod):
			found[key] = true
			report.Addresses = append(report.Addresses, "endpoint addresses differ from pod: "+e.evidence())
		case e.Status.State != "ready":
			found[key] = true
			report.NotReady = append(report.NotReady, key+" "+e.Status.State)
		default:
			found[key] = true
			report.ReadyUIDs[pod.UID] = true
			n := report.Nodes[node]
			n.Ready++
			report.Nodes[node] = n
		}
	}
	for key, pod := range selected {
		node := pod.Node
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
	for _, list := range [][]string{report.Missing, report.Allowed, report.NotReady, report.Misplaced, report.Health, report.Stale, report.Ownership, report.Addresses} {
		slices.Sort(list)
	}
	return report, nil
}

type selectedPod struct {
	UID, Node, HostIP string
	IPs               []string
}
type endpointList struct {
	Items []endpoint `json:"items"`
}
type endpoint struct {
	Metadata meta `json:"metadata"`
	Status   struct {
		State      string `json:"state"`
		Networking struct {
			Node       string `json:"node"`
			Addressing []struct {
				IPV4 string `json:"ipv4"`
				IPV6 string `json:"ipv6"`
			} `json:"addressing"`
		} `json:"networking"`
	} `json:"status"`
}

func (e endpoint) ownerUID() string {
	uid := ""
	for _, ref := range e.Metadata.OwnerReferences {
		if ref.Kind == "Pod" {
			if uid != "" {
				return ""
			}
			uid = ref.UID
		}
	}
	return uid
}
func (e endpoint) ownedBy(uid string) bool { return uid != "" && e.ownerUID() == uid }
func (e endpoint) evidence() string {
	return fmt.Sprintf("%s/%s CEP UID=%s owner UID=%s node=%s", e.Metadata.Namespace, e.Metadata.Name, e.Metadata.UID, e.ownerUID(), e.Status.Networking.Node)
}
func (e endpoint) addressesMatch(p selectedPod) bool {
	if p.HostIP == "" || e.Status.Networking.Node != p.HostIP || len(p.IPs) == 0 {
		return false
	}
	ips := []string{}
	for _, a := range e.Status.Networking.Addressing {
		if a.IPV4 != "" {
			ips = append(ips, a.IPV4)
		}
		if a.IPV6 != "" {
			ips = append(ips, a.IPV6)
		}
	}
	slices.Sort(ips)
	want := slices.Clone(p.IPs)
	slices.Sort(want)
	return slices.Equal(ips, want)
}
