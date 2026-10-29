package lab

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Cluster is one disposable Talos cluster created with talosctl's QEMU
// provisioner. Everything it creates lives under Directory, apart from the
// VMs, the bridge and the host firewall rules, which Destroy removes.
type Cluster struct {
	Name      string   `json:"name"`
	Directory string   `json:"directory"`
	Assets    string   `json:"assets"`
	CNIBin    string   `json:"cniBin"`
	Versions  Versions `json:"versions"`
	Contract  string   `json:"contract"`
	Patches   Patches  `json:"patches"`
	// Workers defaults to one.
	Workers int `json:"workers,omitempty"`
	// StorageDisk, if set, gives each worker a second, sparse disk for
	// production's user volume template to select by its serial.
	StorageDisk *Disk `json:"storageDisk,omitempty"`
	// StateLink is a short path to the state directory: QEMU's monitor
	// sockets live there and Unix socket paths are limited to 108 bytes.
	StateLink string `json:"stateLink"`
	Run       Runner `json:"-"`
}

const (
	ControlPlaneIP = "10.5.0.2"
	// FirewallComment marks the rule that opens a NixOS host's firewall to the lab bridge.
	FirewallComment = "talos-lab"
	clusterFile     = "cluster.json"
	iptablesBefore  = "iptables-before.txt"
	linksBefore     = "links-before.txt"
)

// Disk is an extra worker disk.
type Disk struct {
	Serial string `json:"serial"`
	SizeMB int    `json:"sizeMB"`
}

func (c *Cluster) Path(parts ...string) string {
	return filepath.Join(append([]string{c.Directory}, parts...)...)
}
func (c *Cluster) Kubeconfig() string  { return c.Path("kubeconfig") }
func (c *Cluster) Talosconfig() string { return c.Path("talosconfig") }
func (c *Cluster) Talosctl() string    { return filepath.Join(c.Assets, "bin", "talosctl") }

// ClientEnv points every client at this cluster's files only.
func (c *Cluster) ClientEnv() []string {
	return []string{"KUBECONFIG=" + c.Kubeconfig(), "TALOSCONFIG=" + c.Talosconfig(), "HOME=" + c.Path("home")}
}

func (c *Cluster) CreateArgs() []string {
	args := []string{
		"cluster", "create", "dev",
		"--name", c.Name,
		"--state", c.StateLink,
		"--talosconfig", c.Talosconfig(),
		"--skip-kubeconfig",
		"--cni-bin-path", c.CNIBin,
		"--cni-cache-dir", c.Path("cni", "cache"),
		"--cni-conf-dir", c.Path("cni", "conf.d"),
		"--talos-version", c.Contract,
		"--kubernetes-version", c.Versions.Kubernetes,
		"--vmlinuz-path", filepath.Join(c.Assets, "vmlinuz-amd64"),
		"--initrd-path", filepath.Join(c.Assets, "initramfs-amd64.xz"),
		"--with-uefi=false",
		"--controlplanes", "1", "--workers", strconv.Itoa(max(c.Workers, 1)),
		"--cpus", "2", "--cpus-workers", "2",
		"--memory", "3GiB", "--memory-workers", "3GiB",
		// Preallocated disks once filled the host's /home.
		"--disk", "10240", "--disk-preallocate=false",
		"--wait-timeout", "15m",
	}
	if c.StorageDisk != nil {
		args = append(args, "--extra-disks", "1", "--extra-disks-size", strconv.Itoa(c.StorageDisk.SizeMB), "--extra-disks-drivers", "virtio", "--extra-disks-serials", c.StorageDisk.Serial)
	}
	for _, group := range []struct {
		flag  string
		files []string
	}{{"--config-patch", c.Patches.All}, {"--config-patch-control-plane", c.Patches.ControlPlane}, {"--config-patch-worker", c.Patches.Worker}} {
		for _, file := range group.files {
			args = append(args, group.flag, "@"+file)
		}
	}
	return args
}

func (c *Cluster) sudo(ctx context.Context, name string, args ...string) (string, error) {
	return c.Run(ctx, Cmd{Name: "sudo", Args: append([]string{"-n", name}, args...)})
}

