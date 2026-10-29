package lab

import (
	"context"
	"encoding/json"
	"os"
	"regexp"
	"time"
)

func (c *Cluster) Kubectl(ctx context.Context, stdin string, args ...string) (string, error) {
	return c.Run(ctx, Cmd{Name: "kubectl", Args: append([]string{"--kubeconfig", c.Kubeconfig()}, args...), Env: c.ClientEnv(), Stdin: stdin})
}

func (c *Cluster) Talos(ctx context.Context, args ...string) (string, error) {
	return c.Run(ctx, Cmd{Name: c.Talosctl(), Args: append([]string{"--talosconfig", c.Talosconfig()}, args...), Env: c.ClientEnv()})
}

// RenderCiliumPatch renders a Helm chart into a control-plane patch that
// installs it through cluster.inlineManifests, with later values files
// overriding earlier ones.
func RenderCiliumPatch(ctx context.Context, run Runner, chart, home, patch string, values ...string) error {
	env := []string{"HOME=" + home, "HELM_CACHE_HOME=" + home + "/cache", "HELM_CONFIG_HOME=" + home + "/config", "HELM_DATA_HOME=" + home + "/data"}
	args := []string{"template", "cilium", chart, "--namespace", "kube-system"}
	for _, file := range values {
		args = append(args, "-f", file)
	}
	manifest, err := run(ctx, Cmd{Name: "helm", Args: args, Env: env})
	if err != nil {
		return err
	}
	// JSON is YAML, so talosctl reads this as a strategic merge patch.
	data, err := json.Marshal(map[string]any{"cluster": map[string]any{"inlineManifests": []any{map[string]string{"name": "cilium", "contents": manifest}}}})
	if err != nil {
		return err
	}
	return os.WriteFile(patch, data, 0600)
}

var manifestChange = regexp.MustCompile(`(?m)^\s*< (\w+) (\S+/\S+)\s*$`)

// ManifestChanges groups the objects in `talosctl upgrade-k8s` output by what
// happened to them: Pruned (dry run), deleted, created, configured or
// unchanged.
func ManifestChanges(output string) map[string][]string {
	changes := map[string][]string{}
	for _, match := range manifestChange.FindAllStringSubmatch(output, -1) {
		changes[match[1]] = append(changes[match[1]], match[2])
	}
	return changes
}

func Sleep(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
