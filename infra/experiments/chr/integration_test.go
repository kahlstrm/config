//go:build integration

package chr_test

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/logger"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/kahlstrm/config/infra/experiments/chr/internal/lab"
	"golang.org/x/sync/errgroup"
)

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func environment(t *testing.T, scenario string) (context.Context, string, string, string) {
	t.Helper()
	for _, binary := range []string{"qemu-system-x86_64", "qemu-img", "ssh", "scp", "ssh-keygen", "curl", "dig", "jq", "python3"} {
		_, err := exec.LookPath(binary)
		must(t, err)
	}
	file, err := os.OpenFile("/dev/kvm", os.O_RDWR, 0)
	must(t, err)
	must(t, file.Close())
	source := os.Getenv("CHR_SOURCE")
	if source == "" {
		source, err = os.Getwd()
		must(t, err)
	}
	root := os.Getenv("CHR_STATE")
	if root == "" {
		root = os.Getenv("XDG_STATE_HOME")
		if root == "" {
			home, err := os.UserHomeDir()
			must(t, err)
			root = filepath.Join(home, ".local/state")
		}
		root = filepath.Join(root, "chr")
	}
	root, err = filepath.Abs(root)
	must(t, err)
	unlock, err := lab.Lock(root)
	must(t, err)
	t.Cleanup(func() { must(t, unlock()) })
	runRoot := filepath.Join(root, scenario, strconv.FormatInt(time.Now().UnixNano(), 10))
	must(t, os.MkdirAll(runRoot, 0700))
	t.Log("Private evidence:", runRoot)
	return t.Context(), root, runRoot, source
}

type fixture struct {
	t       *testing.T
	options *terraform.Options
}

func newFixture(t *testing.T, directory string, env map[string]string) *fixture {
	t.Helper()
	binary := "terraform"
	if _, err := exec.LookPath("tofu"); err == nil {
		binary = "tofu"
	}
	_, err := exec.LookPath(binary)
	must(t, err)
	env["TF_IN_AUTOMATION"] = "1"
	return &fixture{t: t, options: &terraform.Options{TerraformDir: directory, TerraformBinary: binary, EnvVars: env, NoColor: true, Lock: true, Logger: logger.Discard}}
}

func (f *fixture) execute(label string, call func() (string, error)) string {
	f.t.Helper()
	output, err := call()
	log := filepath.Join(f.options.TerraformDir, label+".log")
	must(f.t, lab.Write(log, output))
	if err != nil {
		f.t.Fatalf("Terraform %s failed; see %s", label, log)
	}
	return output
}

func (f *fixture) init() {
	f.execute("init", func() (string, error) { return terraform.InitE(f.t, f.options) })
}
func (f *fixture) plan(label, filename string) string {
	f.options.PlanFilePath = filename
	f.execute(label, func() (string, error) { return terraform.PlanE(f.t, f.options) })
	return f.execute(label+"-show", func() (string, error) { return terraform.ShowE(f.t, f.options) })
}
func (f *fixture) apply(label string) {
	f.execute(label, func() (string, error) { return terraform.ApplyE(f.t, f.options) })
	f.options.PlanFilePath = ""
}
func (f *fixture) settled(label string) {
	f.execute(label, func() (string, error) {
		code, err := terraform.PlanExitCodeE(f.t, f.options)
		if err == nil && code != 0 {
			err = fmt.Errorf("expected no changes, got exit code %d", code)
		}
		return fmt.Sprintf("Plan exit code: %d\n", code), err
	})
}

