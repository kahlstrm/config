//go:build integration

package t3mobile_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/kahlstrm/config/infra/experiments/t3-mobile/internal/lab"
)

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// eachVariant builds every app variant, boots one emulator and server, and
// runs check on each variant with a freshly installed and paired app.
func eachVariant(t *testing.T, scenario string, check func(t *testing.T, ctx context.Context, s *lab.Session, variant string)) {
	for _, binary := range []string{"t3", "ss", "git", "pnpm", "java"} {
		_, err := exec.LookPath(binary)
		must(t, err)
	}
	file, err := os.OpenFile("/dev/kvm", os.O_RDWR, 0)
	must(t, err)
	must(t, file.Close())
	ctx := t.Context()
	source, state := os.Getenv("T3_MOBILE_SOURCE"), os.Getenv("T3_MOBILE_STATE")
	if source == "" || state == "" {
		t.Fatal("run through `just t3-mobile run SCENARIO`")
	}
	sdk, err := lab.SDK()
	must(t, err)
	must(t, os.MkdirAll(state, 0o700))
	log, err := os.Create(filepath.Join(state, "build.log"))
	must(t, err)
	defer log.Close()
	builder := &lab.Builder{Source: source, State: state, SDK: sdk, Log: log}
	apks := map[string]string{}
	for _, variant := range lab.VariantNames() {
		apks[variant], err = builder.APK(ctx, variant)
		must(t, err)
	}
	must(t, builder.Prune())
	session, err := lab.NewSession(ctx, state, scenario)
	must(t, err)
	t.Cleanup(func() { must(t, session.Close()) })
	t.Logf("evidence: %s", session.Dir)
	for _, variant := range lab.VariantNames() {
		t.Run(variant, func(t *testing.T) {
			_ = session.Device.Shell(ctx, "pm", "uninstall", lab.Package)
			must(t, session.Device.Install(ctx, apks[variant]))
			must(t, session.Device.Pair(ctx, session.Server))
			must(t, session.Record(ctx, variant+"-paired", "paired with %s", lab.EmulatorAddress))
			check(t, ctx, session, variant)
		})
	}
}

// TestResume reopens the app after a minute in the background.
func TestResume(t *testing.T) {
	eachVariant(t, "resume", func(t *testing.T, ctx context.Context, s *lab.Session, variant string) {
		d := s.Device
		must(t, d.Home(ctx))
		must(t, lab.Sleep(ctx, time.Minute))
		must(t, d.Launch(ctx))
		must(t, lab.WaitConnected(ctx, 20*time.Second))
		must(t, lab.Sleep(ctx, 5*time.Second))
		state, err := d.Observe(ctx)
		must(t, err)
		must(t, s.Record(ctx, variant+"-resumed", "%s", state))
		if state.Offline {
			t.Errorf("%s: connected but still shows %q", variant, lab.OfflineLabel)
		}
	})
}

// TestBlockedResume reopens the app while Android still blocks its
// background network, then lifts the block. Android 15 and later block
// background apps' network and lift the block shortly after the app returns
// to the foreground; the lab fixes that order instead of racing for it.
func TestBlockedResume(t *testing.T) {
	expectStuck := map[string]bool{"upstream": true, "blocked-status-fix": false}
	eachVariant(t, "blocked-resume", func(t *testing.T, ctx context.Context, s *lab.Session, variant string) {
		d := s.Device
		must(t, d.Home(ctx))
		must(t, lab.Sleep(ctx, 3*time.Second))
		must(t, d.SetNetworkBlocked(ctx, true))
		must(t, lab.Sleep(ctx, 20*time.Second))
		must(t, d.Launch(ctx))
		must(t, lab.Sleep(ctx, 3*time.Second))
		blocked, err := d.Observe(ctx)
		must(t, err)
		must(t, s.Record(ctx, variant+"-reopened-blocked", "%s", blocked))
		if !blocked.Offline {
			t.Fatalf("%s: the app did not read the network while blocked, so the scenario did not set up the race", variant)
		}
		must(t, d.SetNetworkBlocked(ctx, false))
		must(t, lab.Sleep(ctx, 30*time.Second))
		after, err := d.Observe(ctx)
		must(t, err)
		must(t, s.Record(ctx, variant+"-unblocked-30s", "%s", after))
		stuck := after.Offline && after.Connections == 0
		recovered := !after.Offline && after.Connections > 0
		switch {
		case expectStuck[variant] && !stuck:
			t.Errorf("%s recovered (%s); the bug no longer reproduces at this revision", variant, after)
		case !expectStuck[variant] && !recovered:
			t.Errorf("%s did not reconnect (%s)", variant, after)
		}
	})
}
