package lab

import (
	"os"
	"testing"
)

// Cilium 1.20's endpoint list carries no pod name in its external
// identifiers, only the CNI attachment; the pod is named by the endpoint's
// label-resolution controller.
func TestAgentEndpointsNamePods(t *testing.T) {
	raw, err := os.ReadFile("testdata/cilium-1.20-endpoints.json")
	if err != nil {
		t.Fatal(err)
	}
	endpoints, err := AgentEndpoints(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(endpoints) != 2 {
		t.Fatalf("got %d endpoints, want 2", len(endpoints))
	}
	pod, other := endpoints[0], endpoints[1]
	if pod.ID != 1034 || pod.Namespace != "mig-app" || pod.Pod != "data-b4467747-cpd44" || pod.State != "ready" {
		t.Errorf("got %+v, want endpoint 1034 for mig-app/data-b4467747-cpd44, ready", pod)
	}
	if pod.Container != "99ee823283ddcf2b1594977e5919fae55408c9587ca598b87e900d4ba78168b8:eth0" {
		t.Errorf("got container %q", pod.Container)
	}
	if other.ID != 128 || other.Namespace != "" || other.Pod != "" {
		t.Errorf("got %+v, want endpoint 128 without a pod", other)
	}
}
