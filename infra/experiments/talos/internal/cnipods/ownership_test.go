package cnipods

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestSameNameCEPRequiresCurrentPodUID(t *testing.T) {
	for _, uid := range []string{"uid-web-a", "old-pod", ""} {
		t.Run(uid, func(t *testing.T) {
			k := func(ctx context.Context, args ...string) (string, error) {
				if args[1] == "ciliumendpoints.cilium.io" {
					return list(cepObject("web", "web-a", uid, "10.0.0.1", "10.244.1.77")), nil
				}
				return endpointCluster("ready", "10.0.0.2", false)(ctx, args...)
			}
			r, err := Endpoints(t.Context(), k, nil)
			if err != nil {
				t.Fatal(err)
			}
			if r.ReadyUIDs["uid-web-a"] != (uid == "uid-web-a") {
				t.Fatalf("accepted ownership %q: %s", uid, r)
			}
			if uid != "uid-web-a" && (len(r.Ownership) != 1 || !strings.Contains(r.Ownership[0], "CEP UID=cep-web-a")) {
				t.Fatalf("missing stale evidence: %s", r)
			}
		})
	}
}

func TestCEPRequiresCurrentAddresses(t *testing.T) {
	for _, ip := range []string{"10.244.1.77", "10.244.1.99", ""} {
		k := func(ctx context.Context, args ...string) (string, error) {
			if args[1] == "ciliumendpoints.cilium.io" {
				return list(cepObject("web", "web-a", "uid-web-a", "10.0.0.1", ip)), nil
			}
			return endpointCluster("ready", "10.0.0.2", false)(ctx, args...)
		}
		r, err := Endpoints(t.Context(), k, nil)
		if err != nil {
			t.Fatal(err)
		}
		if r.ReadyUIDs["uid-web-a"] != (ip == "10.244.1.77") {
			t.Fatalf("accepted IP %q: %s", ip, r)
		}
	}
}

func TestReplacementWaitRequiresOldCEPGone(t *testing.T) {
	f := &fake{pods: []podSpec{{namespace: "web", name: "db-0", node: "w1", owner: [2]string{"StatefulSet", "db"}}}, endpoints: []string{}, replaced: map[string]bool{"web/db-0": true}}
	base := f.kubectl(t)
	old := Pod{Namespace: "web", Name: "db-0", UID: "old-pod", Owner: Owner{Kind: "StatefulSet", Name: "db", UID: "uid-db"}}
	for _, lingering := range []bool{true, false} {
		k := func(ctx context.Context, args ...string) (string, error) {
			if lingering && strings.Join(args, " ") == "get ciliumendpoints.cilium.io -A -o json" {
				return list(cepObject("web", "db-0", "uid-new-db-0", "10.10.10.21", "10.244.1.77"), cepObject("web", "old-name", "old-pod", "10.10.10.21", "10.244.1.76")), nil
			}
			return base(ctx, args...)
		}
		err := waitNetworkReplacement(t.Context(), k, old, "", map[string]bool{"old-pod": true}, io.Discard, 20*time.Millisecond)
		if (err != nil) != lingering {
			t.Fatalf("lingering=%t: %v", lingering, err)
		}
		if lingering && !strings.Contains(err.Error(), "old CEP gone=false") {
			t.Fatal(err)
		}
	}
}

func TestStaleCEPBlocksNextStatefulSetOrdinal(t *testing.T) {
	f := &fake{endpoints: []string{}, replaced: map[string]bool{}, pods: []podSpec{
		{namespace: "web", name: "db-0", node: "w1", owner: [2]string{"StatefulSet", "db"}},
		{namespace: "web", name: "db-1", node: "w1", owner: [2]string{"StatefulSet", "db"}},
	}}
	base := f.kubectl(t)
	k := func(ctx context.Context, args ...string) (string, error) {
		out, err := base(ctx, args...)
		if strings.Join(args, " ") == "get ciliumendpoints.cilium.io -A -o json" {
			var objects map[string][]any
			if err := json.Unmarshal([]byte(out), &objects); err != nil {
				t.Fatal(err)
			}
			objects["items"] = append(objects["items"], cepObject("web", "old-db-1", "uid-db-1", "10.10.10.21", "10.244.1.76"))
			data, _ := json.Marshal(objects)
			out = string(data)
		}
		return out, err
	}
	plan := Plan{Signal: SignalEndpoints}
	for _, p := range f.pods {
		plan.Candidates = append(plan.Candidates, Candidate{Pod: Pod{Namespace: p.namespace, Name: p.name, UID: "uid-" + p.name, Node: p.node, Owner: Owner{Kind: "StatefulSet", Name: "db", UID: "uid-db"}}, Action: Sequential})
	}
	if err := Recreate(t.Context(), k, plan, Options{Timeout: 20 * time.Millisecond}); err == nil {
		t.Fatal("accepted lingering CEP")
	}
	if !f.replaced["web/db-1"] || f.replaced["web/db-0"] {
		t.Fatalf("advanced past blocked ordinal: %v", f.replaced)
	}
}

