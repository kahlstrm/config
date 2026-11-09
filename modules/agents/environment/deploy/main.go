// Command agent-deploy-runner applies a fixed system configuration from the upstream main
// branch. Its settings are fixed at build time; callers choose only deploy or restore.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// The host checks upstream main every few minutes, then builds every environment.
const (
	substituteWait = 30 * time.Minute
	substitutePoll = 30 * time.Second
)

var commit = regexp.MustCompile(`^[0-9a-f]{40}$`)

type settings struct {
	Repository         string `json:"repository"`
	Configuration      string `json:"configuration"`
	BootMode           string `json:"bootMode"`
	Platform           string `json:"platform"`
	User               string `json:"user"`
	WaitForSubstituter string `json:"waitForSubstituter"`
}

func (s settings) platform() string {
	if s.Platform == "" {
		return "nixos"
	}
	return s.Platform
}

type deployer struct {
	state, booted, current, systemProfile, store string
	// run captures a command's standard output; exec lets an activation print as it goes.
	run   func(args ...string) (string, error)
	exec  func(args ...string) error
	now   func() time.Time
	sleep func(time.Duration)
}

func (d *deployer) setProfile(profile, system string) error {
	_, err := d.run("nix-env", "--profile", profile, "--set", system)
	return err
}

// link points destination at target, replacing it atomically.
func link(target, destination string) error {
	temporary := destination + ".new"
	if err := os.Remove(temporary); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := os.Symlink(target, temporary); err != nil {
		return err
	}
	return os.Rename(temporary, destination)
}

