package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const mainCommit = "1111111111111111111111111111111111111111"

// fixture runs the runner against a temporary state directory, recording every command.
type fixture struct {
	t        *testing.T
	dir      string
	deployer *deployer
	calls    [][]string
	// respond answers a captured command; activations go through failActivation.
	respond        func(args []string) (string, error)
	failActivation func(args []string) bool
	clock          time.Time
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	dir := t.TempDir()
	f := &fixture{t: t, dir: dir, clock: time.Unix(0, 0)}
	previous := filepath.Join(dir, "previous")
	if err := os.Mkdir(previous, 0o755); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(dir, "state")
	if err := os.Mkdir(state, 0o755); err != nil {
		t.Fatal(err)
	}
	f.deployer = &deployer{
		state:         state,
		booted:        previous,
		current:       previous,
		systemProfile: filepath.Join(dir, "system"),
		run: func(args ...string) (string, error) {
			f.calls = append(f.calls, args)
			return f.respond(args)
		},
		exec: func(args ...string) error {
			f.calls = append(f.calls, args)
			if f.failActivation != nil && f.failActivation(args) {
				return &exec.ExitError{}
			}
			return nil
		},
		now:   func() time.Time { return f.clock },
		sleep: func(d time.Duration) { f.clock = f.clock.Add(d) },
	}
	return f
}

func (f *fixture) path(name string) string { return filepath.Join(f.dir, name) }

// pin links the state's pending out-link to system, as nix build --out-link would.
func (f *fixture) pin(system string) {
	if err := os.Symlink(system, filepath.Join(f.deployer.state, "pending")); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) called(want ...string) bool {
	for _, call := range f.calls {
		if reflect.DeepEqual(call, want) {
			return true
		}
	}
	return false
}

func (f *fixture) index(prefix ...string) int {
	for i, call := range f.calls {
		if len(call) >= len(prefix) && reflect.DeepEqual(call[:len(prefix)], prefix) {
			return i
		}
	}
	return -1
}

func (f *fixture) status() map[string]any {
	f.t.Helper()
	data, err := os.ReadFile(filepath.Join(f.deployer.state, "status.json"))
	if err != nil {
		f.t.Fatal(err)
	}
	var status map[string]any
	if err := json.Unmarshal(data, &status); err != nil {
		f.t.Fatal(err)
	}
	return status
}