func TestClearStaleCEPsUsesPreconditionsAndRefusesUnproven(t *testing.T) {
	for _, tc := range []struct {
		name, owner            string
		live, changed, deletes bool
	}{
		{"gone", "old", false, false, true}, {"same-name-replaced", "old", true, false, true},
		{"current", "uid-db-0", true, false, false}, {"missing-owner", "", false, false, false},
		{"changed", "old", false, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			deleted := false
			k := func(_ context.Context, args ...string) (string, error) {
				obj := cepObject("web", "db-0", tc.owner, "10.0.0.1", "10.244.1.77")
				switch {
				case args[0] == "delete":
					data, err := os.ReadFile(args[4])
					if err != nil {
						t.Fatal(err)
					}
					var options struct {
						Preconditions struct{ UID, ResourceVersion string }
					}
					if err := json.Unmarshal(data, &options); err != nil {
						t.Fatal(err)
					}
					if options.Preconditions.UID != "cep-db-0" || options.Preconditions.ResourceVersion != "123" {
						t.Fatalf("unsafe preconditions: %s", data)
					}
					deleted = true
					return "", nil
				case args[0] == "get":
					return list(obj), nil
				case args[3] == "pods":
					if tc.live {
						return list(podSpec{namespace: "web", name: "db-0"}.object()), nil
					}
					return list(), nil
				default:
					if tc.changed {
						obj["metadata"].(map[string]any)["resourceVersion"] = "124"
					}
					data, _ := json.Marshal(obj)
					return string(data), nil
				}
			}
			err := ClearStaleCEPs(t.Context(), k, nil, io.Discard)
			// Changed and ownerless CEPs are unresolved suspects: an error.
			if (err != nil) != (tc.changed || tc.owner == "") || deleted != tc.deletes {
				t.Fatalf("deleted=%t err=%v", deleted, err)
			}
		})
	}
}

// deploymentReplaced answers the queries of a wait for web/web-a, a
// Deployment pod deleted and replaced by web/web-b, which owns a ready CEP.
// retained, if set, adds a CEP named web-a with that owner UID ("none" for
// no owner reference): a stale same-name CEP of an earlier pod.
func deploymentReplaced(retained string) Kubectl {
	return func(_ context.Context, args ...string) (string, error) {
		switch strings.Join(args, " ") {
		case "get nodes -o json":
			return list(map[string]any{"metadata": map[string]any{"name": "w1"}, "status": map[string]any{"addresses": []any{map[string]any{"type": "InternalIP", "address": "10.10.10.21"}}}}), nil
		case "get pods -A -o json":
			pod := podSpec{namespace: "web", name: "web-b", node: "w1", owner: [2]string{"ReplicaSet", "web-rs"}, sandbox: after, ready: true}.object()
			status := pod["status"].(map[string]any)
			status["hostIP"], status["podIP"], status["podIPs"] = "10.10.10.21", "10.244.1.80", []any{map[string]any{"ip": "10.244.1.80"}}
			return list(pod), nil
		case "get replicasets,jobs -A -o json":
			return list(map[string]any{"kind": "ReplicaSet", "metadata": map[string]any{"uid": "uid-web-rs", "ownerReferences": []any{map[string]any{"kind": "Deployment", "name": "web", "uid": "uid-web", "controller": true}}}}), nil
		case "get ciliumendpoints.cilium.io -A -o json":
			items := []any{cepObject("web", "web-b", "uid-web-b", "10.10.10.21", "10.244.1.80")}
			switch retained {
			case "":
			case "none":
				stale := cepObject("web", "web-a", "", "10.10.10.21", "10.244.1.70")
				stale["metadata"].(map[string]any)["ownerReferences"] = []any{}
				items = append(items, stale)
			default:
				items = append(items, cepObject("web", "web-a", retained, "10.10.10.21", "10.244.1.70"))
			}
			return list(items...), nil
		}
		return "", fmt.Errorf("unexpected kubectl %v", args)
	}
}

