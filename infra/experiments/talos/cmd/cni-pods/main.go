// Command cni-pods recreates the pods that a switch to Cilium left on the
// previous pod network, through their owners. It runs kubectl with the
// caller's configuration; the Talos lab runs the same code on its clusters.
//
//	cni-pods plan       list the candidates and what would happen to each
//	cni-pods recreate   recreate them, then verify (needs CiliumEndpoint access)
//	cni-pods verify     wait until none is left and every workload is ready
//
// With -cni0=talos (the default), talosctl with the caller's configuration
// finds the nodes whose Flannel cni0 bridge is still up; read-only access
// suffices.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/kahlstrm/config/infra/experiments/talos/internal/cnipods"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func kubectl(ctx context.Context, args ...string) (string, error) {
	return command(ctx, "kubectl", args...)
}

func command(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		return string(output), fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return string(output), nil
}

func run(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("cni-pods", flag.ContinueOnError)
	include := flags.String("include", "", "comma-separated namespace/name of report-only pods to recreate anyway")
	timeout := flags.Duration("timeout", 10*time.Minute, "limit for each wait")
	bridges := flags.String("cni0", "talos", "how to find nodes whose Flannel cni0 bridge is still up: talos or none")
	if err := flags.Parse(args); err != nil {
		return err
	}
	opts := cnipods.Options{Timeout: *timeout, Log: os.Stdout}
	switch *bridges {
	case "talos":
		opts.CNI0 = cnipods.TalosCNI0(func(ctx context.Context, args ...string) (string, error) { return command(ctx, "talosctl", args...) })
	case "none":
	default:
		return fmt.Errorf("-cni0 is talos or none, not %q", *bridges)
	}
	if *include != "" {
		opts.Include = strings.Split(*include, ",")
	}
	switch flags.Arg(0) {
	case "plan":
		inv, err := cnipods.Gather(ctx, kubectl, opts.CNI0)
		if err != nil {
			return err
		}
		fmt.Print(cnipods.Classify(inv))
		return nil
	case "recreate":
		_, _, err := cnipods.Run(ctx, kubectl, opts)
		return err
	case "verify":
		_, err := cnipods.Verify(ctx, kubectl, opts)
		return err
	}
	return fmt.Errorf("usage: cni-pods [-include ns/name,...] [-timeout 10m] [-cni0 talos|none] plan|recreate|verify")
}
