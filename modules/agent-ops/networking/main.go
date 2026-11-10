// ops-networking runs the ops runner's privileged infra/local-networking work with the
// runner's own GCP key: plans and applies of merged PRs, and edits of Secret Manager secrets.
// See modules/agent-ops/runner.nix.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

// runtimeDirectory and project come from runner.nix at build time; the bucket and
// repository are local-networking's backend and this repository.
var (
	runtimeDirectory = "/run/ops-networking"
	project          = "infra-464520"
	stateBucket      = "terraform-state-1751317459"
	repository       = "kahlstrm/config"
)

const usage = `usage:
  ops-networking plan --pr N       plan infra/local-networking at merged main for PR N
  ops-networking apply             apply the saved plan behind RouterOS dead-man switches
  ops-networking secret-edit SECRET [--remove PATH] [--generate PATH=token|password]
                                   [--from-env PATH=VARIABLE]...
                                   write a new version of a Secret Manager secret`

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "ops-networking:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	// Only the secrets of the layers the runner manages; never sops_age_key or the others.
	if args[0] == "secret-edit" && len(args) > 1 && args[1] != "local-networking" && args[1] != "local-kubernetes" {
		return fmt.Errorf("%s: only local-networking and local-kubernetes may be edited", args[1])
	}
	unlock, err := lock()
	if err != nil {
		return err
	}
	defer unlock()
	switch args[0] {
	case "plan":
		flags := flag.NewFlagSet("plan", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		pr := flags.Int("pr", 0, "the merged PR whose rollout this plan is for")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		if *pr <= 0 || flags.NArg() != 0 {
			return errors.New(usage)
		}
		return planCommand(ctx, *pr)
	case "apply":
		if len(args) != 1 {
			return errors.New(usage)
		}
		return applyCommand(ctx)
	case "secret-edit":
		return secretEditCommand(ctx, args[1:])
	}
	return errors.New(usage)
}

// lock keeps runs of this tool from overlapping; the kernel releases it when a run dies.
func lock() (func(), error) {
	file, err := os.OpenFile(filepath.Join(runtimeDirectory, "lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, errors.New("another ops-networking run is in progress")
	}
	return func() { file.Close() }, nil
}

func keyFile() string { return filepath.Join(runtimeDirectory, "gcp.json") }

func secretEditCommand(ctx context.Context, args []string) error {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return errors.New(usage)
	}
	secret := args[0]
	var edits []edit
	flags := flag.NewFlagSet("secret-edit", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	for _, name := range []string{"remove", "generate", "from-env"} {
		flags.Func(name, "property change", func(spec string) error {
			e, err := parseEdit(name, spec)
			edits = append(edits, e)
			return err
		})
	}
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 || len(edits) == 0 {
		return errors.New(usage)
	}
	seen := map[string]bool{}
	for _, e := range edits {
		if seen[e.String()] {
			return fmt.Errorf("%s: changed twice", e)
		}
		seen[e.String()] = true
	}
	g, err := newGCP(ctx, keyFile())
	if err != nil {
		return err
	}
	data, version, err := g.accessSecret(ctx, project, secret)
	if err != nil {
		return fmt.Errorf("read %s: %w", secret, err)
	}
	updated, report, err := editSecret(data, edits, os.Getenv)
	if err != nil {
		return fmt.Errorf("%s version %s: %w", secret, version, err)
	}
	added, err := g.addSecretVersion(ctx, project, secret, updated)
	if err != nil {
		return fmt.Errorf("write %s: %w", secret, err)
	}
	fmt.Printf("%s: version %s → %s: %s.\n", secret, version, added, strings.Join(report, ", "))
	fmt.Println("Values were not printed. Apply the layer that reads the secret for the change to take effect.")
	return nil
}

// planMeta is saved next to the plan file for apply.
type planMeta struct {
	PR     int    `json:"pr"`
	Commit string `json:"commit"`
	Dir    string `json:"dir"`
}

func metaPath() string { return filepath.Join(runtimeDirectory, "plan.json") }
func planPath() string { return filepath.Join(runtimeDirectory, "plan.tfplan") }

func readMeta() (planMeta, error) {
	var meta planMeta
	data, err := os.ReadFile(metaPath())
	if errors.Is(err, os.ErrNotExist) {
		return meta, errors.New("no saved plan; run ops-networking plan --pr N first")
	}
	if err != nil {
		return meta, err
	}
	return meta, json.Unmarshal(data, &meta)
}
