package cnipods

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

// ClearStaleCEPs is an explicit operator action, never part of recreation.
// Missing ownership is not proof of staleness. Re-read both objects before
// deleting, and let the API server protect against subsequent CEP changes.
func ClearStaleCEPs(ctx context.Context, k Kubectl, log io.Writer) error {
	var endpoints endpointList
	if err := get(ctx, k, &endpoints, "get", "ciliumendpoints.cilium.io", "-A", "-o", "json"); err != nil {
		return err
	}
	for _, candidate := range endpoints.Items {
		if candidate.Metadata.Namespace == "kube-system" && strings.HasPrefix(candidate.Metadata.Name, "cilium-health-") {
			continue
		}
		var current endpoint
		m := candidate.Metadata
		if err := get(ctx, k, &current, "-n", m.Namespace, "get", "ciliumendpoints.cilium.io", m.Name, "--ignore-not-found", "-o", "json"); err != nil {
			return err
		}
		if current.Metadata.UID != m.UID || current.Metadata.ResourceVersion != m.ResourceVersion {
			return fmt.Errorf("CEP changed during stale check: %s", candidate.evidence())
		}
		var pods podList
		if err := get(ctx, k, &pods, "-n", m.Namespace, "get", "pods", "-o", "json"); err != nil {
			return err
		}
		stale := current.ownerUID() != ""
		for _, pod := range pods.Items {
			if pod.Metadata.UID == current.ownerUID() {
				stale = false
			}
		}
		if !stale || m.UID == "" || m.ResourceVersion == "" {
			fmt.Fprintf(log, "refused: not proven stale: %s\n", current.evidence())
			continue
		}
		body, err := json.Marshal(map[string]any{"apiVersion": "v1", "kind": "DeleteOptions", "preconditions": map[string]string{"uid": m.UID, "resourceVersion": m.ResourceVersion}})
		if err != nil {
			return err
		}
		f, err := os.CreateTemp("", "cni-pods-cep-delete-*.json")
		if err != nil {
			return err
		}
		err = func() error {
			defer os.Remove(f.Name())
			if _, err := f.Write(body); err != nil {
				f.Close()
				return err
			}
			if err := f.Close(); err != nil {
				return err
			}
			_, err := k(ctx, "delete", "--raw", "/apis/cilium.io/v2/namespaces/"+m.Namespace+"/ciliumendpoints/"+m.Name, "-f", f.Name())
			return err
		}()
		if err != nil {
			return err
		}
		fmt.Fprintf(log, "cleared stale: %s\n", current.evidence())
	}
	return nil
}
