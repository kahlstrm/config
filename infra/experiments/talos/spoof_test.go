//go:build integration

package talos_test

import (
	"fmt"
	"strings"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
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

// curlExternal requests the external address from the spoofer, from the
// address from if it is set, and reports whether it connected. Only a timeout
// counts as blocked, as a dropped SYN gives; any other curl failure, such as
// a source address the pod doesn't have, fails the test.
func (b *bench) curlExternal(pod, from string) bool {
	b.t.Helper()
	args := "--connect-timeout 3 --max-time 5"
	if from != "" {
		args += " --interface " + from
	}
	out := b.kubectl("", "-n", "spoof", "exec", pod, "--", "sh", "-c", fmt.Sprintf(`curl -s -o /dev/null %s http://%s/; echo "exit $?"`, args, externalIP))
	switch out {
	case "exit 0":
		return true
	case "exit 28":
		return false
	}
	b.t.Fatalf("curl from %s (source %q) failed other than by a timeout: %s", pod, from, out)
	return false
}

// spoofSource has a root pod with NET_ADMIN and NET_RAW take an idle pod's
// address on the same node, announce it with a gratuitous ARP and send from
// it, as root in a privileged pod or a VM guest can. The spoofer's namespace
// denies the external address and the victim's allows it, so reaching it from
// the victim's address means the policy followed the claimed source.
// annotations is the spoofer's metadata.annotations as JSON.
func (b *bench) spoofSource(label, annotations string) spoofed {
	b.t.Helper()
	spoofer := "spoofer-" + label
	// The spoofer first runs without a policy, as the positive control for its own data path.
	b.kubectl("", "-n", "spoof", "delete", "networkpolicy", "pod-network-only", "--ignore-not-found")
	b.kubectl(b.manifest("spoof.yaml", "${NODE}", b.worker, "${PROBE_IMAGE}", b.image, "${SPOOFER}", spoofer, "${ANNOTATIONS}", annotations), "apply", "-f", "-")
	b.kubectl("", "-n", "np-allow", "wait", "--for=condition=Ready", "pod/victim", "--timeout=5m")
	b.kubectl("", "-n", "spoof", "wait", "--for=condition=Ready", "pod/"+spoofer, "--timeout=5m")
	victim := b.kubectl("", "-n", "np-allow", "get", "pod", "victim", "-o", "jsonpath={.status.podIP}")
	external := fmt.Sprintf("%s 80", externalIP)

	if !b.curlExternal(spoofer, "") {
		b.t.Fatalf("spoof %s: the spoofer did not reach the external address without a policy, so its blocked requests would show nothing", label)
	}
	b.kubectl("", "-n", "spoof", "apply", "-f", b.production.PodNetworkPolicy())
	// Wait out ADR 4's window until the policy denies the spoofer's own address.
	var result spoofed
	result.own = true
	for try := 0; try < 10 && result.own; try++ {
		must(b.t, lab.Sleep(b.ctx, time.Second))
		result.own = b.curlExternal(spoofer, "")
	}
	result.victimBefore = b.reaches("np-allow", "victim", "nc -w 3 "+external+" </dev/null >/dev/null 2>&1")
	// The node ignores ARP updates for a second after its last one. Any
	// failure to take the address or send the ARP fails the exec, and so the test.
	takeover := fmt.Sprintf(`set -e
sleep 2
ip addr add %[1]s/32 dev eth0
ip -4 -o addr show dev eth0 | grep -qF "inet %[1]s/32 "
arp=$(arping -c 2 -U -I eth0 -s %[1]s %[1]s 2>&1) || true
echo "$arp"
echo "$arp" | grep -q "Sent 2 probe"
sleep 1
ip -4 -o addr show dev eth0`, victim)
	fmt.Fprintf(b.results, "== spoof %s takeover\n%s\n", label, b.kubectl("", "-n", "spoof", "exec", spoofer, "--", "sh", "-c", takeover))
	result.spoofed = b.curlExternal(spoofer, victim)
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