// status records progress in status.json; revision is null until main resolves.
func (d *deployer) status(state string, revision *string, details map[string]string) error {
	record := map[string]any{"state": state}
	if revision != nil || state != "building" && state != "restore-failed" {
		record["revision"] = revision
	}
	for key, value := range details {
		record[key] = value
	}
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	temporary := filepath.Join(d.state, "status.new")
	if err := os.WriteFile(temporary, append(data, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(temporary, filepath.Join(d.state, "status.json"))
}

func sameTarget(a, b string) (bool, error) {
	resolvedA, err := filepath.EvalSymlinks(a)
	if err != nil {
		return false, err
	}
	resolvedB, err := filepath.EvalSymlinks(b)
	if err != nil {
		return false, err
	}
	return resolvedA == resolvedB, nil
}

func sameContents(a, b string) (bool, error) {
	contentsA, err := os.ReadFile(a)
	if err != nil {
		return false, err
	}
	contentsB, err := os.ReadFile(b)
	if err != nil {
		return false, err
	}
	return bytes.Equal(contentsA, contentsB), nil
}

// compatible refuses a VM system whose boot or host-coupled parts differ from the booted image.
func compatible(system, baseline string) error {
	for _, name := range []string{"kernel", "initrd", "kernel-modules"} {
		same, err := sameTarget(filepath.Join(system, name), filepath.Join(baseline, name))
		if err != nil || !same {
			return fmt.Errorf("%s changed; an operator must deploy the VM boot image", name)
		}
	}
	for _, check := range []struct{ file, what string }{
		{"agent-boot-parameters", "boot parameters"},
		{"agent-host-configuration", "host configuration"},
	} {
		same, err := sameContents(filepath.Join(system, check.file), filepath.Join(baseline, check.file))
		if err != nil {
			return err
		}
		if !same {
			return fmt.Errorf("%s changed; an operator must deploy the VM boot image", check.what)
		}
	}
	return nil
}

// restore reactivates the last deployed VM userspace at boot, unless the boot image changed.
func (d *deployer) restore() error {
	saved := filepath.Join(d.state, "current")
	if _, err := os.Stat(saved); err != nil {
		return nil
	}
	// A new operator-provided boot image takes precedence over saved userspace.
	if same, err := sameTarget(filepath.Join(d.state, "base"), d.booted); err != nil || !same {
		return nil
	}
	baseline, err := filepath.EvalSymlinks(d.current)
	if err != nil {
		return err
	}
	failure := func() error {
		system, err := filepath.EvalSymlinks(saved)
		if err != nil {
			return err
		}
		booted, err := filepath.EvalSymlinks(d.booted)
		if err != nil {
			return err
		}
		if err := compatible(system, booted); err != nil {
			return err
		}
		_, err = d.run(filepath.Join(saved, "activate"))
		return err
	}()
	if failure == nil {
		return nil
	}
	if _, err := d.run(filepath.Join(baseline, "activate")); err != nil {
		return err
	}
	if err := d.status("restore-failed", nil, map[string]string{"error": failure.Error()}); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Saved environment failed; restored boot image: %v\n", failure)
	return nil
}

// waitForSubstitute waits until the substituter holds the system, so building it only downloads.
func (d *deployer) waitForSubstitute(reference, substituter string, revision *string) error {
	if err := d.status("waiting", revision, map[string]string{"substituter": substituter}); err != nil {
		return err
	}
	system, err := d.run("nix", "eval", "--raw", reference+".outPath")
	if err != nil {
		return err
	}
	deadline := d.now().Add(substituteWait)
	for {
		// Nix otherwise remembers a miss for an hour and never sees the system arrive.
		_, err := d.run("nix", "path-info", "--option", "narinfo-cache-negative-ttl", "0", "--store", substituter, system)
		if err == nil {
			return nil
		}
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			return err
		}
		if !d.now().Before(deadline) {
			return fmt.Errorf("%s did not provide %s within %d minutes; rerun agent-deploy once the host has built upstream main",
				substituter, system, int(substituteWait.Minutes()))
		}
		d.sleep(substitutePoll)
	}
}

func (d *deployer) activate(system string, s settings) error {
	if s.platform() == "darwin" {
		// Activate inside the agent's login session so launchd reloads its user agents.
		uid, err := d.run("id", "-u", s.User)
		if err != nil {
			return err
		}
		return d.exec("/bin/launchctl", "asuser", uid, filepath.Join(system, "activate"))
	}
	action := "test"
	if s.BootMode == "system" {
		action = "switch"
	}
	return d.exec(filepath.Join(system, "bin/switch-to-configuration"), action)
}

// resolveMain returns the single commit upstream main points at.
func (d *deployer) resolveMain(repository string) (string, error) {
	output, err := d.run("git", "ls-remote", "--exit-code", "https://github.com/"+repository+".git", "refs/heads/main")
	if err != nil {
		return "", err
	}
	fields := strings.Fields(output)
	if len(fields) != 2 || fields[1] != "refs/heads/main" || !commit.MatchString(fields[0]) {
		return "", errors.New("Upstream main did not resolve to one commit")
	}
	return fields[0], nil
}

// build builds the system and checks it is one store path, pinned by the pending out-link.
func (d *deployer) build(reference string, extra []string) (string, error) {
	pending := filepath.Join(d.state, "pending")
	output, err := d.run(append([]string{"nix", "build", reference, "--out-link", pending, "--print-out-paths"}, extra...)...)
	if err != nil {
		return "", err
	}
	invalid := errors.New("Build did not produce a single pinned system closure")
	if strings.Contains(output, "\n") {
		return "", invalid
	}
	candidate, err := filepath.EvalSymlinks(output)
	if err != nil {
		return "", invalid
	}
	pinned, err := filepath.EvalSymlinks(pending)
	if err != nil || filepath.Dir(candidate) != d.store || candidate != pinned {
		return "", invalid
	}
	return candidate, nil
}

func (d *deployer) deploy(s settings) (err error) {
	var revision *string
	native := s.BootMode == "system"
	activated, profileChanged := false, false
	defer func() {
		if removeErr := os.Remove(filepath.Join(d.state, "pending")); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) && err == nil {
			err = removeErr
		}
	}()
	previous, err := filepath.EvalSymlinks(d.current)
	if err != nil {
		return d.fail(revision, err)
	}
	attempt := func() error {
		if err := d.status("building", nil, nil); err != nil {
			return err
		}
		resolved, err := d.resolveMain(s.Repository)
		if err != nil {
			return err
		}
		revision = &resolved
		reference := fmt.Sprintf("github:%s/%s#%sConfigurations.%s.config.system.build.toplevel",
			s.Repository, resolved, s.platform(), s.Configuration)
		var downloadOnly []string
		if s.WaitForSubstituter != "" {
			if err := d.waitForSubstitute(reference, s.WaitForSubstituter, revision); err != nil {
				return err
			}
			if err := d.status("building", revision, nil); err != nil {
				return err
			}
			// Fetch even derivations marked local-only, such as the toplevel, and never build.
			downloadOnly = []string{"--option", "always-allow-substitutes", "true", "--max-jobs", "0"}
		}
		candidate, err := d.build(reference, downloadOnly)
		if err != nil {
			return err
		}
		if native {
			if err := d.setProfile(d.systemProfile, candidate); err != nil {
				return err
			}
			profileChanged = true
		} else {
			booted, err := filepath.EvalSymlinks(d.booted)
			if err != nil {
				return err
			}
			if err := compatible(candidate, booted); err != nil {
				return err
			}
		}
		if err := d.status("activating", revision, nil); err != nil {
			return err
		}
		activated = true
		if err := d.activate(candidate, s); err != nil {
			return err
		}
		if err := d.setProfile(filepath.Join(d.state, "current"), candidate); err != nil {
			return err
		}
		if s.platform() == "nixos" {
			booted, err := filepath.EvalSymlinks(d.booted)
			if err != nil {
				return err
			}
			if err := link(booted, filepath.Join(d.state, "base")); err != nil {
				return err
			}
		}
		return d.status("succeeded", revision, map[string]string{"system": candidate})
	}
	failure := attempt()
	if failure == nil {
		return nil
	}
	if activated || profileChanged {
		if rollbackErr := d.rollBack(previous, native, s); rollbackErr != nil {
			if err := d.status("rollback-failed", revision, map[string]string{
				"error":         failure.Error(),
				"rollbackError": rollbackErr.Error(),
			}); err != nil {
				return errors.Join(failure, rollbackErr, err)
			}
			return fmt.Errorf("rollback after %v failed: %w", failure, rollbackErr)
		}
	}
	return d.fail(revision, failure)
}