func TestBootstrap(t *testing.T) {
	ctx, root, runRoot, source := environment(t, "bootstrap")
	version := os.Getenv("CHR_VERSION")
	if version == "" {
		version = "7.21.3"
	}
	routers := []*lab.BootstrapLab{}
	for i, name := range []string{"stationary", "kuberack"} {
		router, err := lab.NewBootstrap(version, root, runRoot, name, source, filepath.Join(runRoot, "transit.sock"), i == 0)
		must(t, err)
		routers = append(routers, router)
		t.Cleanup(func() { must(t, router.Stop(context.Background())) })
		must(t, router.Start(ctx))
	}
	reset := func() {
		group, ctx := errgroup.WithContext(ctx)
		for _, router := range routers {
			group.Go(func() error { return router.Reset(ctx) })
		}
		must(t, group.Wait())
	}
	verify := func() {
		for _, router := range routers {
			must(t, router.Verify(ctx))
		}
	}
	exports := func() []string {
		values := []string{}
		for _, router := range routers {
			output, err := router.FirewallExport(ctx)
			must(t, err)
			values = append(values, output)
		}
		return values
	}
	assertExports := func(before []string) {
		after := exports()
		for i := range before {
			if before[i] != after[i] {
				t.Fatalf("%s: Terraform changed firewall rules or ordering", routers[i].Name)
			}
		}
	}
	reset()
	verify()
	directory := filepath.Join(runRoot, "terraform")
	must(t, os.Mkdir(directory, 0700))
	must(t, lab.Copy(filepath.Join(source, "scenarios/bootstrap/terraform/main.tf"), filepath.Join(directory, "main.tf")))
	networking := filepath.Clean(filepath.Join(source, "../../local-networking"))
	for _, name := range []string{"bootstrap.tf", "bootstrap-config.tf", "network-topology.tf", "modules"} {
		must(t, os.Symlink(filepath.Join(networking, name), filepath.Join(directory, name)))
	}
	must(t, lab.Copy(filepath.Join(networking, ".terraform.lock.hcl"), filepath.Join(directory, ".terraform.lock.hcl")))
	env := map[string]string{}
	for _, router := range routers {
		password, err := os.ReadFile(router.Path("password"))
		must(t, err)
		env["TF_VAR_"+router.Name+"_hosturl"] = fmt.Sprintf("https://127.0.0.1:%d", router.HTTPSPort)
		env["TF_VAR_"+router.Name+"_password"] = string(password)
	}
	f := newFixture(t, directory, env)
	f.init()
	adopt := func(recovery bool) {
		for _, phase := range []struct {
			label string
			apply bool
		}{{"preview", false}, {"adopt", true}, {"repeat", true}} {
			args := []string{filepath.Join(networking, "scripts/adopt-bootstrap.py"), "--terraform", f.options.TerraformBinary, "--directory", directory, "--router", "stationary", "--router", "kuberack"}
			if phase.apply {
				args = append(args, "--apply")
			}
			cmd := exec.CommandContext(ctx, "python3", args...)
			cmd.Env = os.Environ()
			for name, value := range f.options.EnvVars {
				cmd.Env = append(cmd.Env, name+"="+value)
			}
			output, err := cmd.CombinedOutput()
			must(t, lab.Write(filepath.Join(directory, phase.label+".log"), string(output)))
			if err != nil {
				t.Fatalf("importer %s failed; see private log", phase.label)
			}
			if recovery && phase.label == "adopt" && !strings.Contains(string(output), "rebind ") {
				t.Fatal("reset did not exercise stale binding repair")
			}
			if phase.label == "repeat" && !strings.Contains(string(output), "No state changes needed.") {
				t.Fatal("repeat adoption was not a no-op")
			}
		}
		plan := f.plan("plan", "adopt.tfplan")
		must(t, lab.VerifyAdoptionPlan(ctx, plan, recovery))
		f.apply("apply")
		f.settled("settled")
		for _, router := range routers {
			generated, err := os.ReadFile(filepath.Join(directory, "bootstrap/generated", router.Name+".rsc"))
			must(t, err)
			production, err := os.ReadFile(filepath.Join(networking, "bootstrap/generated", router.Name+".rsc"))
			must(t, err)
			if string(generated) != string(production) {
				t.Fatalf("%s: generated script differs from production", router.Name)
			}
		}
		t.Log("PASS adoption, repeat no-op and empty full bootstrap-module plan")
	}
	before := exports()
	adopt(false)
	assertExports(before)
	for _, router := range routers {
		for _, family := range []string{"ip", "ipv6"} {
			_, err := router.SSH(ctx, fmt.Sprintf(`/%s firewall filter move [find chain=forward action=fasttrack-connection] destination=[find chain=forward comment="bootstrap: drop invalid"]`, family))
			must(t, err)
		}
	}
	plan := f.plan("order-plan", "order.tfplan")
	_, err := lab.QueryJSON(ctx, plan, `[.resource_changes[] | select(.change.actions != ["no-op"])] | length == 4 and all(.[]; .type == "routeros_move_items" and .change.actions == ["update"])`, "-e")
	must(t, err)
	f.apply("order-apply")
	f.settled("order-settled")
	assertExports(before)
	reset()
	for _, router := range routers {
		_, err := router.SSH(ctx, `:foreach id in=[/ip dns static find] do={:local n [/ip dns static get $id name]; :local t [/ip dns static get $id type]; :local a [/ip dns static get $id address]; :local d [/ip dns static get $id disabled]; :local c [/ip dns static get $id comment]; /ip dns static remove $id; /ip dns static add name=$n type=$t address=$a disabled=$d comment=$c}`)
		must(t, err)
		for _, rule := range []struct{ family, next string }{{"ip", "bootstrap: drop all from WAN not DSTNATed"}, {"ipv6", "bootstrap: drop packets with bad src ipv6"}} {
			_, err := router.SSH(ctx, fmt.Sprintf(`/%s firewall filter remove [find chain=forward comment="bootstrap: drop invalid"]; /%s firewall filter add chain=forward action=drop connection-state=invalid comment="bootstrap: drop invalid" place-before=[find chain=forward comment="%s"]`, rule.family, rule.family, rule.next))
			must(t, err)
		}
	}
	before = exports()
	adopt(true)
	assertExports(before)
	verify()
}

