// Command cni-pods recreates the pods that a switch to Cilium left on the
// previous pod network, through their owners. It runs kubectl with the
// caller's configuration; the Talos lab runs the same code on its clusters.
//
//	cni-pods plan [flags]       list the candidates and what would happen to each
//	cni-pods recreate [flags]   recreate them, then verify (needs CiliumEndpoint access)
//	cni-pods verify [flags]     wait until none is left and every workload is ready
//	cni-pods verify -cni flannel
//	                            after a rollback: wait until Flannel and kube-proxy
//	                            run on every node, nothing of Cilium is left and
//	                            every workload is ready
//	cni-pods clear-stale-ceps [-cep namespace/name,...]
//	                            delete CiliumEndpoints whose owner pod is gone,
//	                            with UID and resourceVersion preconditions
//	                            (needs CiliumEndpoint delete rights)
//	cni-pods endpoints [-allow namespace/pod,...]
//	                            join CiliumEndpoints to the running pod-network pods
//	                            and compare them per node; fails on any mismatch
//	                            (needs CiliumEndpoint access)
//
// Flags may come before or after the command; anything else is an error.
// -include takes pod keys, namespace/pod, not owners: name the pod of a Job.
// With -cni0=talos (the default), talosctl with the caller's configuration
// finds the nodes whose Flannel cni0 bridge is still up; read-only access
// suffices.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
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

const usage = "usage: cni-pods plan|recreate|verify|endpoints|clear-stale-ceps [-include namespace/pod,...] [-allow namespace/pod,...] [-cep namespace/name,...] [-timeout 10m] [-cni0 talos|none] [-cni cilium|flannel]"

// invocation is a parsed command line.
type invocation struct {
	command string
	include []string
	allow   []string
	ceps    []string
	timeout time.Duration
	cni0    string
	cni     string
}

// parse reads the command and its flags, which may come before or after it.
// It rejects anything left over, as Go's flag package would otherwise stop
// at the command and ignore the flags after it.
func parse(args []string) (invocation, error) {
	flags := flag.NewFlagSet("cni-pods", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	include := flags.String("include", "", "comma-separated pod keys, namespace/pod, of report-only pods to recreate anyway")
	timeout := flags.Duration("timeout", 10*time.Minute, "limit for each wait")
	cni0 := flags.String("cni0", "talos", "how to find nodes whose Flannel cni0 bridge is still up: talos or none")
	cni := flags.String("cni", "cilium", "the CNI verify expects: cilium, or flannel after a rollback")
	allow := flags.String("allow", "", "comma-separated pod keys, namespace/pod, that endpoints accepts without a CiliumEndpoint")
	ceps := flags.String("cep", "", "comma-separated CiliumEndpoints, namespace/name, that clear-stale-ceps limits itself to")
	if err := flags.Parse(args); err != nil {
		return invocation{}, fmt.Errorf("%w\n%s", err, usage)
	}
	if flags.NArg() == 0 {
		return invocation{}, errors.New(usage)
	}
	inv := invocation{command: flags.Arg(0)}
	if err := flags.Parse(flags.Args()[1:]); err != nil {
		return invocation{}, fmt.Errorf("%w\n%s", err, usage)
	}
	if flags.NArg() > 0 {
		return invocation{}, fmt.Errorf("unexpected argument %q after %s\n%s", flags.Arg(0), inv.command, usage)
	}
	switch inv.command {
	case "plan", "recreate", "verify", "endpoints", "clear-stale-ceps":
	default:
		return invocation{}, fmt.Errorf("unknown command %q\n%s", inv.command, usage)
	}
	if *cni0 != "talos" && *cni0 != "none" {
		return invocation{}, fmt.Errorf("-cni0 is talos or none, not %q", *cni0)
	}
	if *cni != "cilium" && *cni != "flannel" {
		return invocation{}, fmt.Errorf("-cni is cilium or flannel, not %q", *cni)
	}
	if *cni == "flannel" && inv.command != "verify" {
		return invocation{}, fmt.Errorf("-cni flannel is for verify only")
	}
	for _, list := range []struct {
		flag  string
		value string
		into  *[]string
	}{{"include", *include, &inv.include}, {"allow", *allow, &inv.allow}, {"cep", *ceps, &inv.ceps}} {
		if list.value == "" {
			continue
		}
		*list.into = strings.Split(list.value, ",")
		for _, key := range *list.into {
			if namespace, name, ok := strings.Cut(key, "/"); !ok || namespace == "" || name == "" || strings.Contains(name, "/") {
				return invocation{}, fmt.Errorf("-%s takes pod keys, namespace/pod, not %q", list.flag, key)
			}
		}
	}
	if len(inv.allow) > 0 && inv.command != "endpoints" {
		return invocation{}, fmt.Errorf("-allow is for endpoints only")
	}
	if len(inv.ceps) > 0 && inv.command != "clear-stale-ceps" {
		return invocation{}, fmt.Errorf("-cep is for clear-stale-ceps only")
	}
	inv.timeout, inv.cni0, inv.cni = *timeout, *cni0, *cni
	return inv, nil
}

func run(ctx context.Context, args []string) error {
	inv, err := parse(args)
	if err != nil {
		return err
	}
	opts := cnipods.Options{Timeout: inv.timeout, Log: os.Stdout, Include: inv.include}
	if inv.cni0 == "talos" {
		opts.CNI0 = cnipods.TalosCNI0(func(ctx context.Context, args ...string) (string, error) { return command(ctx, "talosctl", args...) })
	}
	switch {
	case inv.command == "clear-stale-ceps":
		return cnipods.ClearStaleCEPs(ctx, kubectl, inv.ceps, os.Stdout)
	case inv.command == "plan":
		gathered, err := cnipods.Gather(ctx, kubectl, opts.CNI0)
		if err != nil {
			return err
		}
		fmt.Print(cnipods.Classify(gathered))
		return nil
	case inv.command == "endpoints":
		report, err := cnipods.Endpoints(ctx, kubectl, inv.allow)
		if err != nil {
			return err
		}
		fmt.Print(report)
		if problems := report.Problems(); len(problems) > 0 {
			return fmt.Errorf("%d endpoint problems", len(problems))
		}
		return nil
	case inv.command == "recreate":
		_, _, err := cnipods.Run(ctx, kubectl, opts)
		return err
	case inv.cni == "flannel":
		return cnipods.VerifyFlannel(ctx, kubectl, opts)
	default:
		_, err := cnipods.Verify(ctx, kubectl, opts)
		return err
	}
}
