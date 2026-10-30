//go:build integration

package talos_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

const (
	inboundPort = 18999
	inboundRuns = 5
)

// restricted is the restricted Pod Security profile's pod and container
// settings, as the probes use.
func restricted(name, image, script string) (pod, container map[string]any) {
	pod = map[string]any{
		"automountServiceAccountToken":  false,
		"terminationGracePeriodSeconds": 0,
		"securityContext": map[string]any{
			"runAsNonRoot": true, "runAsUser": 65534, "runAsGroup": 65534,
			"seccompProfile": map[string]string{"type": "RuntimeDefault"},
		},
	}
	container = map[string]any{
		"name": name, "image": image, "command": []string{"sh", "-c", script},
		"securityContext": map[string]any{
			"allowPrivilegeEscalation": false,
			"readOnlyRootFilesystem":   true,
			"capabilities":             map[string]any{"drop": []string{"ALL"}},
		},
	}
	pod["containers"] = []any{container}
	return pod, container
}

// inboundServer is a pod that logs its start and every connection it
// accepts on inboundPort, with the node's uptime.
func (b *bench) inboundServer(namespace, name string) string {
	script := fmt.Sprintf(`echo "start $(cut -d' ' -f1 /proc/uptime)"
while true; do
  if nc -l -p %d </dev/null >/dev/null 2>&1; then echo "accepted $(cut -d' ' -f1 /proc/uptime)"; fi
done`, inboundPort)
	spec, _ := restricted("server", b.image, script)
	spec["nodeName"], spec["restartPolicy"], spec["activeDeadlineSeconds"] = b.worker, "Never", 60
	data, err := json.Marshal(map[string]any{
		"apiVersion": "v1", "kind": "Pod",
		"metadata": map[string]any{"name": name, "namespace": namespace, "labels": map[string]string{"app": "inbound"}},
		"spec":     spec,
	})
	must(b.t, err)
	return string(data)
}

var uptimeLine = regexp.MustCompile(`(?m)^(start|accepted) ([0-9.]+)$`)

// inbound is one server's result: connections it accepted and how long after
// its start the first came.
type inbound struct {
	accepted int
	first    time.Duration
}

// inboundFirstPacket starts fresh servers on the worker while a scanner on the
// control plane keeps connecting to every address of the worker's pod CIDR,
// in np-inbound-open (no policy) and np-inbound (default-deny ingress), and
// returns what each server accepted. The scanner does not need the server's
// address, so it can connect from the first moment the server listens; its
// round over 254 addresses takes about a second, so a window shorter than
// that can be missed.
func (b *bench) inboundFirstPacket() (open, policed []inbound) {
	b.t.Helper()
	podCIDR := b.kubectl("", "get", "node", b.worker, "-o", "jsonpath={.spec.podCIDR}")
	if !strings.HasSuffix(podCIDR, ".0/24") {
		b.t.Fatalf("worker pod CIDR %s is not a /24", podCIDR)
	}
	prefix := strings.TrimSuffix(podCIDR, ".0/24")
	b.kubectl(b.manifest("inbound.yaml", "${PROBE_IMAGE}", b.image, "${PREFIX}", prefix, "${PORT}", strconv.Itoa(inboundPort)), "apply", "-f", "-")
	b.kubectl("", "-n", "np-control", "rollout", "status", "deployment/scanner", "--timeout=5m")
	run := func(namespace string, i int) inbound {
		name := fmt.Sprintf("server-%d-%d", i, time.Now().UnixNano()%1_000_000)
		b.kubectl(b.inboundServer(namespace, name), "create", "-f", "-")
		b.kubectl("", "-n", namespace, "wait", "--for=condition=Ready", "pod/"+name, "--timeout=120s")
		must(b.t, lab.Sleep(b.ctx, 8*time.Second))
		log := b.kubectl("", "-n", namespace, "logs", name)
		b.kubectl("", "-n", namespace, "delete", "pod", name, "--wait=false")
		result := inbound{first: -1}
		var start float64
		for _, match := range uptimeLine.FindAllStringSubmatch(log, -1) {
			at, _ := strconv.ParseFloat(match[2], 64)
			if match[1] == "start" {
				start = at
				continue
			}
			if result.accepted == 0 {
				result.first = time.Duration((at - start) * float64(time.Second))
			}
			result.accepted++
		}
		fmt.Fprintf(b.results, "== inbound %s %s\n%s\n", namespace, name, log)
		return result
	}
	for i := range inboundRuns {
		open = append(open, run("np-inbound-open", i))
		policed = append(policed, run("np-inbound", i))
	}
	summary := "inbound first packet (fresh servers on " + b.worker + ", scanned from the control plane)\n"
	for i := range inboundRuns {
		summary += fmt.Sprintf("  run %d: open accepted %d (first after %s), default-deny accepted %d (first after %s)\n", i+1, open[i].accepted, open[i].first.Round(10*time.Millisecond), policed[i].accepted, policed[i].first.Round(10*time.Millisecond))
	}
	fmt.Fprintln(b.results, summary)
	b.t.Log("\n" + summary)
	b.kubectl("", "-n", "np-control", "delete", "deployment", "scanner", "--wait=false")
	return open, policed
}

// reachedEveryServer fails unless the scan reached every unpoliced server,
// which shows it covers a server from its first seconds.
func (b *bench) reachedEveryServer(open []inbound) {
	b.t.Helper()
	for i, result := range open {
		if result.accepted == 0 {
			b.t.Errorf("inbound run %d: the scan never reached the unpoliced server, so the check shows nothing", i+1)
		}
	}
}

