package lab

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// StateRoot resolves the lab's state directory.
func StateRoot(override string) (string, error) {
	if override != "" {
		return filepath.Abs(override)
	}
	if root := os.Getenv("XDG_STATE_HOME"); root != "" {
		return filepath.Join(root, "t3-mobile-lab"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "state", "t3-mobile-lab"), nil
}

// SDK is the Android SDK the Nix shell provides.
func SDK() (string, error) {
	sdk := os.Getenv("ANDROID_HOME")
	if sdk == "" {
		return "", errors.New("ANDROID_HOME is unset; run inside `nix develop .#t3-mobile`")
	}
	return sdk, nil
}

// Session is one run: an emulator and a server, with evidence under Dir.
type Session struct {
	Dir    string
	Device *Device
	Server *Server
	report *os.File
}

// NewSession boots the emulator and server for a run under state/runs.
func NewSession(ctx context.Context, state, scenario string) (*Session, error) {
	sdk, err := SDK()
	if err != nil {
		return nil, err
	}
	dir := filepath.Join(state, "runs", scenario, time.Now().UTC().Format("20060102T150405Z"))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	report, err := os.Create(filepath.Join(dir, "results.txt"))
	if err != nil {
		return nil, err
	}
	s := &Session{Dir: dir, report: report}
	if s.Server, err = StartServer(ctx, filepath.Join(dir, "server")); err != nil {
		return nil, errors.Join(err, s.Close())
	}
	if s.Device, err = StartDevice(ctx, sdk, filepath.Join(state, "android"), filepath.Join(dir, "emulator.log")); err != nil {
		return nil, errors.Join(err, s.Close())
	}
	return s, nil
}

// Record writes a line to results.txt and a screenshot named after the step.
func (s *Session) Record(ctx context.Context, step, format string, args ...any) error {
	line := fmt.Sprintf("%s %s: %s", time.Now().UTC().Format(time.TimeOnly), step, fmt.Sprintf(format, args...))
	fmt.Println(line)
	if _, err := fmt.Fprintln(s.report, line); err != nil {
		return err
	}
	return s.Device.Screenshot(ctx, filepath.Join(s.Dir, step+".png"))
}

// Close stops the emulator and server.
func (s *Session) Close() error {
	var errs []error
	if s.Device != nil {
		errs = append(errs, s.Device.Stop())
	}
	if s.Server != nil {
		errs = append(errs, s.Server.Stop())
	}
	return errors.Join(append(errs, s.report.Close())...)
}
