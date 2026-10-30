package lab

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	avdName     = "t3-mobile-lab"
	systemImage = "system-images;android-36;google_apis;x86_64"
	consolePort = 5560
)

// Device is the lab's headless Android emulator.
type Device struct {
	SDK, AndroidHome, Serial string
	emulator                 *exec.Cmd
	exited                   chan error
}

// StartDevice boots a freshly wiped emulator whose AVD lives under home.
func StartDevice(ctx context.Context, sdk, home, logPath string) (*Device, error) {
	d := &Device{SDK: sdk, AndroidHome: home, Serial: "emulator-" + strconv.Itoa(consolePort)}
	if err := d.ensureAVD(ctx); err != nil {
		return nil, err
	}
	log, err := os.Create(logPath)
	if err != nil {
		return nil, err
	}
	defer log.Close()
	d.emulator = exec.Command(filepath.Join(sdk, "emulator", "emulator"), "-avd", avdName,
		"-no-window", "-no-audio", "-no-snapshot", "-no-boot-anim", "-wipe-data",
		// The emulator rewrites config.ini's data disk size on launch, sizing it
		// from free space; this image's minimum is 6 GiB.
		"-partition-size", "6144",
		"-gpu", "swiftshader_indirect", "-port", strconv.Itoa(consolePort))
	d.emulator.Env = d.env()
	d.emulator.Stdout, d.emulator.Stderr = log, log
	d.emulator.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := d.emulator.Start(); err != nil {
		return nil, err
	}
	d.exited = make(chan error, 1)
	go func() { d.exited <- d.emulator.Wait() }()
	deadline := time.Now().Add(6 * time.Minute)
	for time.Now().Before(deadline) {
		if out, err := d.ADB(ctx, "shell", "getprop", "sys.boot_completed"); err == nil && strings.TrimSpace(string(out)) == "1" {
			return d, nil
		}
		select {
		case err := <-d.exited:
			d.emulator = nil
			return nil, fmt.Errorf("emulator exited during boot (%v); see %s", err, logPath)
		case <-ctx.Done():
			return nil, errors.Join(ctx.Err(), d.Stop())
		case <-time.After(3 * time.Second):
		}
	}
	return nil, errors.Join(fmt.Errorf("emulator did not boot; see %s", logPath), d.Stop())
}

func (d *Device) env() []string {
	return append(os.Environ(),
		"ANDROID_HOME="+d.SDK, "ANDROID_SDK_ROOT="+d.SDK,
		"ANDROID_USER_HOME="+d.AndroidHome, "ANDROID_AVD_HOME="+filepath.Join(d.AndroidHome, "avd"))
}

func (d *Device) ensureAVD(ctx context.Context) error {
	config := filepath.Join(d.AndroidHome, "avd", avdName+".avd", "config.ini")
	if _, err := os.Stat(config); err != nil {
		manager, err := filepath.Glob(filepath.Join(d.SDK, "cmdline-tools", "*", "bin", "avdmanager"))
		if err != nil || len(manager) == 0 {
			return fmt.Errorf("no avdmanager in %s", d.SDK)
		}
		create := exec.CommandContext(ctx, manager[0], "create", "avd", "--force", "--name", avdName, "--package", systemImage)
		create.Env = d.env()
		create.Stdin = strings.NewReader("no\n")
		if out, err := create.CombinedOutput(); err != nil {
			return fmt.Errorf("create AVD: %w: %s", err, out)
		}
	}
	// A phone-sized screen.
	// Applied on every start because the emulator rewrites the file.
	current, err := os.ReadFile(config)
	if err != nil {
		return err
	}
	return os.WriteFile(config, []byte(overrideConfig(string(current), map[string]string{
		"hw.lcd.width": "1080", "hw.lcd.height": "2400", "hw.lcd.density": "420",
		"hw.ramSize": "4096", "hw.keyboard": "yes",
	})), 0o644)
}

// overrideConfig replaces keys in an AVD config.ini, whose writers differ in
// spacing around "=" and whose readers take the first of duplicate keys.
func overrideConfig(current string, settings map[string]string) string {
	var lines []string
	for _, line := range strings.Split(strings.TrimSpace(current), "\n") {
		key, _, _ := strings.Cut(line, "=")
		if _, overridden := settings[strings.TrimSpace(key)]; !overridden {
			lines = append(lines, line)
		}
	}
	for _, key := range slices.Sorted(maps.Keys(settings)) {
		lines = append(lines, key+"="+settings[key])
	}
	return strings.Join(lines, "\n") + "\n"
}

// ADB runs an adb command against the lab emulator.
func (d *Device) ADB(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(d.SDK, "platform-tools", "adb"), append([]string{"-s", d.Serial}, args...)...)
	cmd.Env = d.env()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("adb %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// Shell runs a device shell command.
func (d *Device) Shell(ctx context.Context, args ...string) error {
	_, err := d.ADB(ctx, append([]string{"shell"}, args...)...)
	return err
}

// Install replaces the app with the APK. Pushing first avoids adb's streamed
// install, which hangs on this emulator.
func (d *Device) Install(ctx context.Context, apk string) error {
	if _, err := d.ADB(ctx, "push", apk, "/data/local/tmp/app.apk"); err != nil {
		return err
	}
	out, err := d.ADB(ctx, "shell", "pm", "install", "-r", "/data/local/tmp/app.apk")
	if err != nil || !strings.Contains(string(out), "Success") {
		return fmt.Errorf("install %s: %w: %s", apk, err, out)
	}
	return nil
}

// Screenshot saves the screen as a PNG.
func (d *Device) Screenshot(ctx context.Context, path string) error {
	png, err := d.ADB(ctx, "exec-out", "screencap", "-p")
	if err != nil {
		return err
	}
	return os.WriteFile(path, png, 0o644)
}

// Stop shuts the emulator down.
func (d *Device) Stop() error {
	if d.emulator == nil || d.emulator.Process == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_, _ = d.ADB(ctx, "emu", "kill")
	select {
	case <-d.exited:
		return nil
	case <-time.After(30 * time.Second):
		return syscall.Kill(-d.emulator.Process.Pid, syscall.SIGKILL)
	}
}
