package cnipods

import (
	"slices"
	"testing"
	"time"
)

// A pod Cilium networks but whose endpoint never syncs (its agent lost the
// create's response) has a CiliumEndpoint, so it is no candidate; naming it
// with -include recreates it by its owner.
func TestIncludeAddsAPodOnCilium(t *testing.T) {
	pods := slices.DeleteFunc(cluster(), func(p podSpec) bool { return p.node == "w3" })
	f := &fake{pods: pods, endpoints: []string{"web/on-cilium", "web/on-gateway"}, replaced: map[string]bool{}}
	inv, err := Gather(t.Context(), f.kubectl(t), nil)
	if err != nil {
		t.Fatal(err)
	}
	inv.Taken = after.Add(time.Hour)
	plan, err := Classify(inv).Include(inv, []string{"web/on-cilium", "default/standalone"})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Candidate{}
	for _, c := range plan.Candidates {
		got[c.Key()] = c
	}
	if c, ok := got["web/on-cilium"]; !ok || c.Action != Delete || c.Reason != Included {
		t.Errorf("web/on-cilium: got %+v, want an included Delete candidate", c)
	}
	// Already a candidate: kept as classified.
	if c := got["default/standalone"]; c.Action != Report || c.Reason != OnPrevious {
		t.Errorf("default/standalone: got %+v, want it as classified", c)
	}
	for _, bad := range []string{"web/missing", "kube-system/cilium-a", "web/terminating", "pocket-id/pocket-id-sync-1"} {
		if _, err := Classify(inv).Include(inv, []string{bad}); err == nil {
			t.Errorf("%s: included, want an error", bad)
		}
	}
}