// Save records the cluster so Sweep can destroy it after an interrupted run.
func (c *Cluster) Save() error {
	if err := os.MkdirAll(c.Path("home"), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.Path(clusterFile), data, 0600)
}

func Load(directory string, run Runner) (*Cluster, error) {
	data, err := os.ReadFile(filepath.Join(directory, clusterFile))
	if err != nil {
		return nil, err
	}
	c := &Cluster{Run: run}
	return c, json.Unmarshal(data, c)
}

func (c *Cluster) linkState() error {
	if err := os.MkdirAll(c.Path("state"), 0700); err != nil {
		return err
	}
	directory, err := os.MkdirTemp("/tmp", "tl-")
	if err != nil {
		return err
	}
	c.StateLink = filepath.Join(directory, "s")
	return os.Symlink(c.Path("state"), c.StateLink)
}

func (c *Cluster) Create(ctx context.Context) error {
	if err := c.linkState(); err != nil {
		return err
	}
	if err := c.Save(); err != nil {
		return err
	}
	snapshot, err := c.iptables(ctx)
	if err != nil {
		return err
	}
	if err := os.WriteFile(c.Path(iptablesBefore), []byte(snapshot), 0600); err != nil {
		return err
	}
	links, err := c.Run(ctx, Cmd{Name: "ip", Args: []string{"-br", "link"}})
	if err != nil {
		return err
	}
	if err := os.WriteFile(c.Path(linksBefore), []byte(links), 0600); err != nil {
		return err
	}
	if err := c.openFirewall(ctx); err != nil {
		return err
	}
	env := append([]string{"PATH=" + os.Getenv("PATH")}, c.ClientEnv()...)
	start := time.Now()
	output, err := c.sudo(ctx, "env", append(env, append([]string{c.Talosctl()}, c.CreateArgs()...)...)...)
	if writeErr := os.WriteFile(c.Path("create.log"), []byte(output), 0600); writeErr != nil {
		return errors.Join(err, writeErr)
	}
	if err != nil {
		return fmt.Errorf("talosctl cluster create failed; see %s: %w", c.Path("create.log"), err)
	}
	if _, err := c.sudo(ctx, "chown", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()), c.Talosconfig()); err != nil {
		return err
	}
	_, err = c.Run(ctx, Cmd{Name: c.Talosctl(), Args: []string{"--talosconfig", c.Talosconfig(), "-n", ControlPlaneIP, "kubeconfig", "--force", c.Kubeconfig()}, Env: c.ClientEnv()})
	fmt.Printf("Cluster %s ready after %s\n", c.Name, time.Since(start).Round(time.Second))
	return err
}

func (c *Cluster) firewall(ctx context.Context, action string) error {
	_, err := c.sudo(ctx, "iptables", action, "nixos-fw", "-i", "talos+", "-m", "comment", "--comment", FirewallComment, "-j", "nixos-fw-accept")
	return err
}

// openFirewall lets the lab bridge reach talosctl's DHCP, DNS and config
// servers on hosts whose NixOS firewall drops them.
func (c *Cluster) openFirewall(ctx context.Context) error {
	if _, err := c.sudo(ctx, "iptables", "-n", "-L", "nixos-fw"); err != nil {
		return nil
	}
	if c.firewall(ctx, "-C") == nil {
		return nil
	}
	return c.firewall(ctx, "-I")
}

func (c *Cluster) closeFirewall(ctx context.Context) error {
	for c.firewall(ctx, "-C") == nil {
		if err := c.firewall(ctx, "-D"); err != nil {
			return err
		}
	}
	return nil
}

func (c *Cluster) iptables(ctx context.Context) (string, error) {
	output := ""
	for _, table := range []string{"filter", "nat"} {
		rules, err := c.sudo(ctx, "iptables", "-t", table, "-S")
		if err != nil {
			return "", err
		}
		for _, line := range strings.Split(strings.TrimSpace(rules), "\n") {
			output += table + " " + line + "\n"
		}
	}
	return output, nil
}

