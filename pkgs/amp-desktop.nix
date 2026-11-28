# Amp's Linux desktop app, published as a .deb in Amp's apt repository
# (ampcode.com/app). The current version and its SHA-256 are in
# https://static.ampcode.com/linux/dists/stable/main/binary-amd64/Packages;
# pkgs/amp-desktop-update.sh bumps both.
# The app is a JavaScript bundle with no native modules, so it runs on
# nixpkgs' Electron of the same major version as the one it ships with, and
# the bundle is the same for every architecture.
#
# The app shows its passkey sheet only when it finds amp-passkey-helper,
# which the .deb ships prebuilt for x86_64 next to app.asar. It is built here
# from source, at the version the .deb bundles (named in the .deb's
# opt/amp/resources/amp-passkey-helper.NOTICE), and the wrapper points
# AMP_PASSKEY_HELPER at it. It needs no privileges: the phone flow talks to
# BlueZ over D-Bus (hardware.bluetooth.enable), and systemd's udev rules give
# the logged-in user the /dev/hidraw* of a USB security key.
{
  lib,
  stdenvNoCC,
  fetchurl,
  fetchFromGitHub,
  rustPlatform,
  pkg-config,
  dbus,
  dpkg,
  makeWrapper,
  electron_44,
  xdg-utils,
  systemd,
  glib,
  gnome-session,
  writeShellScript,
}:
let
  passkeyHelper = rustPlatform.buildRustPackage (finalAttrs: {
    pname = "amp-passkey-helper";
    version = "0.2.0";

    src = fetchFromGitHub {
      owner = "ampcode";
      repo = "amp-passkey-helper";
      tag = "v${finalAttrs.version}";
      hash = "sha256-PC7NrswUVHfSt1pJgKTMQdMHmWoZ8vGhzD1Fd55j3NU=";
    };

    cargoHash = "sha256-/G05TaqxKdV0Tsw4BJXquQtrMBeavfMcdphAs+dNero=";

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [
      dbus
      systemd
    ];

    meta = {
      description = "Runs WebAuthn passkey ceremonies with a phone or a USB security key";
      homepage = "https://github.com/ampcode/amp-passkey-helper";
      license = lib.licenses.lgpl21Plus;
      mainProgram = "amp-passkey-helper";
    };
  });

  # Holds a GNOME suspend inhibitor while UPower reports AC power, and
  # rechecks on every change UPower announces.
  inhibitOnAc = writeShellScript "amp-desktop-lid-inhibit" ''
    inhibitor=
    update() {
      on_battery=$(${systemd}/bin/busctl get-property org.freedesktop.UPower \
        /org/freedesktop/UPower org.freedesktop.UPower OnBattery)
      if [ "$on_battery" = "b false" ]; then
        if [ -z "$inhibitor" ] || ! kill -0 "$inhibitor" 2>/dev/null; then
          ${gnome-session}/bin/gnome-session-inhibit --inhibit suspend \
            --app-id amp-desktop --reason "Amp runner is on" --inhibit-only &
          inhibitor=$!
        fi
      elif [ -n "$inhibitor" ]; then
        kill "$inhibitor"
        wait "$inhibitor"
        inhibitor=
      fi
    }
    { echo; exec ${glib.bin}/bin/gdbus monitor --system \
        --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower; } |
      while read -r _; do update; done
  '';
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "amp-desktop";
  version = "0.1.29927281";

  src = fetchurl {
    url = "https://static.ampcode.com/linux/${finalAttrs.version}/amp-desktop-${finalAttrs.version}-amd64.deb";
    hash = "sha256-inNuQ90hCnvjyKQAvNInRcMIbcXNmuY+PiqQmc1tJ48=";
  };

  nativeBuildInputs = [
    dpkg
    makeWrapper
  ];

  installPhase = ''
    runHook preInstall

    install -Dm644 opt/amp/resources/app.asar $out/share/amp-desktop/app.asar
    cp -r usr/share/icons $out/share/icons
    install -Dm644 usr/share/applications/amp-desktop.desktop -t $out/share/applications
    substituteInPlace $out/share/applications/amp-desktop.desktop \
      --replace-fail /opt/amp/amp-desktop amp-desktop

    # xdg-open opens the browser for sign-in and links.
    makeWrapper ${lib.getExe electron_44} $out/bin/amp-desktop \
      --add-flags $out/share/amp-desktop/app.asar \
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --set AMP_PASSKEY_HELPER ${lib.getExe passkeyHelper} \
      --inherit-argv0

    # The app runs its runner as the user unit amp-desktop-runner.service.
    # While it runs and the laptop is on AC power, this unit holds a GNOME
    # session suspend inhibitor, so a closed laptop stays reachable. GNOME
    # then locks and blanks the screen on lid close and turns it back on when
    # the lid opens, and idle blanking still works. On battery the inhibitor
    # is dropped, so the lid suspends as usual. logind refuses the lid
    # suspend only with LidSwitchIgnoreInhibited=no, and the inhibitor also
    # blocks idle suspend. gnome-session takes its logind lock in block-weak
    # mode, so the user can still suspend by hand. NixOS ignores [Install];
    # wire it up with systemd.user.services.amp-desktop-lid-inhibit.wantedBy.
    install -Dm644 /dev/stdin $out/lib/systemd/user/amp-desktop-lid-inhibit.service <<EOF
    [Unit]
    Description=Keep a closed laptop on AC power awake while the Amp runner is on
    BindsTo=amp-desktop-runner.service
    After=amp-desktop-runner.service

    [Service]
    ExecStart=${inhibitOnAc}
    Restart=always

    [Install]
    WantedBy=amp-desktop-runner.service
    EOF

    runHook postInstall
  '';

  meta = {
    description = "Amp, the frontier coding agent, as a desktop app";
    homepage = "https://ampcode.com";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "amp-desktop";
  };
})