// initIdentityCCNP selects endpoints whose identity Cilium does not know yet
// (reserved:init) and allows them only cluster DNS, so they are policed until
// their real identity applies.
const initIdentityCCNP = `apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: init-identity-dns-only
spec:
  endpointSelector:
    matchLabels:
      reserved:init: ""
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - {port: "53", protocol: ANY}
`

// apiDownLine is one check of the API-down probe.
var apiDownLine = regexp.MustCompile(`(?m)^([0-9T:.Z-]+) check external=(connected|blocked) local=(connected|blocked)\s*$`)

// apiDownPodStart starts a pod in np-policed while the Kubernetes API is
// unreachable, so Cilium cannot learn the pod's labels when its CNI plugin
// sets it up: the control plane's VM is frozen and the pod is a static pod
// that the worker's kubelet starts from its machine config. The pod checks
// the external address, which np-policed's policy denies, and a pod on its
// own node, which it allows, every second. It returns how often each
// connected while the API was down and afterwards.
func (b *bench) apiDownPodStart(label string) (down, after map[string]int) {
	b.t.Helper()
	controlPlane := b.kubectl("", "get", "nodes", "-l", "node-role.kubernetes.io/control-plane", "-o", "jsonpath={.items[0].metadata.name}")
	local := b.kubectl("", "-n", "np-echo", "get", "pod", "-l", "app=local-echo", "-o", "jsonpath={.items[0].status.podIP}")
	name := "api-down-" + label
	script := fmt.Sprintf(`check() { if nc -w 1 "$1" "$2" </dev/null >/dev/null 2>&1; then echo connected; else echo blocked; fi; }
i=0
while [ $i -lt 90 ]; do
  at=$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)
  r=$({ check %s 80 | sed s/^/external=/ & check %s 8080 | sed s/^/local=/ & wait; } | sort | tr '\n' ' ')
  echo "$at check $r"
  i=$((i + 1))
  sleep 1
done
echo done`, externalIP, local)
	spec, _ := restricted("probe", b.image, script)
	spec["restartPolicy"] = "Never"
	pod := map[string]any{
		"apiVersion": "v1", "kind": "Pod",
		"metadata": map[string]any{"name": name, "namespace": "np-policed", "labels": map[string]string{"app": "probe"}},
		"spec":     spec,
	}
	patch := b.cluster.Path(name + ".json")
	data, err := json.Marshal(map[string]any{"machine": map[string]any{"pods": []any{pod}}})
	must(b.t, err)
	must(b.t, os.WriteFile(patch, data, 0600))
	worker := []string{"-e", b.workerIP, "-n", b.workerIP}

	must(b.t, b.cluster.Freeze(b.ctx, controlPlane, false))
	frozen := time.Now()
	// The agent's API watches fail only after their timeouts.
	err = lab.Sleep(b.ctx, 15*time.Second)
	if err == nil {
		_, err = b.cluster.Talos(b.ctx, append(worker, "patch", "machineconfig", "--patch", "@"+patch)...)
	}
	if err == nil {
		err = lab.Sleep(b.ctx, 60*time.Second)
	}
	resumed := time.Now()
	must(b.t, errors.Join(err, b.cluster.Freeze(b.ctx, controlPlane, true)))
	fmt.Fprintf(b.results, "%s: API frozen %s, static pod added at +15s, API back after %s\n", label, frozen.UTC().Format(time.TimeOnly), resumed.Sub(frozen).Round(time.Second))
	b.kubectl("", "wait", "--for=condition=Ready", "node/"+controlPlane, "--timeout=5m")

	mirror := name + "-" + b.worker
	var log string
	for started := time.Now(); time.Since(started) < 5*time.Minute; {
		log, err = b.cluster.Kubectl(b.ctx, "", "-n", "np-policed", "logs", mirror)
		if err == nil && strings.Contains(log, "\ndone") {
			break
		}
		must(b.t, lab.Sleep(b.ctx, 5*time.Second))
	}
	identity, _ := b.cluster.Kubectl(b.ctx, "", "-n", "np-policed", "get", "ciliumendpoint", mirror, "-o", "jsonpath={.status.identity.labels}")
	fmt.Fprintf(b.results, "== %s, identity now %s\n%s\n", label, identity, log)
	_, err = b.cluster.Talos(b.ctx, append(worker, "patch", "machineconfig", "--patch", `[{"op":"remove","path":"/machine/pods"}]`)...)
	must(b.t, err)

	// The worker's clock follows the host's; one second of slack.
	down, after = map[string]int{}, map[string]int{}
	for _, match := range apiDownLine.FindAllStringSubmatch(log, -1) {
		at, err := time.Parse(time.RFC3339, match[1])
		if err != nil {
			continue
		}
		counts := after
		if at.Before(resumed.Add(-time.Second)) {
			counts = down
		}
		counts["checks"]++
		for i, target := range []string{"external", "local"} {
			if match[2+i] == "connected" {
				counts[target]++
			}
		}
	}
	summary := fmt.Sprintf("%s: while the API was down %d checks, external connected %d, local connected %d; afterwards %d checks, external %d, local %d", label, down["checks"], down["external"], down["local"], after["checks"], after["external"], after["local"])
	fmt.Fprintln(b.results, summary)
	b.t.Log(summary)
	return down, after
}