// labRule matches iptables entries the provisioner and its CNI plugins create.
var labRule = regexp.MustCompile(`CNI-|DOCKER-USER|talos|10\.5\.0\.`)

// AddedRules returns the lab's iptables rules and chains that were not present
// before, in an order that deletes rules before their chains.
func AddedRules(before, after string) (rules, chains [][]string) {
	existing := map[string]bool{}
	for _, line := range strings.Split(before, "\n") {
		existing[line] = true
	}
	for _, line := range strings.Split(after, "\n") {
		if existing[line] || !labRule.MatchString(line) {
			continue
		}
		table, rule, _ := strings.Cut(line, " ")
		fields := SplitRule(rule)
		if len(fields) < 2 {
			continue
		}
		switch fields[0] {
		case "-A":
			rules = append(rules, append([]string{"-t", table, "-D"}, fields[1:]...))
		case "-N":
			chains = append(chains, []string{"-t", table, fields[1]})
		}
	}
	return rules, chains
}

// SplitRule splits an `iptables -S` line, honouring its double quotes.
func SplitRule(line string) []string {
	fields := []string{}
	field, quoted, started := "", false, false
	for _, r := range line {
		switch {
		case r == '"':
			quoted, started = !quoted, true
		case r == ' ' && !quoted:
			if started {
				fields = append(fields, field)
			}
			field, started = "", false
		default:
			field, started = field+string(r), true
		}
	}
	if started {
		fields = append(fields, field)
	}
	return fields
}

func (c *Cluster) restoreIptables(ctx context.Context) error {
	before, err := os.ReadFile(c.Path(iptablesBefore))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	after, err := c.iptables(ctx)
	if err != nil {
		return err
	}
	rules, chains := AddedRules(string(before), after)
	var errs []error
	for _, rule := range rules {
		_, err := c.sudo(ctx, "iptables", rule...)
		errs = append(errs, err)
	}
	for _, chain := range chains {
		_, flush := c.sudo(ctx, "iptables", "-t", chain[1], "-F", chain[2])
		_, remove := c.sudo(ctx, "iptables", "-t", chain[1], "-X", chain[2])
		errs = append(errs, flush, remove)
	}
	return errors.Join(errs...)
}

// collectLogs keeps the VM console logs before the state directory goes.
func (c *Cluster) collectLogs() {
	logs, err := filepath.Glob(c.Path("state", c.Name, "*.log"))
	if err != nil || len(logs) == 0 {
		return
	}
	if err := os.MkdirAll(c.Path("logs"), 0700); err != nil {
		return
	}
	for _, log := range logs {
		if data, err := os.ReadFile(log); err == nil {
			_ = os.WriteFile(c.Path("logs", filepath.Base(log)), data, 0600)
		}
	}
}

// Destroy removes the VMs, the bridge, the firewall rules and the disks, then
// fails if anything of the lab remains on the host. Every step runs even
// when an earlier one fails.
func (c *Cluster) Destroy(ctx context.Context) error {
	var errs []error
	if _, err := os.Stat(c.Path("state", c.Name)); err == nil {
		c.collectLogs()
		_, err := c.sudo(ctx, "env", append(c.ClientEnv(), c.Talosctl(), "cluster", "destroy", "--name", c.Name, "--state", c.StateLink)...)
		if err != nil {
			// talosctl gives up on the first VM that does not stop in time and
			// leaves the rest of the cluster, such as its DHCP server, running.
			errs = append(errs, err, c.killProcesses(ctx), c.removeLinks(ctx))
		}
	}
	errs = append(errs, c.closeFirewall(ctx), c.restoreIptables(ctx))
	remove := []string{"-rf", c.Path("state"), c.Path("cni"), c.Path("home")}
	if c.StateLink != "" {
		remove = append(remove, filepath.Dir(c.StateLink))
	}
	_, err := c.sudo(ctx, "rm", remove...)
	errs = append(errs, err)
	return errors.Join(append(errs, c.Leftovers(ctx))...)
}

