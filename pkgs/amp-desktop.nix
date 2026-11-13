# Amp's Linux desktop app, published as a .deb in Amp's apt repository
# (ampcode.com/app). The current version and its SHA-256 are in
# https://static.ampcode.com/linux/dists/stable/main/binary-amd64/Packages.
# The app is a JavaScript bundle with no native modules, so it runs on
# nixpkgs' Electron of the same major version as the one it ships with, and
# the bundle is the same for every architecture. The .deb's optional
# amp-passkey-helper binary is left out, so the app offers no passkey sheet.
{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
  makeWrapper,
  electron_44,
  xdg-utils,
  systemd,
  coreutils,
}:
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
