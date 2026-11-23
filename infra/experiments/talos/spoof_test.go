//go:build integration

package talos_test

import (
	"fmt"
	"strings"
)

// spoofed is one spoofing run: whether each request reached the external address.
type spoofed struct {
	// own is the spoofer from its own address, which its policy denies.
	own bool
	// spoofed is the spoofer from the victim's address, after a gratuitous ARP.
	spoofed bool
	// victim is the victim itself, which its policy allows, before and after the spoof.
	victimBefore, victimAfter bool
}

func (s spoofed) String() string {
	return fmt.Sprintf("victim before %t, spoofer from its own address %t, spoofer from the victim's address %t, victim after %t", s.victimBefore, s.own, s.spoofed, s.victimAfter)
}

// reaches runs a check in a pod and reports whether it printed "connected".
func (b *bench) reaches(namespace, pod, check string) bool {
	b.t.Helper()
	script := fmt.Sprintf(`if %s; then echo connected; else echo blocked; fi`, check)
	return b.kubectl("", "-n", namespace, "exec", pod, "--", "sh", "-c", script) == "connected"
}

// spoofSource has a root pod with NET_ADMIN and NET_RAW take an idle pod's
// address on the same node, announce it with a gratuitous ARP and send from
// it, as root in a privileged pod or a VM guest can. The spoofer's namespace denies
// the external address and the victim's allows it, so reaching it from the
// victim's address means the policy followed the claimed source. annotations
// is the spoofer's metadata.annotations as JSON.
func (b *bench) spoofSource(label, annotations string) spoofed {
	b.t.Helper()
	spoofer := "spoofer-" + label
	b.kubectl(b.manifest("spoof.yaml", "${NODE}", b.worker, "${PROBE_IMAGE}", b.image, "${SPOOFER}", spoofer, "${ANNOTATIONS}", annotations), "apply", "-f", "-")
	b.kubectl("", "-n", "spoof", "apply", "-f", b.production.PodNetworkPolicy())
	b.kubectl("", "-n", "np-allow", "wait", "--for=condition=Ready", "pod/victim", "--timeout=5m")
	b.kubectl("", "-n", "spoof", "wait", "--for=condition=Ready", "pod/"+spoofer, "--timeout=5m")
	victim := b.kubectl("", "-n", "np-allow", "get", "pod", "victim", "-o", "jsonpath={.status.podIP}")
	external := fmt.Sprintf("%s 80", externalIP)

	var result spoofed
	result.victimBefore = b.reaches("np-allow", "victim", "nc -w 3 "+external+" </dev/null >/dev/null 2>&1")
	result.own = b.reaches("spoof", spoofer, "curl -s -o /dev/null --connect-timeout 3 http://"+externalIP+"/")
	// The node ignores ARP updates for a second after its last one.
	takeover := fmt.Sprintf(`sleep 2; ip addr add %[1]s/32 dev eth0; arping -c 2 -U -I eth0 -s %[1]s %[1]s >/dev/null 2>&1; sleep 1; true`, victim)
	fmt.Fprintf(b.results, "== spoof %s takeover\n%s\n", label, b.kubectl("", "-n", "spoof", "exec", spoofer, "--", "sh", "-c", takeover+"; ip -4 addr show dev eth0"))
	result.spoofed = b.reaches("spoof", spoofer, fmt.Sprintf("curl -s -o /dev/null --connect-timeout 3 --interface %s http://%s/", victim, externalIP))
	b.kubectl("", "-n", "spoof", "delete", "pod", spoofer, "--wait=true", "--timeout=2m")
	result.victimAfter = b.reaches("np-allow", "victim", "nc -w 3 "+external+" </dev/null >/dev/null 2>&1")

	fmt.Fprintf(b.results, "== spoof %s (victim %s, annotations %s)\n%s\n", label, victim, annotations, result)
	b.t.Logf("spoof %s: %s", label, result)
	return result
}

// ciliumDrops records the worker's Cilium drop counters.
func (b *bench) ciliumDrops(label string) {
	b.t.Helper()
	agent := b.kubectl("", "-n", "kube-system", "get", "pod", "-l", "k8s-app=cilium", "--field-selector", "spec.nodeName="+b.worker, "-o", "name")
	metrics := b.kubectl("", "-n", "kube-system", "exec", agent, "-c", "cilium-agent", "--", "cilium-dbg", "metrics", "list")
	var drops []string
	for _, line := range strings.Split(metrics, "\n") {
		if strings.Contains(line, "drop_count") {
			drops = append(drops, line)
		}
	}
	fmt.Fprintf(b.results, "== Cilium drops on %s, %s\n%s\n", b.worker, label, strings.Join(drops, "\n"))
}
