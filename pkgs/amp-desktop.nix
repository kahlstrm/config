# Amp's Linux desktop app, published as a .deb in Amp's apt repository
# (ampcode.com/app). The current version and its SHA-256 are in
# https://static.ampcode.com/linux/dists/stable/main/binary-amd64/Packages.
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
  coreutils,
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
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "amp-desktop";
  version = "0.1.29908343";

  src = fetchurl {
    url = "https://static.ampcode.com/linux/${finalAttrs.version}/amp-desktop-${finalAttrs.version}-amd64.deb";
    hash = "sha256-Z3EOt6cupJA/dzqKxJEg9KGRBoknmJlALjNVFzoHwYY=";
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
    # While it runs, this unit keeps logind from acting on the lid, so a
    # closed laptop stays reachable. It takes no sleep lock, so suspending
    # by hand still works. NixOS ignores [Install]; wire it up with
    # systemd.user.services.amp-desktop-lid-inhibit.wantedBy.
    install -Dm644 /dev/stdin $out/lib/systemd/user/amp-desktop-lid-inhibit.service <<EOF
    [Unit]
    Description=Ignore lid close while the Amp runner is on
    BindsTo=amp-desktop-runner.service
    After=amp-desktop-runner.service

    [Service]
    ExecStart=${systemd}/bin/systemd-inhibit --what=handle-lid-switch --who=Amp --why="Amp runner is on" --mode=block ${coreutils}/bin/sleep infinity

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
