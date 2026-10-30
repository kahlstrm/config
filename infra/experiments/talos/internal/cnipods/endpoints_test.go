package cnipods

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
)

// endpointCluster answers Endpoints' queries: w1 (10.0.0.1) runs web-a, the
// report-only job pod and a host-network pod; w2 (10.0.0.2) runs web-b and a
// finished pod. The endpoints include a health endpoint and a stale one.
func endpointCluster(webBState, webBNode string, jobEndpoint bool) Kubectl {
	return func(_ context.Context, args ...string) (string, error) {
		switch strings.Join(args, " ") {
		case "get nodes -o json":
			return list(
				map[string]any{"metadata": map[string]any{"name": "w1"}, "status": map[string]any{"addresses": []any{map[string]any{"type": "InternalIP", "address": "10.0.0.1"}}}},
				map[string]any{"metadata": map[string]any{"name": "w2"}, "status": map[string]any{"addresses": []any{map[string]any{"type": "InternalIP", "address": "10.0.0.2"}}}},
			), nil
		case "get pods -A -o json":
			return list(
				endpointPod("web", "web-a", "w1", "10.0.0.1"),
				endpointPod("web", "web-b", "w2", "10.0.0.2"),
				endpointPod("jobs", "sync-x", "w1", "10.0.0.1"),
				podSpec{namespace: "kube-system", name: "cilium-a", node: "w1", hostNetwork: true}.object(),
				podSpec{namespace: "jobs", name: "done", node: "w2", phase: "Succeeded"}.object(),
			), nil
		case "get ciliumendpoints.cilium.io -A -o json":
			endpoint := func(key, state, node string) any {
				namespace, name, _ := strings.Cut(key, "/")
				obj := cepObject(namespace, name, "uid-"+name, node, "10.244.1.77")
				obj["status"].(map[string]any)["state"] = state
				return obj
			}
			items := []any{
				endpoint("web/web-a", "ready", "10.0.0.1"),
				endpoint("web/web-b", webBState, webBNode),
				endpoint("kube-system/cilium-health-w1", "ready", "10.0.0.1"),
				endpoint("kube-system/cilium-health-w2", "ready", "10.0.0.2"),
				endpoint("web/gone", "ready", "10.0.0.2"),
			}
			if jobEndpoint {
				items = append(items, endpoint("jobs/sync-x", "ready", "10.0.0.1"))
			}
			return list(items...), nil
		}
		return "", fmt.Errorf("unexpected kubectl %v", args)
	}
}

func TestEndpointsJoinPodsBeforeCounting(t *testing.T) {
	report, err := Endpoints(t.Context(), endpointCluster("ready", "10.0.0.2", false), []string{"jobs/sync-x"})
	if err != nil {
		t.Fatal(err)
	}
	// Health endpoints count on neither side; the allowed job pod neither.
	if report.Nodes["w1"] != (NodeEndpoints{Pods: 1, Ready: 1}) || report.Nodes["w2"] != (NodeEndpoints{Pods: 1, Ready: 1}) {
		t.Errorf("nodes %+v", report.Nodes)
	}
	if !slices.Equal(report.Health, []string{"kube-system/cilium-health-w1 ready", "kube-system/cilium-health-w2 ready"}) {
		t.Errorf("health %v", report.Health)
	}
	if !slices.Equal(report.Allowed, []string{"jobs/sync-x"}) {
		t.Errorf("allowed %v", report.Allowed)
	}
	// The stale endpoint is the only problem.
	if problems := report.Problems(); !slices.Equal(problems, []string{"endpoint without a running pod: web/gone"}) {
		t.Errorf("problems %v", problems)
	}
}

func TestEndpointsReportEachMismatch(t *testing.T) {
	report, err := Endpoints(t.Context(), endpointCluster("waiting-for-identity", "10.0.0.2", false), nil)
	if err != nil {
		t.Fatal(err)
	}
	problems := strings.Join(report.Problems(), "\n")
	for _, want := range []string{"no CiliumEndpoint for jobs/sync-x", "endpoint not ready: web/web-b waiting-for-identity", "node w2: 1 pods, 0 ready endpoints", "node w1: 2 pods, 1 ready endpoints"} {
		if !strings.Contains(problems, want) {
			t.Errorf("problems lack %q:\n%s", want, problems)
		}
	}
	report, err = Endpoints(t.Context(), endpointCluster("ready", "10.0.0.1", true), nil)
	if err != nil {
		t.Fatal(err)
	}
	if problems := strings.Join(report.Problems(), "\n"); !strings.Contains(problems, "endpoint on another node: web/web-b pod on w2, endpoint on 10.0.0.1") {
		t.Errorf("misplaced endpoint not reported:\n%s", problems)
	}
}

func TestEndpointsNeedEndpointAccess(t *testing.T) {
	k := func(ctx context.Context, args ...string) (string, error) {
		if args[1] == "ciliumendpoints.cilium.io" {
			return "", fmt.Errorf("Error from server (Forbidden): ciliumendpoints.cilium.io is forbidden")
		}
		return endpointCluster("ready", "10.0.0.2", false)(ctx, args...)
	}
	if _, err := Endpoints(t.Context(), k, nil); err == nil || !strings.Contains(err.Error(), "cluster administrator") {
		t.Errorf("got %v", err)
	}
}

func cepObject(ns, name, owner, node, ip string) map[string]any {
	return map[string]any{"metadata": map[string]any{"namespace": ns, "name": name, "uid": "cep-" + name + map[bool]string{true: "-new"}[strings.HasPrefix(owner, "uid-new-")], "resourceVersion": "123", "ownerReferences": []any{map[string]any{"kind": "Pod", "name": name, "uid": owner}}}, "status": map[string]any{"state": "ready", "networking": map[string]any{"node": node, "addressing": []any{map[string]any{"ipv4": ip}}}}}
}
func endpointPod(ns, name, node, host string) map[string]any {
	obj := podSpec{namespace: ns, name: name, node: node}.object()
	obj["status"].(map[string]any)["hostIP"] = host
	return obj
}
