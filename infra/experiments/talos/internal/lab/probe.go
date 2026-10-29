package lab

import (
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// Target is something a probe connects to: a TCP address, or a DNS name to resolve.
type Target struct {
	Name string
	Host string
	Port int
}

func (t Target) check() string {
	if t.Port == 0 {
		return fmt.Sprintf("nslookup %s >/dev/null 2>&1", t.Host)
	}
	return fmt.Sprintf("nc -w 2 %s %d </dev/null >/dev/null 2>&1", t.Host, t.Port)
}

// Probe is a fresh pod that, as its first action, checks every target, and
// again at each later offset in seconds. It runs as the production netpol
// canary does: restricted PSA, non-root, read-only, no service account token.
type Probe struct {
	Name, Namespace, Node, Image string
	Offsets                      []int
	Targets                      []Target
}

func (p Probe) Script() string {
	lines := []string{"at() {"}
	for _, t := range p.Targets {
		lines = append(lines, fmt.Sprintf(`  (if %s; then r=connected; else r=blocked; fi; echo "probe offset=$1 target=%s result=$r") &`, t.check(), t.Name))
	}
	lines = append(lines, "  wait", "}")
	for _, offset := range p.Offsets {
		if offset == 0 {
			continue
		}
		lines = append(lines, fmt.Sprintf("(sleep %d; at %d) &", offset, offset))
	}
	if slices.Contains(p.Offsets, 0) {
		lines = append(lines, "at 0")
	}
	return strings.Join(append(lines, "wait"), "\n")
}

func (p Probe) Manifest() (string, error) {
	pod := map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata":   map[string]any{"name": p.Name, "namespace": p.Namespace, "labels": map[string]string{"app": "probe"}},
		"spec": map[string]any{
			"nodeName":                      p.Node,
			"restartPolicy":                 "Never",
			"terminationGracePeriodSeconds": 0,
			"activeDeadlineSeconds":         120,
			"automountServiceAccountToken":  false,
			"securityContext": map[string]any{
				"runAsNonRoot": true, "runAsUser": 65534, "runAsGroup": 65534,
				"seccompProfile": map[string]string{"type": "RuntimeDefault"},
			},
			"containers": []any{map[string]any{
				"name":    "probe",
				"image":   p.Image,
				"command": []string{"sh", "-c", p.Script()},
				"securityContext": map[string]any{
					"allowPrivilegeEscalation": false,
					"readOnlyRootFilesystem":   true,
					"capabilities":             map[string]any{"drop": []string{"ALL"}},
				},
			}},
		},
	}
	data, err := json.Marshal(pod)
	return string(data), err
}

// Result maps an offset and target name to whether the probe connected.
type Result map[int]map[string]bool

var probeLine = regexp.MustCompile(`^probe offset=(\d+) target=(\S+) result=(connected|blocked)$`)

// ParseProbe reads a probe's log and fails unless every offset reported every target.
func ParseProbe(log string, p Probe) (Result, error) {
	result := Result{}
	for _, line := range strings.Split(log, "\n") {
		match := probeLine.FindStringSubmatch(strings.TrimSpace(line))
		if match == nil {
			continue
		}
		offset, _ := strconv.Atoi(match[1])
		if result[offset] == nil {
			result[offset] = map[string]bool{}
		}
		result[offset][match[2]] = match[3] == "connected"
	}
	for _, offset := range p.Offsets {
		for _, t := range p.Targets {
			if _, ok := result[offset][t.Name]; !ok {
				return nil, fmt.Errorf("probe %s did not report %s at +%ds:\n%s", p.Name, t.Name, offset, log)
			}
		}
	}
	return result, nil
}

// Tally counts connected results over runs of the same probe.
type Tally struct {
	Runs      int
	Offsets   []int
	Targets   []string
	connected map[int]map[string]int
}

func NewTally(p Probe) *Tally {
	t := &Tally{Offsets: p.Offsets, connected: map[int]map[string]int{}}
	for _, target := range p.Targets {
		t.Targets = append(t.Targets, target.Name)
	}
	return t
}

func (t *Tally) Add(r Result) {
	t.Runs++
	for offset, targets := range r {
		if t.connected[offset] == nil {
			t.connected[offset] = map[string]int{}
		}
		for target, ok := range targets {
			if ok {
				t.connected[offset][target]++
			}
		}
	}
}

func (t *Tally) Connected(offset int, target string) int { return t.connected[offset][target] }

func (t *Tally) String() string {
	b := &strings.Builder{}
	fmt.Fprintf(b, "%-10s", "connected")
	for _, offset := range t.Offsets {
		fmt.Fprintf(b, " %7s", fmt.Sprintf("+%ds", offset))
	}
	for _, target := range t.Targets {
		fmt.Fprintf(b, "\n%-10s", target)
		for _, offset := range t.Offsets {
			fmt.Fprintf(b, " %7s", fmt.Sprintf("%d/%d", t.Connected(offset, target), t.Runs))
		}
	}
	return b.String()
}

// NodeWidePacketSockets counts sockets in /proc/net/packet bound to every
// interface (Iff 0) for IPv4 (0800) or all protocols (0003), as ADR 2 describes.
func NodeWidePacketSockets(procNetPacket string) int {
	count := 0
	for _, line := range strings.Split(procNetPacket, "\n")[1:] {
		fields := strings.Fields(line)
		if len(fields) >= 5 && (fields[3] == "0003" || fields[3] == "0800") && fields[4] == "0" {
			count++
		}
	}
	return count
}