func TestRetainedSameNameCEPBlocksAHealthyDeploymentReplacement(t *testing.T) {
	old := Pod{Namespace: "web", Name: "web-a", UID: "uid-web-a", Node: "w1", Owner: Owner{Kind: "Deployment", Name: "web", UID: "uid-web"}}
	// Without a retained CEP the healthy replacement is accepted.
	if err := waitNetworkReplacement(t.Context(), deploymentReplaced(""), old, "cep-web-a", map[string]bool{"uid-web-a": true}, io.Discard, time.Second); err != nil {
		t.Fatalf("healthy replacement refused: %v", err)
	}
	// A CEP named after the old pod, owned by an earlier pod or by nothing,
	// keeps the old side open even though no CEP is owned by the deleted UID.
	for _, owner := range []string{"uid-earlier-pod", "none"} {
		err := waitNetworkReplacement(t.Context(), deploymentReplaced(owner), old, "", map[string]bool{"uid-web-a": true}, io.Discard, 50*time.Millisecond)
		if err == nil || !strings.Contains(err.Error(), "old CEP gone=false") || !strings.Contains(err.Error(), "same-name CEP not owned by the live pod: web/web-a") {
			t.Errorf("retained CEP owned by %q: got %v", owner, err)
		}
	}
	// The recorded CEP UID blocks on its own, whoever owns it now.
	err := waitNetworkReplacement(t.Context(), deploymentReplaced("uid-earlier-pod"), Pod{Namespace: "web", Name: "web-z", UID: "uid-web-z", Owner: old.Owner}, "cep-web-a", map[string]bool{"uid-web-z": true}, io.Discard, 50*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "recorded CEP of a deleted pod still exists") {
		t.Errorf("recorded CEP UID present: got %v", err)
	}
}

// staleCluster holds, in namespace web: a healthy CEP (owner pod live), two
// stale ones (owner pods gone), of which the API server rejects deleting
// stale-b by precondition, and an ownerless one.
func staleCluster(t *testing.T, deleted *[]string) Kubectl {
	objects := map[string]map[string]any{
		"healthy": cepObject("web", "healthy", "uid-live", "10.0.0.1", "10.244.1.1"),
		"stale-a": cepObject("web", "stale-a", "uid-gone-a", "10.0.0.1", "10.244.1.2"),
		"stale-b": cepObject("web", "stale-b", "uid-gone-b", "10.0.0.1", "10.244.1.3"),
		"orphan":  cepObject("web", "orphan", "", "10.0.0.1", "10.244.1.4"),
	}
	objects["orphan"]["metadata"].(map[string]any)["ownerReferences"] = []any{}
	return func(_ context.Context, args ...string) (string, error) {
		switch {
		case strings.Join(args, " ") == "get ciliumendpoints.cilium.io -A -o json":
			return list(objects["healthy"], objects["stale-a"], objects["stale-b"], objects["orphan"]), nil
		case strings.Join(args, " ") == "-n web get pods -o json":
			live := podSpec{namespace: "web", name: "live"}.object()
			live["metadata"].(map[string]any)["uid"] = "uid-live"
			return list(live), nil
		case len(args) > 4 && args[2] == "get" && args[3] == "ciliumendpoints.cilium.io":
			data, _ := json.Marshal(objects[args[4]])
			return string(data), nil
		case args[0] == "delete":
			name := args[2][strings.LastIndex(args[2], "/")+1:]
			if name == "stale-b" {
				return "", fmt.Errorf("Error from server (Conflict): Operation cannot be fulfilled on ciliumendpoints.cilium.io \"stale-b\": Precondition failed: ResourceVersion in precondition: 123, ResourceVersion in object meta: 124")
			}
			*deleted = append(*deleted, name)
			return "", nil
		}
		t.Fatalf("unexpected kubectl %v", args)
		return "", nil
	}
}

func TestClearStaleCEPsClassifiesAMixedListAndCarriesOn(t *testing.T) {
	var deleted []string
	var log strings.Builder
	err := ClearStaleCEPs(t.Context(), staleCluster(t, &deleted), nil, &log)
	if !slices.Equal(deleted, []string{"stale-a"}) {
		t.Errorf("deleted %v, want only stale-a", deleted)
	}
	out := log.String()
	for _, want := range []string{
		"healthy: owner pod exists, skipped: web/healthy",
		"cleared: owner pod gone: web/stale-a",
		"unresolved: delete rejected: Error from server (Conflict)",
		"unresolved: no Pod owner reference, not proof of staleness: web/orphan",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "web/healthy") && strings.Contains(out, "unresolved: no Pod owner reference, not proof of staleness: web/healthy") {
		t.Errorf("healthy CEP reported as unresolved:\n%s", out)
	}
	if err == nil || !strings.Contains(err.Error(), "2 CEPs unresolved: web/stale-b web/orphan") {
		t.Errorf("got %v", err)
	}
}

func TestClearStaleCEPsTouchesOnlySelectedCEPs(t *testing.T) {
	var deleted []string
	var log strings.Builder
	if err := ClearStaleCEPs(t.Context(), staleCluster(t, &deleted), []string{"web/stale-a"}, &log); err != nil {
		t.Fatalf("%v\n%s", err, log.String())
	}
	if !slices.Equal(deleted, []string{"stale-a"}) || strings.Contains(log.String(), "orphan") || strings.Contains(log.String(), "stale-b") {
		t.Errorf("deleted %v, log:\n%s", deleted, log.String())
	}
	err := ClearStaleCEPs(t.Context(), staleCluster(t, &deleted), []string{"web/missing"}, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "web/missing") {
		t.Errorf("a missing selected CEP: got %v", err)
	}
}
