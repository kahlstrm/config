package cnipods

import (
	"context"
	"encoding/json"
	"io"
	"os"
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
			err := ClearStaleCEPs(t.Context(), k, io.Discard)
			if (err != nil) != tc.changed || deleted != tc.deletes {
				t.Fatalf("deleted=%t err=%v", deleted, err)
			}
		})
	}
}
