# T3 mobile lab

Builds T3 Code's Android app from upstream source, runs it on a headless
emulator against a throwaway T3 server, and drives it through `adb` to test
how it reconnects. Each scenario runs once per app variant: `upstream`, the
pinned revision as published, and variants with the lab's patches applied.

## Running

Requires x86_64 Linux, `/dev/kvm`, about 6 GiB of free RAM, about 20 GiB of free
disk for the first build (checkout and dependencies 6 GiB, Gradle cache 6 GiB,
build outputs 3 GiB) and 8 GiB afterwards for the emulator, HTTPS
access to GitHub, npm and Maven, and `t3` on `PATH`. The lab's server is that
`t3`, the agent environment's own package. From `infra/`:

```sh
nix develop .#t3-mobile --command just t3-mobile run blocked-resume
nix develop .#t3-mobile --command just t3-mobile run resume
nix develop .#t3-mobile --command just t3-mobile build upstream
```

The Nix shell pins the Android SDK ([android.nix](android.nix): build tools,
NDK, CMake and an Android 16 emulator image), JDK 17, Node, pnpm and Go.
[t3code.json](t3code.json) pins the T3 Code revision. Bump the SDK versions
with react-native's `gradle/libs.versions.toml` when bumping the revision.

`build VARIANT` checks the revision out under the state directory, installs the
mobile app's dependencies with pnpm, applies the variant's patches from
[patches](patches) and builds an x86_64 release APK with Gradle, without
minification. Scenarios build missing APKs first; each revision and variant
builds once. Once the APKs exist, scenarios delete the checkout's Gradle and
CMake outputs, because the emulator's 6 GiB data disk needs 7.2 GiB free to
create. The emulator's data is wiped on
every boot, and the app is reinstalled and paired with the lab's server for
every variant. Release builds
ignore pairing links, so the lab fills in the app's manual pairing form.

State lives under `$XDG_STATE_HOME/t3-mobile-lab` (default `~/.local/state`);
use `--state PATH` to override. Each run keeps `results.txt`, a screenshot per
step, and the emulator and server logs under `runs/<scenario>/<time>/`.

A scenario reads two signals: the home screen's "You are offline" header, which
the app shows only while `expo-network` reports no network, and the server's
established connections (`ss`).

Vet, test and check the helper's formatting, without the Android SDK, with:

```sh
nix build .#checks.x86_64-linux.t3-mobile-lab --no-link -L
```

## Scenarios

- `resume` backgrounds the app for a minute and reopens it. Every variant must
  reconnect within 20 seconds without the offline header.
- `blocked-resume` reproduces the app staying on "You are offline" after it is
  reopened. Android 15 and later block a background app's network
  (`blocked=APP_BACKGROUND` in `dumpsys netpolicy`) and lift the block shortly
  after the app returns to the foreground. If the app reads its network state
  before the block lifts, `expo-network` reports no network, because
  `ConnectivityManager.getActiveNetwork()` returns null for a blocked app.
  Android reports the lift only through `NetworkCallback.onBlockedStatusChanged`,
  which `expo-network` does not implement, so the app never learns the network
  is back. Its connection supervisor waits for an online report before
  connecting, and only reopening the app again recovers it.

  The scenario fixes the race's order with Android's debugging firewall chain
  (`cmd connectivity set-package-networking-enabled`): it blocks the app in
  the background, reopens it, checks that the app shows the offline header,
  lifts the block and checks the app 30 seconds later. `upstream` must stay
  offline with no connection; the test fails if it recovers, so a revision bump
  shows when upstream fixes it. `blocked-status-fix` must reconnect.

## Variants

- `blocked-status-fix` adds `onBlockedStatusChanged` to T3's existing
  `expo-network` patch, so `expo-network` re-reads the network when the block
  changes ([patch](patches/expo-network-blocked-status.patch)).

Add a variant by adding a patch against the T3 Code repository to
[patches](patches) and an entry to `Variants` in
[internal/lab/build.go](internal/lab/build.go).
