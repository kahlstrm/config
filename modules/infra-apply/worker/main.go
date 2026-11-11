// infra-apply-worker plans and applies one infra/ layer from merged main, with that layer's own
// GCP key, in the root-owned units that ../default.nix defines. The layer is its only argument.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"syscall"
)

// project, the bucket and the repository are where every layer's backend and code live.
var (
	project     = "infra-464520"
	stateBucket = "terraform-state-1751317459"
	repository  = "kahlstrm/config"
)

// The layer this run works on, its state directory and its account, set by load.
var (
	layer          string
	stateDirectory string
	account        layerConfig
)

// layerConfig is one entry of the layers file that ../default.nix writes.
type layerConfig struct {
	ServiceAccount string `json:"serviceAccount"`
	KeyID          string `json:"keyId"`
}

const usage = `usage:
  infra-apply-worker plan LAYER          plan infra/LAYER at merged main and save the plan
  infra-apply-worker apply LAYER         apply the saved plan if main has not moved since
  infra-apply-worker credentials LAYER   create the layer's GCP key once and write its key file`

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "infra-apply:", err)
		os.Exit(1)
	}
}

var layerName = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// load reads the layer's entry from the layers file in INFRA_APPLY_LAYERS, refusing any layer
// the file does not list, and sets its state directory.
func load(name string) error {
	if !layerName.MatchString(name) {
		return fmt.Errorf("%q is not a layer name", name)
	}
	data, err := os.ReadFile(os.Getenv("INFRA_APPLY_LAYERS"))
	if err != nil {
		return fmt.Errorf("the layers file: %w", err)
	}
	var layers map[string]layerConfig
	if err := json.Unmarshal(data, &layers); err != nil {
		return fmt.Errorf("the layers file: %w", err)
	}
	config, ok := layers[name]
	if !ok {
		return fmt.Errorf("%s is not a layer this host applies", name)
	}
	layer, account = name, config
	stateDirectory = os.Getenv("STATE_DIRECTORY")
	if stateDirectory == "" {
		return errors.New("STATE_DIRECTORY is not set; run this through its systemd unit")
	}
	return nil
}

func run(ctx context.Context, args []string) error {
	if len(args) != 2 {
		return errors.New(usage)
	}
	if err := load(args[1]); err != nil {
		return err
	}
	// Not under the lock, so a deploy that changes the key ID can rewrite the key file while
	// a run holds it; the file is replaced in one rename.
	if args[0] == "credentials" {
		return credentials(stateDirectory, account.ServiceAccount, account.KeyID)
	}
	unlock, err := lock()
	if err != nil {
		return err
	}
	defer unlock()
	switch args[0] {
	case "plan":
		return planCommand(ctx)
	case "apply":
		return applyCommand(ctx)
	}
	return errors.New(usage)
}

// lock keeps runs on one layer from overlapping; the kernel releases it when a run dies.
func lock() (func(), error) {
	file, err := os.OpenFile(filepath.Join(stateDirectory, "lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, fmt.Errorf("another plan or apply of %s is in progress", layer)
	}
	return func() { file.Close() }, nil
}

func keyFile() string           { return filepath.Join(stateDirectory, "gcp.json") }
func checkoutDirectory() string { return filepath.Join(stateDirectory, "config") }
func metaPath() string          { return filepath.Join(stateDirectory, "plan.json") }
func planPath() string          { return filepath.Join(stateDirectory, "plan.tfplan") }

// appliedPath records the commit of the last apply that finished cleanly, so the next plan
// knows which merged PRs it covers.
func appliedPath() string { return filepath.Join(stateDirectory, "applied") }

// planMeta is saved next to the plan file for apply.
type planMeta struct {
	Commit string `json:"commit"`
	PRs    []int  `json:"prs"`
}

func readMeta() (planMeta, error) {
	var meta planMeta
	data, err := os.ReadFile(metaPath())
	if errors.Is(err, os.ErrNotExist) {
		return meta, fmt.Errorf("no saved plan; run infra-apply plan %s first", layer)
	}
	if err != nil {
		return meta, err
	}
	return meta, json.Unmarshal(data, &meta)
}
