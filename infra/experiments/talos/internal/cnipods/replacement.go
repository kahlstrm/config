package cnipods

import (
	"context"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"
)

type deletionKey struct{}
type deletion struct{ PodUID, CEPUID, Key string }
type deletions struct {
	sync.Mutex
	items []deletion
}

func (d *deletions) snapshot() []deletion {
	d.Lock()
	defer d.Unlock()
	return append([]deletion(nil), d.items...)
}

// waitNetworkReplacement fences both sides of replacement. The old side is
// clear only when no CEP has the recorded CEP UID of the old pod or of any
// pod deleted so far, no CEP is owned by such a deleted pod, and no CEP named
// after the old pod or one of its replacements is owned by anything but the
// live pod of that name (a missing owner counts as stale too). The new side
// needs every current replacement to own a ready CEP on its current node and
// addresses. Same-name readiness alone establishes neither.
func waitNetworkReplacement(ctx context.Context, k Kubectl, old Pod, oldCEP string, initial map[string]bool, log io.Writer, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var evidence string
	for {
		report, err := Endpoints(ctx, k, nil)
		if err != nil {
			return fmt.Errorf("replacement %s UID=%s CEP UID=%s: %w; last evidence: %s", old.Key(), old.UID, oldCEP, err, evidence)
		}
		inv, err := Gather(ctx, k, nil)
		if err != nil {
			return fmt.Errorf("replacement %s UID=%s CEP UID=%s: %w; last evidence: %s", old.Key(), old.UID, oldCEP, err, evidence)
		}

		deletedPods, deletedCEPs := map[string]bool{old.UID: true}, map[string]bool{}
		if oldCEP != "" {
			deletedCEPs[oldCEP] = true
		}
		var tracked []deletion
		if t, ok := ctx.Value(deletionKey{}).(*deletions); ok {
			tracked = t.snapshot()
		}
		for _, d := range tracked {
			deletedPods[d.PodUID] = true
			if d.CEPUID != "" {
				deletedCEPs[d.CEPUID] = true
			}
		}

		live := map[string]string{} // pod key -> UID of the live pod with that name
		names := map[string]bool{old.Key(): true}
		replacement, allReady := false, true
		for _, p := range inv.Pods {
			if !p.Terminating {
				live[p.Key()] = p.UID
			}
			selected := p.Namespace == old.Namespace && p.Owner == old.Owner
			if old.Owner.Kind == "StatefulSet" || old.Owner.Kind == "" {
				selected = p.Key() == old.Key()
			}
			if old.Owner.Kind == "DaemonSet" {
				selected = selected && p.Node == old.Node
			}
			if !selected || p.Terminating || (initial[p.UID] && p.UID != old.UID) {
				continue
			}
			names[p.Key()] = true
			if p.UID != old.UID {
				replacement = true
			}
			if !p.Ready || !report.ReadyUIDs[p.UID] {
				allReady = false
			}
		}

		blocking := []string{}
		for _, e := range report.Endpoints {
			key := e.Metadata.Namespace + "/" + e.Metadata.Name
			owner := e.ownerUID()
			switch {
			case deletedCEPs[e.Metadata.UID]:
				blocking = append(blocking, "recorded CEP of a deleted pod still exists: "+e.evidence())
			case owner != "" && deletedPods[owner]:
				blocking = append(blocking, "CEP owned by a deleted pod: "+e.evidence())
			case names[key] && (owner == "" || owner != live[key]):
				blocking = append(blocking, "same-name CEP not owned by the live pod: "+e.evidence())
			}
		}
		clear := len(blocking) == 0

		evidence = fmt.Sprintf("old pod=%s UID=%s old CEP UID=%s old CEP gone=%t replacement=%t all ready=%t\n", old.Key(), old.UID, oldCEP, clear, replacement, allReady)
		if !clear {
			evidence += "blocking CEPs:\n  " + strings.Join(blocking, "\n  ") + "\n"
		}
		evidence += report.String()
		if len(tracked) > 0 {
			evidence += fmt.Sprintf("\ndeleted Pod UID, CEP UID, pod key: %v", tracked)
		}
		if clear && replacement && allReady {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("replacement network wait: %w: %s", ctx.Err(), evidence)
		case <-time.After(2 * time.Second):
		}
	}
}
