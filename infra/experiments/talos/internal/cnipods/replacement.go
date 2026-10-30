package cnipods

import (
	"context"
	"fmt"
	"io"
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

// waitNetworkReplacement fences both sides of replacement: all CEPs owned
// by the deleted UID must disappear, and current replacement pods must own
// ready CEPs with their current node and addresses. Same-name readiness
// alone cannot establish either condition.
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
		clear, replacement, allReady := true, false, true
		for _, e := range report.Endpoints {
			if e.ownedBy(old.UID) {
				clear = false
			}
			if tracked, ok := ctx.Value(deletionKey{}).(*deletions); ok {
				for _, deleted := range tracked.snapshot() {
					if e.ownedBy(deleted.PodUID) {
						clear = false
					}
				}
			}
		}
		for _, p := range inv.Pods {
			selected := p.Namespace == old.Namespace && p.Owner == old.Owner
			if old.Owner.Kind == "StatefulSet" || old.Owner.Kind == "" {
				selected = p.Key() == old.Key()
			}
			if old.Owner.Kind == "DaemonSet" {
				selected = selected && p.Node == old.Node
			}
			if !selected || p.Terminating {
				continue
			}
			if initial[p.UID] && p.UID != old.UID {
				continue
			}
			if !initial[p.UID] && p.UID != old.UID {
				replacement = true
			}
			if !p.Ready || !report.ReadyUIDs[p.UID] {
				allReady = false
			}
		}
		evidence = fmt.Sprintf("old pod=%s UID=%s old CEP UID=%s old CEP gone=%t replacement=%t all ready=%t\n%s", old.Key(), old.UID, oldCEP, clear, replacement, allReady, report)
		if tracked, ok := ctx.Value(deletionKey{}).(*deletions); ok {
			evidence += fmt.Sprintf("\ndeleted Pod UID, CEP UID, pod key: %v", tracked.snapshot())
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
