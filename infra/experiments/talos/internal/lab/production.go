package lab

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Production locates the configuration the lab consumes from the production
// layers, so the lab follows every version bump and patch change.
type Production struct{ Infra string }

func (p Production) Path(parts ...string) string {
	return filepath.Join(append([]string{p.Infra}, parts...)...)
}

type Versions struct {
	Talos      string `json:"talos"`
	Kubernetes string `json:"kubernetes"`
}

var talosRelease = regexp.MustCompile(`^v\d+\.\d+\.\d+$`)
var kubernetesRelease = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

func (p Production) Versions() (Versions, error) {
	data, err := os.ReadFile(p.Path("local-talos", "versions.json"))
	if err != nil {
		return Versions{}, err
	}
	var v Versions
	if err := json.Unmarshal(data, &v); err != nil {
		return Versions{}, err
	}
	if !talosRelease.MatchString(v.Talos) || !kubernetesRelease.MatchString(v.Kubernetes) {
		return Versions{}, fmt.Errorf("unexpected versions in versions.json: %+v", v)
	}
	return v, nil
}

var contract = regexp.MustCompile(`(?m)^\s*talos_config_version\s*=\s*"(v\d+\.\d+\.\d+)"`)

// ConfigContract is the Talos version production generates machine configs
// for. It differs from the running version, and selects the config style.
func (p Production) ConfigContract() (string, error) {
	data, err := os.ReadFile(p.Path("local-talos", "main.tf"))
	if err != nil {
		return "", err
	}
	match := contract.FindSubmatch(data)
	if match == nil {
		return "", errors.New("talos_config_version not found in local-talos/main.tf")
	}
	return string(match[1]), nil
}

// Patches are production Talos patches that apply to a QEMU lab. The others
// configure hardware or identity the lab lacks:
//   - openebs-worker.yaml reserves 2 GiB of hugepages and a host mount for Mayastor.
//   - nvidia-worker.yaml loads GPU modules.
//   - templates/ set install disks, hostnames, the API VIP, the service-account
//     issuer and user volumes on disk serials.
//   - flux.tf would make the lab reconcile the production repository.
type Patches struct{ All, ControlPlane, Worker []string }

func (p Production) Patches(networkPolicy bool) (Patches, error) {
	patch := func(name string) string { return p.Path("local-talos", "patches", name) }
	patches := Patches{
		ControlPlane: []string{patch("openebs-controlplane.yaml"), patch("metrics-controlplane.yaml")},
		Worker:       []string{patch("metrics-worker.yaml"), patch("containerd-worker.yaml")},
	}
	if networkPolicy {
		patches.ControlPlane = append(patches.ControlPlane, patch("network-policy-controlplane.yaml"))
	}
	for _, path := range append(append([]string{}, patches.ControlPlane...), patches.Worker...) {
		if _, err := os.Stat(path); err != nil {
			return Patches{}, err
		}
	}
	return patches, nil
}

func (p Patches) With(other Patches) Patches {
	return Patches{
		All:          append(append([]string{}, p.All...), other.All...),
		ControlPlane: append(append([]string{}, p.ControlPlane...), other.ControlPlane...),
		Worker:       append(append([]string{}, p.Worker...), other.Worker...),
	}
}

var image = regexp.MustCompile(`(?m)^\s*image:\s*(\S+)\s*$`)

// CanaryImage is the probe image the production NetworkPolicy canary runs.
func (p Production) CanaryImage() (string, error) {
	data, err := os.ReadFile(p.Path("local-kubernetes", "platform", "netpol-canary", "cronjob.yaml"))
	if err != nil {
		return "", err
	}
	match := image.FindSubmatch(data)
	if match == nil {
		return "", errors.New("no image in the netpol-canary CronJob")
	}
	return string(match[1]), nil
}

// PodNetworkPolicy is the production policy that limits a namespace to the pod
// network; agent-sandbox uses the same shape.
func (p Production) PodNetworkPolicy() string {
	return p.Path("local-kubernetes", "platform", "netpol-canary", "network-policy.yaml")
}

// Abs resolves patch paths so talosctl reads them from any directory.
func (p Patches) Abs() (Patches, error) {
	abs := func(paths []string) ([]string, error) {
		resolved := []string{}
		for _, path := range paths {
			path, err := filepath.Abs(path)
			if err != nil {
				return nil, err
			}
			resolved = append(resolved, path)
		}
		return resolved, nil
	}
	all, err := abs(p.All)
	if err != nil {
		return Patches{}, err
	}
	controlPlane, err := abs(p.ControlPlane)
	if err != nil {
		return Patches{}, err
	}
	worker, err := abs(p.Worker)
	return Patches{All: all, ControlPlane: controlPlane, Worker: worker}, err
}

var (
	fluxOperatorVersion = regexp.MustCompile(`(?m)^\s*flux_operator_version\s*=\s*"([^"]+)"`)
	fluxOperatorURL     = regexp.MustCompile(`"(https://[^"]*\$\{local\.flux_operator_version\}[^"]*)"`)
)

// FluxBootstrap renders production's Flux bootstrap patch from
// local-talos/flux.tf: the Flux Operator as a Talos extra manifest and the
// FluxInstance as an inline manifest. The lab's FluxInstance has no sync, so
// Flux installs only what a scenario applies, not this repository.
func (p Production) FluxBootstrap() ([]byte, error) {
	tf, err := os.ReadFile(p.Path("local-talos", "flux.tf"))
	if err != nil {
		return nil, err
	}
	version, url := fluxOperatorVersion.FindSubmatch(tf), fluxOperatorURL.FindSubmatch(tf)
	if version == nil || url == nil {
		return nil, errors.New("flux operator version or URL not found in local-talos/flux.tf")
	}
	instance, err := os.ReadFile(p.Path("local-talos", "manifests", "flux-instance.yaml"))
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{"cluster": map[string]any{
		"extraManifests":  []string{strings.ReplaceAll(string(url[1]), "${local.flux_operator_version}", string(version[1]))},
		"inlineManifests": []any{map[string]string{"name": "flux-instance", "contents": WithoutSync(string(instance))}},
	}})
}

// WithoutSync drops the top-level spec.sync block from a FluxInstance.
func WithoutSync(manifest string) string {
	kept, skipping := []string{}, false
	for _, line := range strings.Split(manifest, "\n") {
		nested := strings.HasPrefix(line, "   ") || strings.TrimSpace(line) == ""
		switch {
		case line == "  sync:":
			skipping = true
		case skipping && nested:
		default:
			skipping = false
			kept = append(kept, line)
		}
	}
	return strings.Join(kept, "\n")
}

// UserVolume renders production's user volume template for a disk serial.
func (p Production) UserVolume(name, serial string) ([]byte, error) {
	data, err := os.ReadFile(p.Path("local-talos", "templates", "user-volume.yaml.tmpl"))
	if err != nil {
		return nil, err
	}
	return []byte(strings.NewReplacer("${name}", name, "${disk_serial}", serial).Replace(string(data))), nil
}

// Kubernetes returns a path in local-kubernetes.
func (p Production) Kubernetes(parts ...string) string {
	return p.Path(append([]string{"local-kubernetes"}, parts...)...)
}
