package lab

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// Cmd is one external command. Env adds to a copy of the process environment
// from which every Kubernetes and Talos client configuration has been removed.
type Cmd struct {
	Name  string
	Args  []string
	Env   []string
	Stdin string
	// Dir is the working directory; empty means the current one.
	Dir string
}

type Runner func(context.Context, Cmd) (string, error)

// clientConfig lists variables that point kubectl, helm and talosctl at a
// cluster. They are never inherited, so a lab command cannot reach the cluster
// the caller is configured for.
var clientConfig = []string{"KUBECONFIG", "TALOSCONFIG"}

func Environ(base, extra []string) []string {
	env := []string{}
	for _, entry := range base {
		name, _, _ := strings.Cut(entry, "=")
		inherited := true
		for _, blocked := range clientConfig {
			if name == blocked {
				inherited = false
			}
		}
		if inherited {
			env = append(env, entry)
		}
	}
	return append(env, extra...)
}

func Exec(ctx context.Context, c Cmd) (string, error) {
	cmd := exec.CommandContext(ctx, c.Name, c.Args...)
	cmd.Env = Environ(os.Environ(), c.Env)
	cmd.Stdin = strings.NewReader(c.Stdin)
	cmd.Dir = c.Dir
	// sudo and talosctl start children; interrupt the group so none outlive us.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return stdout.String(), fmt.Errorf("%s %s: %w: %s", c.Name, strings.Join(c.Args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}
