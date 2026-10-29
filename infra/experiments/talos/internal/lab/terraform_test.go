package lab

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestEmptyClustersBootWithoutConfigsAndKeepThemOutOfTheSource(t *testing.T) {
	f := &fake{}
	c := cluster(t, f)
	c.ControlPlanes, c.Workers, c.Empty = 3, 2, true
	args := strings.Join(c.CreateArgs(), " ")
	for _, want := range []string{"--controlplanes 3", "--workers 2", "--skip-injecting-config", "--wait=false"} {
		if !strings.Contains(args, want) {
			t.Errorf("create args lack %q: %s", want, args)
		}
	}
	if strings.Contains(args, "--config-patch") {
		t.Errorf("an empty cluster's patches would be unused: %s", args)
	}
	if err := c.Create(context.Background()); err != nil {
		t.Fatal(err)
	}
	// talosctl writes the configs it skips to its working directory.
	if dir := f.calls[slices.IndexFunc(f.calls, func(c Cmd) bool { return slices.Contains(c.Args, "create") })].Dir; dir != c.Path("generated") {
		t.Errorf("talosctl cluster create runs in %q", dir)
	}
	if f.ran(" kubeconfig --force") {
		t.Error("an empty cluster has no Kubernetes to fetch a kubeconfig from")
	}
}

func TestNodeIPsFollowTheProvisioner(t *testing.T) {
	c := &Cluster{ControlPlanes: 3, Workers: 2}
	controlPlanes, workers := c.NodeIPs()
	if !slices.Equal(controlPlanes, []string{"10.5.0.2", "10.5.0.3", "10.5.0.4"}) || !slices.Equal(workers, []string{"10.5.0.5", "10.5.0.6"}) {
		t.Fatalf("got %v %v", controlPlanes, workers)
	}
}

func TestTerraformKeepsStateAndDataInTheRun(t *testing.T) {
	f := &fake{}
	data := t.TempDir()
	tf := Terraform{Dir: "/source/fixture", Data: data, Run: f.run}
	if err := tf.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := tf.SetVars(map[string]any{"cni": "cilium"}); err != nil {
		t.Fatal(err)
	}
	if _, err := tf.Apply(context.Background(), "w1", NodeAddress("module.cluster", "worker", "w1")); err != nil {
		t.Fatal(err)
	}
	commands := f.commands()
	for _, want := range []string{
		"terraform -chdir=/source/fixture init -input=false -no-color -lockfile=readonly -backend-config=path=" + filepath.Join(data, "terraform.tfstate"),
		"terraform -chdir=/source/fixture apply -input=false -no-color -auto-approve -var-file=" + filepath.Join(data, "vars.tfvars.json") + ` -target=module.cluster.talos_machine.worker["w1"]`,
	} {
		if !slices.Contains(commands, want) {
			t.Errorf("missing %q in %v", want, commands)
		}
	}
	if !slices.Contains(f.calls[0].Env, "TF_DATA_DIR="+filepath.Join(data, "data")) {
		t.Errorf("working data outside the run: %v", f.calls[0].Env)
	}
	if _, err := os.Stat(filepath.Join(data, "apply-w1.log")); err != nil {
		t.Error(err)
	}
}
