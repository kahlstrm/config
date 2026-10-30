package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/kahlstrm/config/infra/experiments/t3-mobile/internal/lab"
)

var scenarios = map[string]string{
	"resume":         "TestResume",
	"blocked-resume": "TestBlockedResume",
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func names() []string {
	names := make([]string, 0, len(scenarios))
	for name := range scenarios {
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}

func run(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("t3-mobile", flag.ContinueOnError)
	state := flags.String("state", "", "state directory (default: $XDG_STATE_HOME/t3-mobile-lab)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	args = flags.Args()
	root, err := lab.StateRoot(*state)
	if err != nil {
		return err
	}
	source, err := os.Getwd()
	if err != nil {
		return err
	}
	usage := fmt.Errorf("usage: t3-mobile [--state PATH] scenarios|build VARIANT|run SCENARIO; scenarios: %s; variants: %s",
		strings.Join(names(), ", "), strings.Join(lab.VariantNames(), ", "))
	switch {
	case len(args) == 1 && args[0] == "scenarios":
		fmt.Println(strings.Join(names(), "\n"))
		return nil
	case len(args) == 2 && args[0] == "build":
		sdk, err := lab.SDK()
		if err != nil {
			return err
		}
		if err := os.MkdirAll(root, 0o700); err != nil {
			return err
		}
		log, err := os.Create(filepath.Join(root, "build.log"))
		if err != nil {
			return err
		}
		defer log.Close()
		apk, err := (&lab.Builder{Source: source, State: root, SDK: sdk, Log: log}).APK(ctx, args[1])
		if err == nil {
			fmt.Println(apk)
		}
		return err
	case len(args) == 2 && args[0] == "run":
		test, ok := scenarios[args[1]]
		if !ok {
			return usage
		}
		cmd := exec.CommandContext(ctx, "go", "test", "-tags=integration", "-count=1", "-v", "-timeout=150m", "-run=^"+test+"$", ".")
		cmd.Env = append(os.Environ(), "T3_MOBILE_SOURCE="+source, "T3_MOBILE_STATE="+root)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		// Let the test stop its emulator and server on Ctrl-C.
		cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
		cmd.WaitDelay = time.Minute
		return cmd.Run()
	default:
		return usage
	}
}
