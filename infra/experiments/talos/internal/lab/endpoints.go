package lab

import (
	"encoding/json"
	"strings"
)

// AgentEndpoint is one endpoint of a Cilium agent, from
// `cilium-dbg endpoint list -o json` (or `endpoint get`).
type AgentEndpoint struct {
	ID             int
	State          string
	Namespace, Pod string // empty for endpoints without a pod (host, health)
	Container      string // the CNI attachment: container ID and interface
}

// resolveLabels prefixes the controller Cilium 1.20 names after an
// endpoint's pod. Its external identifiers no longer carry the pod name.
const resolveLabels = "resolve-labels-"

// AgentEndpoints parses an agent's endpoint list.
func AgentEndpoints(raw string) ([]AgentEndpoint, error) {
	var parsed []struct {
		ID     int `json:"id"`
		Status struct {
			State       string `json:"state"`
			Identifiers struct {
				Attachment string `json:"cni-attachment-id"`
			} `json:"external-identifiers"`
			Controllers []struct {
				Name string `json:"name"`
			} `json:"controllers"`
		} `json:"status"`
	}
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return nil, err
	}
	endpoints := make([]AgentEndpoint, 0, len(parsed))
	for _, p := range parsed {
		e := AgentEndpoint{ID: p.ID, State: p.Status.State, Container: p.Status.Identifiers.Attachment}
		for _, c := range p.Status.Controllers {
			if pod, ok := strings.CutPrefix(c.Name, resolveLabels); ok {
				e.Namespace, e.Pod, _ = strings.Cut(pod, "/")
			}
		}
		endpoints = append(endpoints, e)
	}
	return endpoints, nil
}