// Processes returns the IDs of the cluster's processes: QEMU and its
// launchers, which mention the state directory, and the lab talosctl's
// *-launch helpers, such as its load balancer and DNS server, which do not.
func (c *Cluster) Processes() []string {
	pids := []string{}
	entries, _ := os.ReadDir("/proc")
	for _, entry := range entries {
		cmdline, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "cmdline"))
		if err == nil && c.owns(strings.Split(string(cmdline), "\x00")) {
			pids = append(pids, entry.Name())
		}
	}
	return pids
}

func (c *Cluster) owns(argv []string) bool {
	if len(argv) > 1 && argv[0] == c.Talosctl() && strings.HasSuffix(argv[1], "-launch") {
		return true
	}
	for _, arg := range argv {
		if strings.Contains(arg, c.Path("state")) || (c.StateLink != "" && strings.Contains(arg, c.StateLink)) {
			return true
		}
	}
	return false
}

func (c *Cluster) killProcesses(ctx context.Context) error {
	pids := c.Processes()
	if len(pids) == 0 {
		return nil
	}
	_, err := c.sudo(ctx, "kill", append([]string{"-KILL"}, pids...)...)
	return errors.Join(err, Sleep(ctx, 2*time.Second))
}

// NewLinks returns the talos* interfaces in after that are not in before.
func NewLinks(before, after string) []string {
	existing := map[string]bool{}
	for _, line := range strings.Split(before, "\n") {
		if fields := strings.Fields(line); len(fields) > 0 {
			existing[fields[0]] = true
		}
	}
	links := []string{}
	for _, line := range strings.Split(after, "\n") {
		if fields := strings.Fields(line); len(fields) > 0 && strings.HasPrefix(fields[0], "talos") && !existing[fields[0]] {
			links = append(links, fields[0])
		}
	}
	return links
}

func (c *Cluster) removeLinks(ctx context.Context) error {
	before, err := os.ReadFile(c.Path(linksBefore))
	if err != nil {
		return err
	}
	after, err := c.Run(ctx, Cmd{Name: "ip", Args: []string{"-br", "link"}})
	if err != nil {
		return err
	}
	var errs []error
	for _, link := range NewLinks(string(before), after) {
		_, err := c.sudo(ctx, "ip", "link", "del", link)
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// Leftovers reports lab processes, links and firewall entries still on the host.
func (c *Cluster) Leftovers(ctx context.Context) error {
	found := []string{}
	if pids := c.Processes(); len(pids) > 0 {
		found = append(found, "processes: "+strings.Join(pids, " "))
	}
	links, err := c.Run(ctx, Cmd{Name: "ip", Args: []string{"-br", "link"}})
	if err != nil {
		return err
	}
	for _, line := range strings.Split(links, "\n") {
		if strings.HasPrefix(line, "talos") {
			found = append(found, "link: "+line)
		}
	}
	rules, err := c.iptables(ctx)
	if err != nil {
		return err
	}
	if before, err := os.ReadFile(c.Path(iptablesBefore)); err == nil {
		added, chains := AddedRules(string(before), rules)
		for _, rule := range added {
			found = append(found, "iptables rule: "+strings.Join(rule, " "))
		}
		for _, chain := range chains {
			found = append(found, "iptables chain: "+strings.Join(chain, " "))
		}
	}
	if strings.Contains(rules, FirewallComment) {
		found = append(found, "firewall rule "+FirewallComment)
	}
	if len(found) > 0 {
		return fmt.Errorf("lab left resources on the host:\n%s", strings.Join(found, "\n"))
	}
	return nil
}

// Sweep destroys clusters of runs under root that still have VM state, such
// as after a test binary timed out before its cleanup ran.
func Sweep(ctx context.Context, root string, run Runner) error {
	files, err := filepath.Glob(filepath.Join(root, "*", "*", clusterFile))
	if err != nil {
		return err
	}
	var errs []error
	for _, file := range files {
		directory := filepath.Dir(file)
		if _, err := os.Stat(filepath.Join(directory, "state")); err != nil {
			continue
		}
		c, err := Load(directory, run)
		if err == nil {
			fmt.Println("Destroying leftover lab cluster in", directory)
			err = c.Destroy(ctx)
		}
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}