func TestDNSReferral(t *testing.T) {
	ctx, _, runRoot, source := environment(t, "dns-referral")
	version := os.Getenv("CHR_VERSION")
	if version == "" {
		version = "7.21.3"
	}
	router, err := lab.New(version, runRoot, 0)
	must(t, err)
	router.EnableAPI = true
	router.NetworkArgs = func(capture string) []string {
		return []string{"-netdev", "user,id=lab,hostfwd=tcp:127.0.0.1:0-:22,hostfwd=tcp:127.0.0.1:0-:8728", "-device", "virtio-net-pci,netdev=lab", "-object", "filter-dump,id=capture,netdev=lab,file=" + capture}
	}
	router.NetworkReady = func(ctx context.Context) error {
		var err error
		router.SSHPort, err = router.ForwardedPort(ctx, "tcp", 22)
		return err
	}
	t.Cleanup(func() { must(t, router.Stop(context.Background())) })
	must(t, router.Start(ctx))
	apiPort, err := router.ForwardedPort(ctx, "tcp", 8728)
	must(t, err)
	directory := filepath.Join(runRoot, "terraform")
	must(t, os.Mkdir(directory, 0700))
	must(t, lab.Copy(filepath.Join(source, "scenarios/dns_referral/terraform/main.tf"), filepath.Join(directory, "main.tf")))
	must(t, lab.Copy(filepath.Join(source, "scenarios/dns_referral/terraform/.terraform.lock.hcl"), filepath.Join(directory, ".terraform.lock.hcl")))
	password, err := os.ReadFile(router.Path("password"))
	must(t, err)
	f := newFixture(t, directory, map[string]string{"TF_VAR_hosturl": fmt.Sprintf("api://127.0.0.1:%d", apiPort), "TF_VAR_password": string(password)})
	f.init()
	id, err := router.SSH(ctx, `:put [/ip/dhcp-client find where interface="ether1"]`)
	must(t, err)
	if len(strings.Fields(id)) != 1 {
		t.Fatalf("expected one factory DHCP client, got %q", id)
	}
	f.execute("import", func() (string, error) {
		return terraform.RunTerraformCommandE(t, f.options, "import", "-input=false", "routeros_ip_dhcp_client.uplink", strings.TrimSpace(id))
	})
	t.Cleanup(func() {
		f.options.PlanFilePath = ""
		// Deleting the imported uplink would remove the API's management address.
		f.options.Vars = map[string]interface{}{"scenario_enabled": false}
		f.apply("restore")
		f.settled("restored")
		settings, err := router.SSH(context.Background(), `:put [/ip/dhcp-client get [find where interface="ether1"] use-peer-dns]; :put [/ip/dns get allow-remote-requests]; :put [:len [/ip/dns get servers]]`)
		must(t, err)
		if strings.Join(strings.Fields(settings), " ") != "true false 0" {
			t.Fatalf("factory DNS settings were not restored: %q", settings)
		}
	})
	f.execute("apply", func() (string, error) { return terraform.ApplyE(t, f.options) })
	f.settled("settled")
	settings, err := router.SSH(ctx, "/system/resource/print; /ip/dns/print")
	must(t, err)
	must(t, lab.Write(filepath.Join(runRoot, "router.txt"), settings))
	_, err = router.SSH(ctx, "/ip/dns/cache/flush")
	must(t, err)
	t.Cleanup(func() { _, err := router.SSH(context.Background(), "/ip/dns/cache/flush"); must(t, err) })
	remove, err := router.Forward(ctx, "udp", 0, 53, "")
	must(t, err)
	t.Cleanup(func() { must(t, remove()) })
	port, err := router.ForwardedPort(ctx, "udp", 53)
	must(t, err)
	query := func(name, kind, filename string) string {
		queryCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		output, err := router.Run(queryCtx, "dig", "@127.0.0.1", "-p", strconv.Itoa(port), name, kind, "+time=3", "+tries=1")
		must(t, lab.Write(filepath.Join(runRoot, filename), output))
		must(t, err)
		if !strings.Contains(output, "status: NOERROR") {
			t.Fatalf("DNS query failed; inspect %s", filename)
		}
		return output
	}
	host := "s3.eu-west-1.amazonaws.com"
	beforeRoots, beforeSOA, err := lab.NegativeReply(query(host, "AAAA", "before.txt"))
	must(t, err)
	must(t, lab.RootReply(query(".", "NS", "root-query.txt")))
	afterRoots, afterSOA, err := lab.NegativeReply(query(host, "AAAA", "after.txt"))
	must(t, err)
	summary := fmt.Sprintf("Before root query: root NS=%d, SOA=%d\nAfter root query: root NS=%d, SOA=%d\nReferral-shaped response change reproduced: %t\n", beforeRoots, beforeSOA, afterRoots, afterSOA, beforeRoots == 0 && afterRoots > 0 && afterSOA == 0)
	must(t, lab.Write(filepath.Join(runRoot, "summary.txt"), summary))
	t.Log(summary)
}
