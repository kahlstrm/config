package lab

import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
)

// NodeIPs are the addresses talosctl's QEMU provisioner gives the nodes:
// control planes from ControlPlaneIP on, then workers.
func (c *Cluster) NodeIPs() (controlPlanes, workers []string) {
	ip := netip.MustParseAddr(ControlPlaneIP)
	next := func() string {
		current := ip.String()
		ip = ip.Next()
		return current
	}
	for range max(c.ControlPlanes, 1) {
		controlPlanes = append(controlPlanes, next())
	}
	for range max(c.Workers, 1) {
		workers = append(workers, next())
	}
	return controlPlanes, workers
}

// Terraform runs the configuration in Dir with its working data, variables
// and local state under Data, so the source tree stays clean.
type Terraform struct {
	Dir  string
	Data string
	Run  Runner
}

func (t Terraform) command(ctx context.Context, args ...string) (string, error) {
	return t.Run(ctx, Cmd{Name: "terraform", Args: append([]string{"-chdir=" + t.Dir}, args...), Env: []string{"TF_DATA_DIR=" + filepath.Join(t.Data, "data"), "TF_IN_AUTOMATION=1"}})
}

func (t Terraform) varFile() string { return filepath.Join(t.Data, "vars.tfvars.json") }

func (t Terraform) Init(ctx context.Context) error {
	if err := os.MkdirAll(t.Data, 0700); err != nil {
		return err
	}
	_, err := t.command(ctx, "init", "-input=false", "-no-color", "-lockfile=readonly", "-backend-config=path="+filepath.Join(t.Data, "terraform.tfstate"))
	return err
}

// SetVars replaces the variables later commands use.
func (t Terraform) SetVars(vars map[string]any) error {
	data, err := json.MarshalIndent(vars, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(t.varFile(), data, 0600)
}

// Apply applies the configuration, limited to targets if any, and keeps the
// output in apply-<label>.log under Data.
func (t Terraform) Apply(ctx context.Context, label string, targets ...string) (string, error) {
	args := []string{"apply", "-input=false", "-no-color", "-auto-approve", "-var-file=" + t.varFile()}
	for _, target := range targets {
		args = append(args, "-target="+target)
	}
	output, err := t.command(ctx, args...)
	if writeErr := os.WriteFile(filepath.Join(t.Data, "apply-"+label+".log"), []byte(output), 0600); writeErr != nil && err == nil {
		err = writeErr
	}
	return output, err
}

// Changes reports whether a plan has changes, with the plan's output.
func (t Terraform) Changes(ctx context.Context) (bool, string, error) {
	output, err := t.command(ctx, "plan", "-input=false", "-no-color", "-detailed-exitcode", "-var-file="+t.varFile())
	if err != nil && strings.Contains(err.Error(), "exit status 2") {
		return true, output, nil
	}
	return false, output, err
}

func (t Terraform) Output(ctx context.Context, name string) (string, error) {
	return t.command(ctx, "output", "-raw", name)
}

// NodeAddress is the talos_machine resource address of a node in the
// talos-cluster module, for -target.
func NodeAddress(module, role, hostname string) string {
	return fmt.Sprintf("%s.talos_machine.%s[%q]", module, role, hostname)
}
