package cnipods

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
)

// ClearStaleCEPs is an explicit operator action, never part of recreation.
// It deletes CiliumEndpoints whose Pod owner UID matches no pod in their
// namespace, with the CEP's UID and resourceVersion as delete
// preconditions. selected, if not empty, limits it to those CEPs
// (namespace/name). Each CEP is reported as one of:
//
//   - healthy: its owner pod exists; skipped.
//   - cleared: deleted.
//   - unresolved: a suspect it could not clear: no owner reference (missing
//     ownership is not proof of staleness), changed since it was read, the
//     delete rejected (such as by a precondition), or a selected CEP that
//     does not exist.
//
// One CEP's failure does not stop the others. It returns an error listing
// the unresolved CEPs, if any.
func ClearStaleCEPs(ctx context.Context, k Kubectl, selected []string, log io.Writer) error {
	var endpoints endpointList
	if err := get(ctx, k, &endpoints, "get", "ciliumendpoints.cilium.io", "-A", "-o", "json"); err != nil {
		return err
	}
	unresolved := []string{}
	note := func(reason string, e endpoint) {
		unresolved = append(unresolved, e.Metadata.Namespace+"/"+e.Metadata.Name)
		fmt.Fprintf(log, "unresolved: %s: %s\n", reason, e.evidence())
	}
	found := map[string]bool{}
	podUIDs := map[string]map[string]bool{} // namespace -> pod UIDs
	for _, candidate := range endpoints.Items {
		m := candidate.Metadata
		key := m.Namespace + "/" + m.Name
		if len(selected) > 0 && !slices.Contains(selected, key) {
			continue
		}
		found[key] = true
		if m.Namespace == "kube-system" && strings.HasPrefix(m.Name, "cilium-health-") {
			fmt.Fprintf(log, "healthy: Cilium health endpoint, skipped: %s\n", candidate.evidence())
			continue
		}
		owner := candidate.ownerUID()
		if owner == "" {
			note("no Pod owner reference, not proof of staleness", candidate)
			continue
		}
		if podUIDs[m.Namespace] == nil {
			var pods podList
			if err := get(ctx, k, &pods, "-n", m.Namespace, "get", "pods", "-o", "json"); err != nil {
				note("could not list its namespace's pods: "+err.Error(), candidate)
				continue
			}
			podUIDs[m.Namespace] = map[string]bool{}
			for _, pod := range pods.Items {
				podUIDs[m.Namespace][pod.Metadata.UID] = true
			}
		}
		if podUIDs[m.Namespace][owner] {
			fmt.Fprintf(log, "healthy: owner pod exists, skipped: %s\n", candidate.evidence())
			continue
		}
		// A suspect: re-read it, then delete only the version we judged.
		var current endpoint
		if err := get(ctx, k, &current, "-n", m.Namespace, "get", "ciliumendpoints.cilium.io", m.Name, "--ignore-not-found", "-o", "json"); err != nil {
			note("could not re-read: "+err.Error(), candidate)
			continue
		}
		if current.Metadata.UID == "" {
			fmt.Fprintf(log, "cleared: already gone: %s\n", candidate.evidence())
			continue
		}
		if current.Metadata.UID != m.UID || current.Metadata.ResourceVersion != m.ResourceVersion || m.ResourceVersion == "" {
			note("changed since it was read, not deleted", candidate)
			continue
		}
		if err := deleteCEP(ctx, k, m.Namespace, m.Name, m.UID, m.ResourceVersion); err != nil {
			note("delete rejected: "+err.Error(), candidate)
			continue
		}
		fmt.Fprintf(log, "cleared: owner pod gone: %s\n", current.evidence())
	}
	for _, key := range selected {
		if !found[key] {
			unresolved = append(unresolved, key)
			fmt.Fprintf(log, "unresolved: selected CEP not found: %s\n", key)
		}
	}
	if len(unresolved) > 0 {
		return fmt.Errorf("%d CEPs unresolved: %s", len(unresolved), strings.Join(unresolved, " "))
	}
	return nil
}

// deleteCEP deletes a CiliumEndpoint only if it still has this UID and
// resourceVersion.
func deleteCEP(ctx context.Context, k Kubectl, namespace, name, uid, resourceVersion string) error {
	body, err := json.Marshal(map[string]any{"apiVersion": "v1", "kind": "DeleteOptions", "preconditions": map[string]string{"uid": uid, "resourceVersion": resourceVersion}})
	if err != nil {
		return err
	}
	f, err := os.CreateTemp("", "cni-pods-cep-delete-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.Write(body); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	_, err = retry(ctx, k, "delete", "--raw", "/apis/cilium.io/v2/namespaces/"+namespace+"/ciliumendpoints/"+name, "-f", f.Name())
	return err
}
