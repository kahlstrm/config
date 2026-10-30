package lab

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

// Upstream pins the T3 Code revision the lab builds.
type Upstream struct {
	Repository string `json:"repository"`
	Revision   string `json:"revision"`
}

// Variants maps each buildable app to the lab patches applied to upstream.
var Variants = map[string][]string{
	"upstream": nil,
	// expo-network re-reads the network when Android lifts a background block.
	"blocked-status-fix": {"expo-network-blocked-status.patch"},
}

// VariantNames lists the variants in a stable order.
func VariantNames() []string {
	names := make([]string, 0, len(Variants))
	for name := range Variants {
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}

// Builder builds release APKs for the emulator from a pinned checkout.
type Builder struct {
	Source, State, SDK string
	Log                *os.File
}

// LoadUpstream reads t3code.json from the lab source.
func LoadUpstream(source string) (Upstream, error) {
	var upstream Upstream
	data, err := os.ReadFile(filepath.Join(source, "t3code.json"))
	if err != nil {
		return upstream, err
	}
	return upstream, json.Unmarshal(data, &upstream)
}

// APK returns the variant's APK, building it unless the revision's build exists.
func (b *Builder) APK(ctx context.Context, variant string) (string, error) {
	patches, ok := Variants[variant]
	if !ok {
		return "", fmt.Errorf("unknown variant %q; choose from %s", variant, strings.Join(VariantNames(), ", "))
	}
	upstream, err := LoadUpstream(b.Source)
	if err != nil {
		return "", err
	}
	apk := filepath.Join(b.State, "apks", upstream.Revision[:12]+"-"+variant+".apk")
	if _, err := os.Stat(apk); err == nil {
		return apk, nil
	}
	checkout := filepath.Join(b.State, "t3code")
	if err := b.checkout(ctx, upstream, checkout); err != nil {
		return "", err
	}
	for _, patch := range patches {
		if err := b.run(ctx, checkout, nil, "git", "apply", filepath.Join(b.Source, "patches", patch)); err != nil {
			return "", err
		}
	}
	// A patched dependency changes its lockfile hash.
	lockfile := "--frozen-lockfile"
	if len(patches) > 0 {
		lockfile = "--no-frozen-lockfile"
	}
	mobile := filepath.Join(checkout, "apps", "mobile")
	env := []string{
		"ANDROID_HOME=" + b.SDK, "ANDROID_SDK_ROOT=" + b.SDK, "CI=1",
		"NODE_ENV=production", "APP_VARIANT=production", "EXPO_NO_GIT_STATUS=1",
	}
	steps := []struct {
		dir  string
		args []string
	}{
		// nixpkgs' Node can trail the patch release upstream's engines field names.
		{checkout, []string{"pnpm", "install", lockfile, "--filter", "@t3tools/mobile...", "--config.engine-strict=false"}},
		{mobile, []string{"pnpm", "exec", "expo", "prebuild", "--clean", "--platform", "android", "--no-install"}},
		// x86_64 only, for the emulator. Minification only shrinks the Java side
		// and needs several more GiB of disk.
		{filepath.Join(mobile, "android"), []string{"./gradlew", "--no-daemon", "assembleRelease",
			"-PreactNativeArchitectures=x86_64",
			"-Pandroid.enableMinifyInReleaseBuilds=false",
			"-Pandroid.enableShrinkResourcesInReleaseBuilds=false",
			// Gradle's own aapt2 download is a dynamically linked binary.
			"-Pandroid.aapt2FromMavenOverride=" + filepath.Join(b.SDK, "build-tools", "37.0.0", "aapt2")}},
	}
	for _, step := range steps {
		if err := b.run(ctx, step.dir, env, step.args...); err != nil {
			return "", err
		}
	}
	if err := os.MkdirAll(filepath.Dir(apk), 0o700); err != nil {
		return "", err
	}
	built := filepath.Join(mobile, "android", "app", "build", "outputs", "apk", "release", "app-release.apk")
	return apk, b.run(ctx, checkout, nil, "cp", built, apk)
}

// checkout resets the shared checkout to the pinned revision, keeping
// node_modules and Gradle outputs between variants.
func (b *Builder) checkout(ctx context.Context, upstream Upstream, dir string) error {
	if _, err := os.Stat(filepath.Join(dir, ".git")); err != nil {
		if err := b.run(ctx, b.State, nil, "git", "clone", "--filter=blob:none", "--no-checkout", upstream.Repository, dir); err != nil {
			return err
		}
	}
	if err := b.run(ctx, dir, nil, "git", "fetch", "--filter=blob:none", "origin", upstream.Revision); err != nil {
		return err
	}
	return b.run(ctx, dir, nil, "git", "checkout", "--force", "--detach", upstream.Revision)
}

func (b *Builder) run(ctx context.Context, dir string, env []string, args ...string) error {
	fmt.Fprintf(b.Log, "\n$ (cd %s && %s)\n", dir, strings.Join(args, " "))
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), env...)
	cmd.Stdout, cmd.Stderr = b.Log, b.Log
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w; see %s", strings.Join(args, " "), err, b.Log.Name())
	}
	return nil
}

// Prune deletes the checkout's Gradle and CMake outputs once the APKs exist,
// so the emulator's 6 GiB data disk fits beside the dependencies. A later
// build of another revision or variant recompiles the native modules.
func (b *Builder) Prune() error {
	checkout := filepath.Join(b.State, "t3code")
	var outputs []string
	for _, pattern := range []string{
		"apps/mobile/android/build", "apps/mobile/android/app/build", "apps/mobile/android/app/.cxx",
		"node_modules/.pnpm/*/node_modules/*/android/build", "node_modules/.pnpm/*/node_modules/*/android/.cxx",
		"node_modules/.pnpm/*/node_modules/@*/*/android/build", "node_modules/.pnpm/*/node_modules/@*/*/android/.cxx",
	} {
		matches, err := filepath.Glob(filepath.Join(checkout, pattern))
		if err != nil {
			return err
		}
		outputs = append(outputs, matches...)
	}
	for _, output := range outputs {
		if err := os.RemoveAll(output); err != nil {
			return err
		}
	}
	return nil
}
