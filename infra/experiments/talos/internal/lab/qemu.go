package lab

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// HostIP is the host's address on the lab bridge.
const HostIP = "10.5.0.1"

func (c *Cluster) monitorSocket(node string) string {
	return filepath.Join(c.StateLink, c.Name, node+".monitor")
}

// qemu returns the ID and command line of the node's QEMU process.
func (c *Cluster) qemu(node string) (string, []string, error) {
	entries, _ := os.ReadDir("/proc")
	for _, entry := range entries {
		cmdline, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "cmdline"))
		if err != nil {
			continue
		}
		argv := strings.Split(string(cmdline), "\x00")
		if strings.Contains(argv[0], "qemu-system") && strings.Contains(string(cmdline), c.monitorSocket(node)) {
			return entry.Name(), argv, nil
		}
	}
	return "", nil, fmt.Errorf("no QEMU process for %s", node)
}

var qemuMAC = regexp.MustCompile(`mac=([0-9a-f:]{17})`)

// MAC is the node's NIC address on the lab bridge.
func (c *Cluster) MAC(node string) (string, error) {
	_, argv, err := c.qemu(node)
	if err != nil {
		return "", err
	}
	match := qemuMAC.FindStringSubmatch(strings.Join(argv, " "))
	if match == nil {
		return "", fmt.Errorf("no MAC address in %s's QEMU command line", node)
	}
	return match[1], nil
}

// Freeze stops (SIGSTOP) or, with resume, continues the node's QEMU process.
// A stopped VM falls silent at once, as a power loss or a hang would, and can
// still run again. Killing QEMU would also end talosctl's launcher, which does
// not start the VM again.
func (c *Cluster) Freeze(ctx context.Context, node string, resume bool) error {
	pid, _, err := c.qemu(node)
	if err != nil {
		return err
	}
	signal := "-STOP"
	if resume {
		signal = "-CONT"
	}
	_, err = c.sudo(ctx, "kill", signal, pid)
	return err
}

var neighbour = regexp.MustCompile(`lladdr ([0-9a-f:]{17})`)

// Holder returns which of the nodes answers ARP for ip on the host.
func (c *Cluster) Holder(ctx context.Context, ip string, nodes []string) (string, error) {
	output, err := c.Run(ctx, Cmd{Name: "ip", Args: []string{"neigh", "show", ip}})
	if err != nil {
		return "", err
	}
	match := neighbour.FindStringSubmatch(output)
	if match == nil {
		return "", fmt.Errorf("no neighbour entry for %s: %q", ip, output)
	}
	for _, node := range nodes {
		if mac, err := c.MAC(node); err == nil && mac == match[1] {
			return node, nil
		}
	}
	return "", fmt.Errorf("%s is at %s, which is no lab node", ip, match[1])
}