func darwinFixture(t *testing.T) (*fixture, settings, string) {
	f := newFixture(t)
	candidate := f.path("candidate")
	if err := os.Mkdir(candidate, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(f.deployer.current, filepath.Join(f.deployer.state, "current")); err != nil {
		t.Fatal(err)
	}
	f.respond = func(args []string) (string, error) {
		switch args[0] {
		case "git":
			return mainCommit + "\trefs/heads/main", nil
		case "nix":
			f.pin(candidate)
			return candidate, nil
		case "id":
			return "501", nil
		}
		return "", nil
	}
	return f, settings{
		Repository:    "upstream/config",
		Configuration: "agent-mac",
		BootMode:      "system",
		Platform:      "darwin",
		User:          "agent",
	}, candidate
}

func TestDarwinBuildsReviewedMainAndActivatesInLoginSession(t *testing.T) {
	f, s, candidate := darwinFixture(t)
	f.deployer.store = f.dir
	if err := f.deployer.deploy(s); err != nil {
		t.Fatal(err)
	}
	build := f.calls[f.index("nix")]
	if want := "github:upstream/config/" + mainCommit + "#darwinConfigurations.agent-mac.config.system.build.toplevel"; build[2] != want {
		t.Fatalf("built %q, want %q", build[2], want)
	}
	if !f.called("/bin/launchctl", "asuser", "501", filepath.Join(candidate, "activate")) {
		t.Fatalf("no activation in the login session: %v", f.calls)
	}
	for _, name := range []string{"pending", "base"} {
		if _, err := os.Lstat(filepath.Join(f.deployer.state, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s left behind: %v", name, err)
		}
	}
	if got := f.status()["state"]; got != "succeeded" {
		t.Fatalf("status %v", got)
	}
}

func TestDarwinFailedActivationRestoresProfileAndPreviousSystem(t *testing.T) {
	f, s, candidate := darwinFixture(t)
	f.deployer.store = f.dir
	f.failActivation = func(args []string) bool { return strings.HasPrefix(args[len(args)-1], candidate) }
	if err := f.deployer.deploy(s); err == nil {
		t.Fatal("deploy succeeded despite a failed activation")
	}
	if !f.called("nix-env", "--profile", f.deployer.systemProfile, "--set", f.deployer.current) {
		t.Fatalf("system profile not restored: %v", f.calls)
	}
	if !f.called("/bin/launchctl", "asuser", "501", filepath.Join(f.deployer.current, "activate")) {
		t.Fatalf("previous system not activated: %v", f.calls)
	}
	if got := f.status()["state"]; got != "failed" {
		t.Fatalf("status %v", got)
	}
}

func TestNativeFailedRollbackReportsBothErrors(t *testing.T) {
	f := newFixture(t)
	f.deployer.store = f.dir
	candidate := f.path("candidate")
	if err := os.Mkdir(candidate, 0o755); err != nil {
		t.Fatal(err)
	}
	f.respond = func(args []string) (string, error) {
		switch args[0] {
		case "git":
			return mainCommit + "\trefs/heads/main", nil
		case "nix":
			f.pin(candidate)
			return candidate, nil
		}
		return "", nil
	}
	f.failActivation = func([]string) bool { return true }
	if err := f.deployer.deploy(settings{Repository: "upstream/config", Configuration: "pannu", BootMode: "system"}); err == nil {
		t.Fatal("deploy succeeded")
	}
	if !f.called(filepath.Join(candidate, "bin/switch-to-configuration"), "switch") {
		t.Fatalf("native deploy did not switch: %v", f.calls)
	}
	status := f.status()
	if status["state"] != "rollback-failed" || status["error"] == nil || status["rollbackError"] == nil {
		t.Fatalf("status %v", status)
	}
}

func TestRejectsAnythingButOneMainCommit(t *testing.T) {
	for _, output := range []string{
		"",
		mainCommit + "\trefs/heads/agent-change",
		"abc\trefs/heads/main",
		mainCommit + "\trefs/heads/main\n" + mainCommit + "\trefs/heads/main",
	} {
		f := newFixture(t)
		f.respond = func(args []string) (string, error) {
			if args[0] == "git" {
				return output, nil
			}
			t.Fatalf("ran %v after an unresolved main", args)
			return "", nil
		}
		err := f.deployer.deploy(settings{Repository: "upstream/config", Configuration: "agents", BootMode: "host"})
		if err == nil || !strings.Contains(err.Error(), "Upstream main") {
			t.Fatalf("%q: %v", output, err)
		}
		if status := f.status(); status["state"] != "failed" {
			t.Fatalf("status %v", status)
		}
	}
}

const substituter = "http://10.83.0.5:5000?trusted=true"

func substitutedFixture(t *testing.T, missingPolls int) (*fixture, settings, string) {
	f := newFixture(t)
	system := f.path("nixos-system-ops")
	if err := os.Mkdir(system, 0o755); err != nil {
		t.Fatal(err)
	}
	f.deployer.store = f.dir
	f.respond = func(args []string) (string, error) {
		switch {
		case args[0] == "git":
			return mainCommit + "\trefs/heads/main", nil
		case args[0] == "nix" && args[1] == "eval":
			return system, nil
		case args[0] == "nix" && args[1] == "path-info":
			if missingPolls > 0 {
				missingPolls--
				return "", &exec.ExitError{}
			}
			return system, nil
		case args[0] == "nix" && args[1] == "build":
			f.pin(system)
			return system, nil
		}
		return "", nil
	}
	return f, settings{
		Repository:         "upstream/config",
		Configuration:      "ops",
		BootMode:           "system",
		WaitForSubstituter: substituter,
	}, system
}

func TestBuildsOnlyAfterTheSubstituterHoldsTheSystem(t *testing.T) {
	f, s, system := substitutedFixture(t, 3)
	if err := f.deployer.deploy(s); err != nil {
		t.Fatal(err)
	}
	reference := "github:upstream/config/" + mainCommit + "#nixosConfigurations.ops.config.system.build.toplevel"
	if !f.called("nix", "eval", "--raw", reference+".outPath") {
		t.Fatalf("system path not evaluated: %v", f.calls)
	}
	var polls []int
	for i, call := range f.calls {
		if len(call) > 1 && call[0] == "nix" && call[1] == "path-info" {
			polls = append(polls, i)
		}
	}
	if len(polls) != 4 {
		t.Fatalf("%d polls, want 4", len(polls))
	}
	last := polls[len(polls)-1]
	if want := []string{"nix", "path-info", "--option", "narinfo-cache-negative-ttl", "0", "--store", substituter, system}; !reflect.DeepEqual(f.calls[last], want) {
		t.Fatalf("poll %v, want %v", f.calls[last], want)
	}
	build := f.index("nix", "build")
	if build < last {
		t.Fatal("built before the substituter held the system")
	}
	// Download only: even derivations that never substitute, such as the toplevel.
	call := f.calls[build]
	if tail := call[len(call)-5:]; !reflect.DeepEqual(tail, []string{"--option", "always-allow-substitutes", "true", "--max-jobs", "0"}) {
		t.Fatalf("build %v is not download-only", call)
	}
	if got := f.status()["state"]; got != "succeeded" {
		t.Fatalf("status %v", got)
	}
}

func TestGivesUpWithoutBuildingWhenTheSubstituterNeverHoldsIt(t *testing.T) {
	f, s, _ := substitutedFixture(t, 1<<30)
	err := f.deployer.deploy(s)
	if err == nil || !strings.Contains(err.Error(), "rerun agent-deploy") {
		t.Fatalf("error %v", err)
	}
	if f.index("nix", "build") >= 0 {
		t.Fatal("built without the substituter holding the system")
	}
	if waited := f.clock.Sub(time.Unix(0, 0)); waited < substituteWait {
		t.Fatalf("gave up after %v", waited)
	}
	status := f.status()
	if status["state"] != "failed" || !strings.Contains(status["error"].(string), substituter) {
		t.Fatalf("status %v", status)
	}
}

func TestBuildsDirectlyWithoutASubstituterToWaitFor(t *testing.T) {
	f, s, _ := substitutedFixture(t, 0)
	s.WaitForSubstituter = ""
	if err := f.deployer.deploy(s); err != nil {
		t.Fatal(err)
	}
	if f.index("nix", "eval") >= 0 || f.index("nix", "path-info") >= 0 {
		t.Fatalf("waited for a substituter: %v", f.calls)
	}
	for _, argument := range f.calls[f.index("nix", "build")] {
		if argument == "--max-jobs" {
			t.Fatal("direct build is download-only")
		}
	}
}

func TestRejectsABuildThatIsNotOnePinnedStorePath(t *testing.T) {
	for _, tc := range []struct {
		name  string
		build func(f *fixture, system string) string
		store func(f *fixture) string
	}{
		{"outside the store", func(f *fixture, system string) string {
			f.pin(system)
			return system
		}, func(*fixture) string { return "/nix/store" }},
		{"several outputs", func(f *fixture, system string) string {
			f.pin(system)
			return system + "\n" + system
		}, func(f *fixture) string { return f.dir }},
		{"not the pinned output", func(f *fixture, system string) string {
			other := f.path("other-system")
			if err := os.Mkdir(other, 0o755); err != nil {
				t.Fatal(err)
			}
			f.pin(other)
			return system
		}, func(f *fixture) string { return f.dir }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, s, system := substitutedFixture(t, 0)
			s.WaitForSubstituter = ""
			f.deployer.store = tc.store(f)
			respond := f.respond
			f.respond = func(args []string) (string, error) {
				if args[0] == "nix" && args[1] == "build" {
					return tc.build(f, system), nil
				}
				return respond(args)
			}
			if err := f.deployer.deploy(s); err == nil || !strings.Contains(err.Error(), "single pinned system closure") {
				t.Fatalf("error %v", err)
			}
			for _, call := range f.calls {
				if strings.HasSuffix(call[0], "switch-to-configuration") || call[0] == "nix-env" {
					t.Fatalf("activated or set a profile: %v", call)
				}
			}
			if _, err := os.Lstat(filepath.Join(f.deployer.state, "pending")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("pending left behind: %v", err)
			}
			if got := f.status()["state"]; got != "failed" {
				t.Fatalf("status %v", got)
			}
		})
	}
}