func (d *deployer) rollBack(previous string, native bool, s settings) error {
	if native {
		if err := d.setProfile(d.systemProfile, previous); err != nil {
			return err
		}
	}
	if err := d.activate(previous, s); err != nil {
		return err
	}
	current := filepath.Join(d.state, "current")
	if _, err := os.Stat(current); err == nil {
		return d.setProfile(current, previous)
	}
	return nil
}

func (d *deployer) fail(revision *string, failure error) error {
	if err := d.status("failed", revision, map[string]string{"error": failure.Error()}); err != nil {
		return errors.Join(failure, err)
	}
	return failure
}

func capture(args ...string) (string, error) {
	command := exec.Command(args[0], args[1:]...)
	command.Stderr = os.Stderr
	output, err := command.Output()
	if err != nil {
		return "", fmt.Errorf("%s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(output)), nil
}

func stream(args ...string) error {
	command := exec.Command(args[0], args[1:]...)
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("%s: %w", strings.Join(args, " "), err)
	}
	return nil
}

func main() {
	if err := runMain(os.Args); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runMain(args []string) error {
	if os.Geteuid() != 0 {
		return errors.New("Deployment runner requires root")
	}
	if len(args) != 3 || (args[2] != "deploy" && args[2] != "restore") {
		return errors.New("Expected fixed configuration and deploy or restore action")
	}
	data, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	var s settings
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	d := &deployer{
		state:         "/nix/var/nix/profiles/agent-deploy",
		booted:        "/run/booted-system",
		current:       "/run/current-system",
		systemProfile: "/nix/var/nix/profiles/system",
		store:         "/nix/store",
		run:           capture,
		exec:          stream,
		now:           time.Now,
		sleep:         time.Sleep,
	}
	if err := os.MkdirAll(d.state, 0o755); err != nil {
		return err
	}
	if args[2] == "restore" {
		return d.restore()
	}
	return d.deploy(s)
}
