package cnipods

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// CaptureDiagnostics preserves complete objects and agent state without
// credentials. It continues after individual failures, recording those too.
func CaptureDiagnostics(ctx context.Context, k Kubectl, directory string) error {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	var errs []error
	run := func(name string, args ...string) {
		out, err := k(ctx, args...)
		if err != nil {
			errs = append(errs, err)
			out += fmt.Sprintf("\nERROR: %v\n", err)
		}
		if err := os.WriteFile(filepath.Join(directory, name), []byte(out), 0600); err != nil {
			errs = append(errs, err)
		}
	}
	run("ceps.json", "get", "ciliumendpoints.cilium.io", "-A", "-o", "json")
	run("pods.json", "get", "pods", "-A", "-o", "json")
	run("events.json", "get", "events", "-A", "-o", "json")
	var agents podList
	if err := get(ctx, k, &agents, "-n", "kube-system", "get", "pods", "-l", agentSelector, "-o", "json"); err != nil {
		errs = append(errs, err)
	}
	for _, agent := range agents.Items {
		name := agent.Metadata.Name
		for _, command := range []struct {
			file string
			args []string
		}{
			{"endpoints.json", []string{"endpoint", "list", "-o", "json"}},
			{"status.log", []string{"status", "--verbose"}},
		} {
			args := append([]string{"-n", "kube-system", "exec", name, "-c", "cilium-agent", "--", "cilium-dbg"}, command.args...)
			run(name+"-"+command.file, args...)
		}
		run(name+"-agent.log", "-n", "kube-system", "logs", name, "-c", "cilium-agent", "--tail=1000")
	}
	return errors.Join(errs...)
}
