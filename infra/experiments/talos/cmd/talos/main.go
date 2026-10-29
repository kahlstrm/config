package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/lab"
)

var scenarios = map[string]string{"netpol-baseline": "TestNetpolBaseline", "cilium": "TestCilium"}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func names() []string {
	keys := []string{}
	for name := range scenarios {
		keys = append(keys, name)
	}
	slices.Sort(keys)
	return keys
}

func run(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("talos", flag.ContinueOnError)
	state := flags.String("state", "", "state directory (default: $XDG_STATE_HOME/talos-lab)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	args = flags.Args()
	root, err := lab.StateRoot(*state)
	if err != nil {
		return err
	}
	switch {
	case len(args) == 1 && args[0] == "scenarios":
		fmt.Println(strings.Join(names(), "\n"))
		return nil
	case len(args) == 1 && args[0] == "cleanup":
		return cleanup(root)
	case len(args) == 2 && args[0] == "run":
		test, ok := scenarios[args[1]]
		if !ok {
			return fmt.Errorf("choose a scenario: %s", strings.Join(names(), ", "))
		}
		source, err := os.Getwd()
		if err != nil {
			return err
		}
		cmd := exec.CommandContext(ctx, "go", "test", "-tags=integration", "-count=1", "-v", "-timeout=40m", "-run=^"+test+"$", ".")
		cmd.Env = append(os.Environ(), "TALOS_LAB_SOURCE="+source, "TALOS_LAB_STATE="+root)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		// Let the test's own teardown finish on Ctrl-C.
		cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
		cmd.WaitDelay = 10 * time.Minute
		// The test destroys its cluster; this also covers a test binary killed first.
		return errors.Join(cmd.Run(), cleanup(root))
	default:
		return fmt.Errorf("usage: talos [--state PATH] run SCENARIO|scenarios|cleanup; scenarios: %s", strings.Join(names(), ", "))
	}
}

func cleanup(root string) error {
	unlock, err := lab.Lock(root)
	if err != nil {
		return err
	}
	return errors.Join(lab.Sweep(context.Background(), root, lab.Exec), unlock())
}
